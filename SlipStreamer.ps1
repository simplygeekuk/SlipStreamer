#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Slipstream SSU / LCU / .NET updates into Windows Server 2019 / 2022 / 2025 ISOs.

.DESCRIPTION
    For each requested version, this driver:
      1. Loads config/<version>.psd1 and validates the base ISO + update packages.
      2. Extracts the base ISO to a writable work tree.
      3. Applies the updates to every edition (index) in sources\install.wim via DISM.
      4. Rebuilds a dual BIOS + UEFI bootable ISO with oscdimg.

    The resulting ISO in iso/output/ is intended to be handed to Packer (out of scope here).

    Drop the base ISO in iso/base/ and the matching update packages (LCU, optional SSU/.NET) in updates/<version>/
    before running. Must be run elevated.

.PARAMETER ArgumentList
    One or more versions to slipstream: 2019, 2022, 2025. Values may be given positionally
    or after -Version (e.g. -Version 2019,2025).

.PARAMETER All
    Process every version that has both a base ISO and update packages present.

.PARAMETER KeepWork
    Do not delete the work/<version>/ scratch tree after a successful build (for debugging).

.EXAMPLE
    .\SlipStreamer.ps1 -Version 2022

.EXAMPLE
    .\SlipStreamer.ps1 -All -WhatIf

.EXAMPLE
    .\SlipStreamer.ps1 -Version 2019,2025 -KeepWork
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$All,

    [switch]$KeepWork,

    # Versions arrive as loose arguments and are parsed by hand below. A declared -Version
    # parameter can't behave gracefully here: the binder throws "Missing an argument" on a
    # bare "-Version" before the script body runs. The catch-all lets us show usage instead.
    # (Cost: no tab completion for the version values.)
    # object[] (not string[]): a comma list like "-Version 2019,2025" arrives as one nested
    # array element, which a string[] cast would mangle into the single string "2019 2025".
    [Parameter(ValueFromRemainingArguments)]
    [object[]]$ArgumentList = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validVersions = @('2019', '2022', '2025')

$usage = @'

SlipStreamer - slipstream SSU / LCU / .NET updates into Windows Server ISOs.

USAGE:
    .\SlipStreamer.ps1 -Version <2019|2022|2025>[,...] [-KeepWork] [-WhatIf]
    .\SlipStreamer.ps1 -All [-KeepWork] [-WhatIf]

OPTIONS:
    -Version    One or more of 2019, 2022, 2025.
    -All        Process every version that has a base ISO and updates present.
    -KeepWork   Keep the work/<version>/ scratch tree after a successful build.
    -WhatIf     Dry run: show what would happen without changing anything.

EXAMPLES:
    .\SlipStreamer.ps1 -Version 2022
    .\SlipStreamer.ps1 -Version 2019,2025 -KeepWork
    .\SlipStreamer.ps1 -All -WhatIf

Before running, drop the base ISO in iso\base\ and the update packages in
updates\<version>\. Must be run from an elevated PowerShell session.

For full help: Get-Help .\SlipStreamer.ps1 -Detailed
'@

$Version        = @()
$sawVersionFlag = $false
$usageError     = $null

# The inner loop unwraps the nested array a comma list produces; "-Version:2022" reaches us
# as the two tokens "-Version:" and "2022".
$tokens = @(foreach ($item in $ArgumentList) { foreach ($value in @($item)) { [string]$value } })
foreach ($token in $tokens) {
    if ($token -match '^-Version:?$') { $sawVersionFlag = $true }
    elseif ($token -match '^-')       { $usageError = "Unknown argument: $token" }
    else                              { $Version += ($token -split ',' | Where-Object { $_ }) }
}

if (-not $usageError) {
    $invalid = @($Version | Where-Object { $_ -notin $validVersions })
    if ($invalid.Count) {
        $usageError = "Invalid version(s): $($invalid -join ', '). Valid values: $($validVersions -join ', ')."
    }
    elseif ($All -and $Version.Count) {
        $usageError = 'Specify either -Version or -All, not both.'
    }
}

if ($usageError) {
    Write-Host "ERROR: $usageError" -ForegroundColor Red
    Write-Host $usage
    exit 1
}

if (-not $All -and -not $Version.Count) {
    if ($sawVersionFlag) {
        Write-Host 'No value supplied for -Version; expected one or more of: 2019, 2022, 2025.' -ForegroundColor Yellow
    }
    Write-Host $usage
    exit 0
}

Import-Module (Join-Path $PSScriptRoot 'src\SlipStreamer.psm1') -Force

# Stop an accidental click from freezing a long copy/DISM step (console QuickEdit mode).
Disable-ConsoleQuickEdit

$repoRoot = $PSScriptRoot
$logDir   = Join-Path $repoRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if ($All) { $Version = $validVersions }

$overallFailures = @()
$runTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($ver in $Version) {
    $verTimer   = [System.Diagnostics.Stopwatch]::StartNew()
    $stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $transcript = Join-Path $logDir "slipstream-$ver-$stamp.log"
    # -WhatIf:$false so a dry run is still transcribed (otherwise the finally-block
    # Stop-Transcript fails: "The host is not currently transcribing").
    Start-Transcript -Path $transcript -Force -WhatIf:$false | Out-Null

    $config   = $null
    $mountDir = $null
    try {
        Write-Log "================ Windows Server $ver ================" -Level STEP
        Assert-Elevated
        $oscdimg = Get-OscdimgPath

        # -All silently skips versions that aren't ready; explicit -Version surfaces the error.
        try {
            $config = Get-VersionConfig -Version $ver
        }
        catch {
            if ($All) {
                Write-Log "Skipping $ver : $($_.Exception.Message)" -Level WARN
                continue
            }
            throw
        }
        $mountDir = Join-Path $config.WorkRoot 'mount'

        Write-Log "Base ISO   : $($config.BaseIso)"
        Write-Log "Output ISO : $($config.OutputIso)"
        Write-Log "Updates    : $($config.Packages.Count) package(s) from $($config.UpdatesPath)"
        $idxLabel = if ($config.Indexes -and $config.Indexes.Count) { $config.Indexes -join ', ' } else { 'all' }
        Write-Log "Indexes    : $idxLabel"
        Write-Log "ResetBase  : $($config.ResetBase)"
        Write-Log "ScratchDir : $($config.ScratchDir)"
        Write-Log "Trim       : $($config.TrimToSelected)"
        Write-Log "VolumeLic  : $($config.VolumeLicense)"

        # Fail fast if any target volume is short on space before the long extract/patch begins.
        Assert-FreeSpace -Config $config

        # Likewise fail fast (or auto-dismount) if the previous output ISO is mounted/locked,
        # rather than discover it after an hour of DISM work.
        Assert-OutputIsoWritable -Config $config -WhatIf:$WhatIfPreference

        # Forward -WhatIf explicitly: preference variables (incl. $WhatIfPreference) do NOT
        # cross the Import-Module boundary, so without this the module functions would run
        # for real even under -WhatIf.
        $isoWork = Expand-BaseIso -Config $config -WhatIf:$WhatIfPreference
        Update-InstallWim -Config $config -IsoWork $isoWork -WhatIf:$WhatIfPreference
        Optimize-InstallWim -Config $config -IsoWork $isoWork -WhatIf:$WhatIfPreference
        New-BootableIso -Config $config -IsoWork $isoWork -OscdimgPath $oscdimg -WhatIf:$WhatIfPreference

        Write-Log "Windows Server $ver complete." -Level STEP
    }
    catch {
        $overallFailures += $ver
        Write-Log "FAILED ($ver): $($_.Exception.Message)" -Level ERROR
        Write-Log $_.ScriptStackTrace -Level ERROR
    }
    finally {
        # Never leave a stale WIM mount that would block the next run.
        if ($mountDir) { Clear-StaleMount -MountPath $mountDir }

        if ($config -and -not $KeepWork -and -not $WhatIfPreference) {
            if (Test-Path -LiteralPath $config.WorkRoot) {
                Write-Log "Cleaning work tree: $($config.WorkRoot)"
                Remove-Item -LiteralPath $config.WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Log "Windows Server $ver took $($verTimer.Elapsed.ToString('hh\:mm\:ss'))" -Level STEP

        # Start-Transcript ran with -WhatIf:$false above, so transcription is always active
        # here. (Stop-Transcript has no -WhatIf parameter, so don't pass one.)
        Stop-Transcript | Out-Null
    }
}

Write-Host ''
Write-Log "Total run time: $($runTimer.Elapsed.ToString('hh\:mm\:ss'))" -Level STEP

if ($overallFailures.Count -gt 0) {
    Write-Host ''
    Write-Log "Completed with failures: $($overallFailures -join ', ')" -Level ERROR
    exit 1
}

Write-Host ''
Write-Log 'All requested versions processed successfully.' -Level STEP
