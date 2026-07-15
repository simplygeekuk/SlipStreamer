# SlipStreamer

Slipstream the latest **Servicing Stack Update (SSU) + Latest Cumulative Update (LCU)**
into Windows Server **2019 / 2022 / 2025** ISOs, producing patched, bootable ISOs for
Packer to rebuild VMs from.

Updates are injected into every edition in `sources\install.wim` with **DISM**, and the
ISO is re-authored with **oscdimg** (BIOS + UEFI bootable). Packer is out of scope.

## Prerequisites

- **Windows** build host, running PowerShell **elevated** (Run as Administrator) — DISM
  cannot mount/commit WIM images otherwise.
- **Windows ADK — "Deployment Tools"** feature installed (provides `oscdimg.exe`).
  Download: <https://learn.microsoft.com/windows-hardware/get-started/adk-install>
- Enough free disk for the extracted ISO + WIM work (allow ~2× the ISO size under `work/`).

## Layout

```
SlipStreamer.ps1  Entry point / driver (run this)
config/          Per-version settings (2019.psd1, 2022.psd1, 2025.psd1)
src/             SlipStreamer.psm1 (helper module)
iso/base/        <- drop clean base ISOs here             (gitignored)
iso/output/      -> patched ISOs are written here         (gitignored)
updates/<ver>/   <- drop that version's LCU (+ SSU/.NET)  (gitignored)
work/            Scratch extract + mount area             (gitignored)
logs/            Per-run transcripts                      (gitignored)
```

Only the folder structure (via `.gitkeep`) is tracked — ISOs and update packages stay out
of git.

## Usage

1. **Drop a base ISO** into `iso/base/` (e.g. `Server2022_eval.iso`). The default config
   matches `Server2022*.iso`; keep one ISO per version or set an exact name in the config.

2. **Drop the updates** for that version into `updates/<version>/`, from the
   [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/). A typical set:
   the **Cumulative Update (LCU)** and, optionally, the **.NET Framework** cumulative update.
   Modern Server LCUs already bundle the SSU, so a separate SSU is usually not required.

   Example for Server 2019: `KB5094123` (LCU) and `KB5088864` (.NET Framework CU) — download
   the **x64 Windows Server 2019** variant of each.

   **Apply order** matters for offline servicing: **SSU → LCU → .NET (last)**. The script
   orders packages automatically using best-effort filename heuristics (SSU first, `.NET`
   last, LCU in between) and logs the resolved order. Because catalog files are named by KB
   number (`windows10.0-kb5094123-x64_<hash>.msu`) rather than type, **run once with
   `-WhatIf` and check the logged order.** If it's ever wrong — or you have a stand-alone SSU
   whose name isn't self-describing — **prefix each filename with a number** to force exact
   order; a numeric prefix on every file overrides the heuristic:
   ```
   updates/2019/01_windows10.0-kb5094123-x64_<hash>.msu   # LCU (SSU bundled)
   updates/2019/02_windows10.0-kb5088864-x64_<hash>.msu   # .NET, applied last
   ```

   **Multiple files for one component.** A catalog download sometimes gives you *two* files for
   the same component — e.g. two .NET Framework payloads targeting different baselines that may
   exist on Server 2019, of which only one applies to a given image. Just drop **both** into
   `updates/<version>/`. The script applies each in turn and **skips any that CBS reports as not
   applicable** (logged as `~ skipped (not applicable)`), so the build no longer fails on the
   non-matching payload. If the filename heuristic mis-buckets a baseline file whose name lacks
   an `ndp*`/`netfx` marker, use the numeric-prefix override above to force its position.

3. **Run elevated:**
   ```powershell
   .\SlipStreamer.ps1 -Version 2022
   ```
   Other forms:
   ```powershell
   .\SlipStreamer.ps1 -Version 2019,2025    # multiple
   .\SlipStreamer.ps1 -All                  # every ready version
   .\SlipStreamer.ps1 -Version 2022 -WhatIf # dry run, no changes
   .\SlipStreamer.ps1 -Version 2022 -KeepWork  # keep work/ for debugging
   ```

The patched ISO lands in `iso/output/` and a transcript in `logs/`.

## Configuration

Each `config/<version>.psd1`:

| Key           | Meaning                                                                 |
|---------------|-------------------------------------------------------------------------|
| `BaseIso`     | File name (or wildcard) of the base ISO. Always read from `iso/base/` — no path. |
| `OutputIso`   | File name for the slipstreamed ISO. Always written to `iso/output/` — no path. |
| `UpdatesPath` | Folder of `.msu`/`.cab` packages for this version.                      |
| `Indexes`     | 1-based `install.wim` index numbers to patch. Empty/omitted = all. Unselected editions stay in the ISO, just unpatched. e.g. `@(1, 3)`. |
| `VolumeLabel` | ISO volume label (≤ 32 chars — enforced up front).                      |
| `ResetBase`   | `$true` runs `/StartComponentCleanup /ResetBase` — smaller WIM, updates become permanent. `$false` (default) keeps them removable. |
| `TrimToSelected` | `$true` exports only the patched `Indexes` into a fresh, smaller `install.wim` (drops unpatched editions). Requires a non-empty `Indexes`; ignored (with a warning) when all editions are patched. Surviving editions are renumbered `1..N`. `$false` (default) keeps every edition. |
| `ScratchDir`  | Optional. Directory DISM uses for temporary scratch while servicing. Omitted/empty = `work/<version>/scratch`. Relative = repo-relative; absolute used as-is. Needs several GB free. |

The config is schema-checked on load: unknown/typo'd keys, missing required keys, a non-boolean
`ResetBase`/`TrimToSelected`, or an over-length `VolumeLabel` all fail immediately with a clear
message before any work starts.

## What it does per version

1. Validate config (schema + `VolumeLabel` length), base ISO, and update packages, then
   **precheck free disk space** — the work extract, DISM scratch, and output ISO are estimated and
   summed per volume; a shortfall fails the run up front with a per-drive breakdown.
2. Mount the base ISO, copy its full contents to `work/<version>/iso`, dismount, clear the
   read-only flag on `install.wim`.
3. For **every selected index** in `install.wim` (all by default, or just those in `Indexes`):
   mount → apply updates in order (SSU → LCU → .NET) → optional `/ResetBase` → commit.
4. If `TrimToSelected` is set (and `Indexes` selects a subset), export just those editions into a
   smaller `install.wim`, dropping the unpatched ones.
5. Rebuild `iso/output/<name>.iso` with oscdimg (dual BIOS + UEFI boot).
6. Discard any stale WIM mount and clean `work/` (unless `-KeepWork`).

Failures are caught per version; a crashed run is cleaned up so it won't leave a locked
WIM mount blocking the next attempt.

## Verifying a build

### On the ISO/WIM (offline)

```powershell
# Mount the output ISO, then inspect an edition:
$mnt = (Mount-DiskImage 'iso/output/Server2022_patched.iso' -PassThru | Get-Volume).DriveLetter
Get-WindowsImage -ImagePath "${mnt}:\sources\install.wim" -Index 1
# Mount that index and confirm the LCU KB is Installed:
#   Mount-WindowsImage ... ; Get-WindowsPackage -Path <mount>
```

Then boot a throwaway VM (or hand the ISO to Packer) to confirm Setup runs to first login.

### On a VM built from the ISO (run on the guest, elevated)

1. **Build + UBR — the primary check.**

   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
       Select-Object ProductName, DisplayVersion, CurrentBuildNumber, UBR
   ```

   > The value that proves the LCU applied is the **`UBR`** (Update Build Revision), the part
   > after the dot in `10.0.17763.<UBR>`. It must match the revision in your slipstreamed LCU's
   > KB article title (e.g. *"…OS Build **17763.6414**"*). If `CurrentBuildNumber` is 17763 but 
   > `UBR` is still the base-media value (a low number like `.107`), the LCU did **not** apply.
   > `cmd /c ver` shows the same `10.0.17763.<UBR>`.

2. **Confirm the packages are Installed.**

   ```powershell
   Get-WindowsPackage -Online |
       Where-Object PackageName -match 'RollupFix|ServicingStack|NetFx|GDR|LanguageFeatures' |
       Select-Object PackageName, PackageState
   Get-HotFix          # lists KB IDs (offline-integrated SSUs may not appear here)
   Get-HotFix -Id KB5094123   # a specific KB — succeeds only if present
   ```

   `RollupFix` = the LCU, `ServicingStack` = the SSU, `NetFx` = the .NET CU — each should read
   `Installed`.

3. **.NET Framework (if you slipstreamed .NET).**

   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' |
       Select-Object Version, Release
   ```

   `Release` confirms the .NET *version* (4.8 ⇒ `Release` ≥ `528040`). To confirm the .NET *cumulative
   update* specifically, use the `NetFx` line from step 2 (or `Get-HotFix -Id <netfx KB>`) — a CU bumps
   assembly/file versions rather than the `Release` value.

4. **Edition — should match what you patched via `Indexes`.**

   ```powershell
   DISM /online /Get-CurrentEdition        # e.g. ServerStandard
   ```

5. **Optional servicing-health sanity.**

   ```powershell
   DISM /online /Cleanup-Image /ScanHealth
   ```

**What PASS looks like:** `UBR` equals your slipstreamed LCU's build revision; the
`RollupFix`/`ServicingStack`/`NetFx` packages show `Installed`; `.NET Release` matches the version you
injected; and the edition equals the one selected by `Indexes`. Cross-check each KB against the
`.msu` files in `updates/<ver>/` — they're named by KB number.
