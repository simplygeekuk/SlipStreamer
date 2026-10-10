# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-10-10

First public release.

### Added

- Slipstreaming of Servicing Stack, Cumulative and .NET Framework updates into Windows Server
  2019, 2022 and 2025 ISOs. DISM applies the packages to the editions in `sources\install.wim`,
  and oscdimg rebuilds an ISO that boots on both BIOS and UEFI.
- `SlipStreamer.ps1` entry point. `-Version` takes one or more versions, `-All` builds every
  version that has a base ISO and updates in place, `-KeepWork` keeps the work tree for
  debugging, and `-WhatIf` does a dry run. Running it with no arguments, or with bad ones,
  prints usage.
- One config file per version in `config/`, checked on load. An unknown key, a missing required
  key, a non-boolean toggle or a `VolumeLabel` over 32 characters stops the run before any work
  starts.
- Automatic package ordering: SSU first, then the LCU, then .NET. A numeric prefix on every
  filename overrides it.
- A package that does not apply to an edition (CBS error `0x800F081E`) is skipped with a warning
  instead of failing the build. A package that needs a newer servicing stack (`0x800F0823`)
  still fails, with a hint to add the standalone SSU.
- `Indexes` config option to patch only selected `install.wim` editions. Unselected editions
  stay in the ISO unpatched.
- `TrimToSelected` config option to export only the patched editions into a smaller
  `install.wim`.
- `ResetBase` config option to run `/StartComponentCleanup /ResetBase` after patching, which
  shrinks the WIM and makes the updates permanent.
- `ScratchDir` config option to put DISM's scratch space on a chosen drive. It defaults to
  `work/<version>/scratch`.
- `VolumeLicense` config option. When `$true`, the build writes a volume-channel
  `sources\EI.CFG` into the ISO so Windows Setup installs without a product key. Enabled for
  Server 2022 and 2025, whose retail/MSDN media otherwise fail an unattended install with no key.
- Free disk space precheck. The work tree, DISM scratch and output ISO are estimated and summed
  per volume, and a shortfall fails the run before the extract begins.
- Check that the previous output ISO can be replaced, made before the build and again before
  the ISO is written. A mounted ISO is dismounted, and one locked by another process fails the
  run early.
- A transcript for each version in `logs/`, with the elapsed time per version and for the whole
  run.
- Clean-up after a failed run: the WIM mount is discarded so it cannot block the next build.
- Console QuickEdit mode is turned off for the run, so a stray click cannot pause a long DISM
  step.
- MIT licence.

[Unreleased]: https://github.com/simplygeekuk/SlipStreamer/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/simplygeekuk/SlipStreamer/releases/tag/v1.0.0
