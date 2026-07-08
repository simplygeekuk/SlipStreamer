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

.PARAMETER Version
    One or more of 2019, 2022, 2025.

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
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Version')]
param(
    [Parameter(ParameterSetName = 'Version', Mandatory, Position = 0)]
    [ValidateSet('2019', '2022', '2025')]
    [string[]]$Version,

    [Parameter(ParameterSetName = 'All', Mandatory)]
    [switch]$All,

    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\SlipStreamer.psm1') -Force

# Stop an accidental click from freezing a long copy/DISM step (console QuickEdit mode).
Disable-ConsoleQuickEdit

$repoRoot = $PSScriptRoot
$logDir   = Join-Path $repoRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if ($All) { $Version = @('2019', '2022', '2025') }

$overallFailures = @()

foreach ($ver in $Version) {
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

        # Forward -WhatIf explicitly: preference variables (incl. $WhatIfPreference) do NOT
        # cross the Import-Module boundary, so without this the module functions would run
        # for real even under -WhatIf.
        $isoWork = Expand-BaseIso -Config $config -WhatIf:$WhatIfPreference
        Update-InstallWim -Config $config -IsoWork $isoWork -WhatIf:$WhatIfPreference
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
        # Start-Transcript ran with -WhatIf:$false above, so transcription is always active
        # here. (Stop-Transcript has no -WhatIf parameter, so don't pass one.)
        Stop-Transcript | Out-Null
    }
}

if ($overallFailures.Count -gt 0) {
    Write-Host ''
    Write-Log "Completed with failures: $($overallFailures -join ', ')" -Level ERROR
    exit 1
}

Write-Host ''
Write-Log 'All requested versions processed successfully.' -Level STEP
