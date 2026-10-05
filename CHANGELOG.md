# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `VolumeLicense` config option. When `$true`, the build writes a volume-channel
  `sources\EI.CFG` into the ISO so Windows Setup installs without a product key. Enabled for
  Server 2022 and 2025, whose retail/MSDN media otherwise fail an unattended install with no key.
