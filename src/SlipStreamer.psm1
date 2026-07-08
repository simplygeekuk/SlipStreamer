#Requires -Version 5.1
<#
.SYNOPSIS
    Helper functions for slipstreaming SSU / LCU / .NET updates into Windows Server ISOs.
.DESCRIPTION
    Backend for SlipStreamer.ps1. Handles ADK/oscdimg discovery, config loading,
    base-ISO extraction, DISM patching of every index in install.wim, and rebuilding a
    dual-boot (BIOS + UEFI) ISO with oscdimg.

    Mutating functions support -WhatIf so the whole pipeline can be dry-run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root = parent of this module's src/ directory.
$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Disable-ConsoleQuickEdit {
    <#  Clear the console's QuickEdit mode so an accidental click can't pause a long-running step
        (robocopy copy, DISM). Best-effort: silently no-ops where it doesn't apply (redirected /
        non-interactive input, Windows Terminal). Session-scoped; not restored on exit. #>
    [CmdletBinding()]
    param()
    if (-not [Environment]::UserInteractive) { return }
    $src = @'
using System;
using System.Runtime.InteropServices;
public static class SsConsole {
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    const int  STD_INPUT_HANDLE = -10;
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    public static bool Disable() {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        uint m;
        if (!GetConsoleMode(h, out m)) return false;   // redirected / no console
        m &= ~ENABLE_QUICK_EDIT_MODE;
        m |= ENABLE_EXTENDED_FLAGS;
        return SetConsoleMode(h, m);
    }
}
'@
    try {
        if (-not ('SsConsole' -as [type])) { Add-Type -TypeDefinition $src -ErrorAction Stop }
        if ([SsConsole]::Disable()) { Write-Log 'Console QuickEdit mode disabled for this run.' }
    }
    catch {
        Write-Log "Could not disable console QuickEdit (non-fatal): $($_.Exception.Message)" -Level WARN
    }
}

function Resolve-RepoPath {
    <#  Turn a repo-relative path into an absolute one (absolute paths pass through). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $script:RepoRoot $Path)
}

function Assert-Elevated {
    <#  DISM WIM mount/commit requires an elevated session. Fail fast otherwise. #>
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This process must run in an elevated (Run as Administrator) PowerShell session. DISM cannot mount/commit WIM images otherwise.'
    }
    Write-Log 'Elevation check passed (running as Administrator).'
}

function Get-OscdimgPath {
    <#  Locate oscdimg.exe from an installed Windows ADK, or on PATH. #>
    [CmdletBinding()]
    param()

    $roots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($root in $roots) {
        foreach ($arch in @('amd64', 'x86')) {
            $candidate = Join-Path $root "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$arch\Oscdimg\oscdimg.exe"
            if (Test-Path -LiteralPath $candidate) {
                Write-Log "Found oscdimg: $candidate"
                return $candidate
            }
        }
    }

    $onPath = Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue
    if ($onPath) {
        Write-Log "Found oscdimg on PATH: $($onPath.Source)"
        return $onPath.Source
    }

    throw @'
oscdimg.exe not found. Install the Windows ADK "Deployment Tools" feature:
  https://learn.microsoft.com/windows-hardware/get-started/adk-install
Expected under: %ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\<arch>\Oscdimg\
'@
}

function Get-VersionConfig {
    <#  Load config/<Version>.psd1, resolve paths, and validate inputs exist. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('2019', '2022', '2025')][string]$Version)

    $configFile = Join-Path $script:RepoRoot "config\$Version.psd1"
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Config file not found: $configFile"
    }

    $cfg = Import-PowerShellDataFile -LiteralPath $configFile

    # BaseIso / OutputIso are FILE NAMES only. They are always resolved inside the
    # deterministic repo folders iso\base and iso\output — any directory part in the config
    # value is ignored (only the leaf file name is used). BaseIso may be a wildcard.
    $baseDir   = Join-Path $script:RepoRoot 'iso\base'
    $outputDir = Join-Path $script:RepoRoot 'iso\output'

    # Resolve the base ISO from iso\base — the file name may be a literal or a wildcard.
    $baseName   = [System.IO.Path]::GetFileName([string]$cfg.BaseIso)
    $baseSpec   = Join-Path $baseDir $baseName
    $isoMatches = @(Get-ChildItem -Path $baseSpec -File -ErrorAction SilentlyContinue)
    if ($isoMatches.Count -eq 0) {
        throw "No base ISO matched '$baseName' in $baseDir. Drop the Server $Version base ISO into iso\base\."
    }
    if ($isoMatches.Count -gt 1) {
        throw ("Base ISO name '$baseName' matched $($isoMatches.Count) files in $baseDir. Narrow the pattern or keep one ISO there:`n  " +
               ($isoMatches.Name -join "`n  "))
    }
    $baseIso = $isoMatches[0].FullName

    # Output ISO is written to iso\output using just the configured file name.
    $outputIso = Join-Path $outputDir ([System.IO.Path]::GetFileName([string]$cfg.OutputIso))

    $updatesPath = Resolve-RepoPath $cfg.UpdatesPath
    if (-not (Test-Path -LiteralPath $updatesPath)) {
        throw "Updates folder not found: $updatesPath"
    }
    $packages = @(Get-ChildItem -Path $updatesPath -File -Include '*.msu', '*.cab' -Recurse)
    if ($packages.Count -eq 0) {
        throw "No .msu/.cab update packages found in $updatesPath. Drop the LCU (and any SSU/.NET) there first."
    }

    # Optional edition selection: which install.wim indexes to patch. Empty/omitted = all.
    $indexes = @()
    if ($cfg.ContainsKey('Indexes') -and $null -ne $cfg.Indexes) {
        $indexes = @($cfg.Indexes)
        foreach ($i in $indexes) {
            if ($null -eq ($i -as [int]) -or [int]$i -lt 1) {
                throw "Config 'Indexes' must be a list of 1-based positive integers. Got: '$i'."
            }
        }
        $indexes = @($indexes | ForEach-Object { [int]$_ } | Select-Object -Unique)
    }

    [pscustomobject]@{
        Version     = $Version
        BaseIso     = $baseIso
        OutputIso   = $outputIso
        UpdatesPath = $updatesPath
        Packages    = $packages
        Indexes     = $indexes
        VolumeLabel = [string]$cfg.VolumeLabel
        ResetBase   = [bool]$cfg.ResetBase
        WorkRoot    = Join-Path $script:RepoRoot "work\$Version"
    }
}

function Get-OrderedPackage {
    <#
        Return update packages in the order DISM expects for offline servicing:
            SSU (servicing stack)  ->  LCU / other  ->  .NET last.

        Catalog .msu filenames are named by KB number, not type (e.g.
        windows10.0-kb5094123-x64_<hash>.msu), so type detection is best-effort.
        For full control — or a stand-alone SSU whose name isn't self-describing —
        prefix every file with a number (01_, 02_, ...) and that order is used verbatim.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.FileInfo[]]$Packages)

    # Explicit override: if EVERY file carries a numeric prefix, honour it verbatim.
    $numbered = @($Packages | Where-Object { $_.Name -match '^\d{1,3}[-_ .]' })
    if ($numbered.Count -eq $Packages.Count) {
        return $Packages | Sort-Object @{ Expression = { [int]($_.Name -replace '^(\d{1,3}).*', '$1') } }, Name
    }

    # Otherwise bucket by best-effort filename heuristics.
    $rank = {
        if ($_.Name -match 'ssu|servicing[-_ ]?stack')                 { 0 }  # SSU first
        elseif ($_.Name -match 'ndp\d|netfx|dotnet|net[-_ ]?framework') { 2 }  # .NET last
        else                                                           { 1 }  # LCU / other
    }
    $Packages | Sort-Object @{ Expression = $rank }, Name
}

function Expand-BaseIso {
    <#  Mount the base ISO, copy its full contents to a writable work tree, dismount. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $isoWork = Join-Path $Config.WorkRoot 'iso'

    if (-not $PSCmdlet.ShouldProcess($Config.BaseIso, "Extract base ISO to $isoWork")) {
        return $isoWork
    }

    if (Test-Path -LiteralPath $Config.WorkRoot) {
        Write-Log "Clearing previous work tree: $($Config.WorkRoot)" -Level WARN
        Remove-Item -LiteralPath $Config.WorkRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $isoWork -Force | Out-Null

    Write-Log "Mounting base ISO: $($Config.BaseIso)" -Level STEP
    $image = Mount-DiskImage -ImagePath $Config.BaseIso -PassThru
    try {
        $driveLetter = ($image | Get-Volume).DriveLetter
        $source = "${driveLetter}:\"
        Write-Log "Copying ISO contents from $source to $isoWork ..."
        # /E all subdirs incl. empty, /COPY:DAT, quiet-ish output.
        $robolog = & robocopy.exe $source $isoWork /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
        # robocopy exit codes < 8 are success (files copied / nothing to do / extras).
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed copying ISO contents (exit $LASTEXITCODE).`n$robolog"
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $Config.BaseIso | Out-Null
        Write-Log 'Base ISO dismounted.'
    }

    # The copied install.wim inherits the read-only attribute from the ISO — clear it.
    $wim = Join-Path $isoWork 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) {
        $esd = Join-Path $isoWork 'sources\install.esd'
        if (Test-Path -LiteralPath $esd) {
            throw "Found install.esd but no install.wim in this ISO. Convert it to WIM first (Export-WindowsImage -CompressionType Max), or use a WIM-based Server ISO."
        }
        throw "sources\install.wim not found in the extracted ISO tree: $isoWork"
    }
    Set-ItemProperty -LiteralPath $wim -Name IsReadOnly -Value $false

    return $isoWork
}

function Update-InstallWim {
    <#  Apply the ordered packages to every index in install.wim. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$IsoWork
    )

    $wim      = Join-Path $IsoWork 'sources\install.wim'
    $mountDir = Join-Path $Config.WorkRoot 'mount'
    $ordered  = Get-OrderedPackage -Packages $Config.Packages

    Write-Log "Packages to apply (in order):" -Level STEP
    $ordered | ForEach-Object { Write-Log "  - $($_.Name)" }

    # Under -WhatIf the base ISO was never extracted, so install.wim isn't here yet.
    # Report intent and stop rather than failing on a missing WIM.
    if (-not (Test-Path -LiteralPath $wim)) {
        if ($WhatIfPreference) {
            $sel = if ($Config.Indexes -and $Config.Indexes.Count) { "index(es) $($Config.Indexes -join ', ')" } else { 'every edition' }
            Write-Log "What if: base ISO not extracted during dry run; would patch $sel in install.wim with the packages above." -Level WARN
            return
        }
        throw "sources\install.wim not found for patching: $wim"
    }

    $images = @(Get-WindowsImage -ImagePath $wim)
    if ($Config.Indexes -and $Config.Indexes.Count -gt 0) {
        $available = @($images.ImageIndex)
        $missing   = @($Config.Indexes | Where-Object { $_ -notin $available })
        if ($missing.Count) {
            throw "Config 'Indexes' requested index(es) $($missing -join ', '), but install.wim only has: $($available -join ', ')."
        }
        $images = @($images | Where-Object { $_.ImageIndex -in $Config.Indexes })
        Write-Log "install.wim has $($available.Count) edition(s); patching selected: $($Config.Indexes -join ', ')." -Level STEP
    }
    else {
        Write-Log "install.wim contains $($images.Count) edition(s); patching all." -Level STEP
    }

    foreach ($img in $images) {
        $idx  = $img.ImageIndex
        $name = $img.ImageName
        if (-not $PSCmdlet.ShouldProcess("index $idx ($name)", 'Slipstream updates into WIM edition')) {
            continue
        }

        Write-Log "==> Index $idx : $name" -Level STEP
        if (Test-Path -LiteralPath $mountDir) { Remove-Item -LiteralPath $mountDir -Recurse -Force }
        New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

        Mount-WindowsImage -ImagePath $wim -Index $idx -Path $mountDir | Out-Null
        try {
            $skipped = @()
            foreach ($pkg in $ordered) {
                Write-Log "    + $($pkg.Name)"
                try {
                    Add-WindowsPackage -Path $mountDir -PackagePath $pkg.FullName -ErrorAction Stop | Out-Null
                }
                catch {
                    # HResult is a signed Int32; match the hex in the message too as a
                    # locale-independent fallback in case the cmdlet wraps the HResult.
                    $hr  = $_.Exception.HResult
                    $msg = "$($_.Exception.Message)"

                    # CBS_E_NOT_APPLICABLE (0x800F081E == -2146498530): this payload targets a
                    # different baseline than this edition (e.g. one of several .NET-baseline
                    # packages). Skip it rather than aborting the whole build.
                    if ($hr -eq -2146498530 -or $msg -match '0x800[Ff]081[Ee]') {
                        Write-Log "    ~ skipped (not applicable to index ${idx}): $($pkg.Name)" -Level WARN
                        $skipped += $pkg.Name
                        continue
                    }

                    # CBS_E_NEW_SERVICING_STACK_REQUIRED (0x800F0823 == -2146498525): the image's
                    # servicing stack is older than this package (usually the LCU) requires. Add a
                    # hint, then re-throw so the build still fails loudly.
                    if ($hr -eq -2146498525 -or $msg -match '0x800[Ff]0823') {
                        Write-Log ("    ! $($pkg.Name) requires a newer servicing stack (0x800F0823). " +
                                   "This base image's SSU is older than the package needs. Add the matching " +
                                   "standalone SSU for Server $($Config.Version) to the updates folder so it " +
                                   "applies first (prefix it '0_' to force order).") -Level ERROR
                    }
                    throw
                }
            }
            if ($skipped.Count) {
                Write-Log "    Skipped $($skipped.Count) non-applicable package(s) on index ${idx}: $($skipped -join ', ')" -Level WARN
            }

            if ($Config.ResetBase) {
                Write-Log '    Running component cleanup (/ResetBase) ...'
                & dism.exe /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "dism /ResetBase failed (exit $LASTEXITCODE) on index $idx." }
            }

            Write-Log "    Committing index $idx ..."
            Dismount-WindowsImage -Path $mountDir -Save | Out-Null
        }
        catch {
            Write-Log "Error on index $idx; discarding mount to avoid a stale WIM lock." -Level ERROR
            Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
            throw
        }
    }
}

function New-BootableIso {
    <#  Rebuild a dual BIOS + UEFI bootable ISO from the patched tree with oscdimg. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$IsoWork,
        [Parameter(Mandatory)][string]$OscdimgPath
    )

    # Under -WhatIf the ISO tree was never extracted; report intent and stop before the
    # boot-file existence check (which would otherwise throw on the missing tree).
    if ($WhatIfPreference) {
        Write-Log "What if: would build bootable ISO $($Config.OutputIso) from $IsoWork." -Level WARN
        return
    }

    $etfsboot = Join-Path $IsoWork 'boot\etfsboot.com'
    $efisys   = Join-Path $IsoWork 'efi\microsoft\boot\efisys.bin'
    foreach ($f in @($etfsboot, $efisys)) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Boot file missing from ISO tree: $f" }
    }

    $outDir = Split-Path -Parent $Config.OutputIso
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    if (-not $PSCmdlet.ShouldProcess($Config.OutputIso, 'Build bootable ISO with oscdimg')) {
        return
    }

    if (Test-Path -LiteralPath $Config.OutputIso) {
        Write-Log "Removing existing output ISO: $($Config.OutputIso)" -Level WARN
        Remove-Item -LiteralPath $Config.OutputIso -Force
    }

    $bootData = "2#p0,e,b$etfsboot#pEF,e,b$efisys"
    $oscArgs  = @(
        '-m'            # ignore max image size limit
        '-o'            # optimize storage of duplicate files
        '-u2'           # produce a pure UDF file system
        '-udfver102'
        "-l$($Config.VolumeLabel)"
        "-bootdata:$bootData"
        $IsoWork
        $Config.OutputIso
    )

    Write-Log "Building ISO: $($Config.OutputIso)" -Level STEP
    & $OscdimgPath @oscArgs
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)." }

    $sizeGb = [math]::Round((Get-Item -LiteralPath $Config.OutputIso).Length / 1GB, 2)
    Write-Log "ISO created: $($Config.OutputIso) ($sizeGb GB)" -Level STEP
}

function Clear-StaleMount {
    <#  Best-effort discard of any WIM mount left over from a crashed run. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPath)

    $mounted = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $MountPath }
    if ($mounted) {
        Write-Log "Discarding stale WIM mount at $MountPath" -Level WARN
        Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction SilentlyContinue | Out-Null
    }
    # Clean up the DISM mount registry too (harmless if nothing to do).
    & dism.exe /Cleanup-Mountpoints | Out-Null
}

Export-ModuleMember -Function Write-Log, Disable-ConsoleQuickEdit, Assert-Elevated, Get-OscdimgPath,
    Get-VersionConfig, Expand-BaseIso, Update-InstallWim, New-BootableIso, Clear-StaleMount
