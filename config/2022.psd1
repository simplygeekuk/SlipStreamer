@{
    # File NAME of the clean base ISO. Always read from iso/base/ (no path needed).
    # May be a wildcard, as long as it matches exactly one ISO in iso/base/.
    BaseIso     = 'SW_DVD9_Win_Server_STD_CORE_2022__64Bit_English_DC_STD_MLF_X22-74290.iso'

    # File NAME for the slipstreamed ISO. Always written to iso/output/.
    OutputIso   = 'Server2022_patched.iso'

    # Folder holding the update packages (.msu / .cab) for this version:
    # LCU and, optionally, SSU and/or .NET. Applied in order SSU -> LCU -> .NET.
    UpdatesPath = 'updates/2022'

    # Which install.wim indexes (editions) to patch. Empty (@()) or omitted = patch ALL.
    # Use the 1-based index numbers logged during a run (or: dism /Get-WimInfo /WimFile:...).
    # Unselected editions remain in the ISO, just unpatched. Example: @(1, 3)
    Indexes     = @(2)

    # Volume label stamped onto the rebuilt ISO (max 32 chars).
    VolumeLabel = 'SERVER2022'

    # $true  -> run /StartComponentCleanup /ResetBase after patching each index
    #           (smaller WIM, updates become permanent / non-removable).
    # $false -> keep updates removable and skip the (slow) cleanup pass.
    ResetBase   = $true

    # Optional: after patching, export ONLY the selected Indexes into a fresh install.wim so the
    # output ISO drops the unpatched editions (smaller media for Packer). Needs a non-empty
    # Indexes; ignored with a warning when Indexes is empty/all. Surviving editions are renumbered
    # 1..N (Setup selects by edition name, not index). Omitted / $false -> keep every edition.
    TrimToSelected = $true

    # Optional: write a volume-channel sources\EI.CFG into the ISO so Setup does not demand a
    # product key (it uses the edition's built-in KMS client key). For retail/MSDN media, which
    # otherwise fail an unattended install with no key. Replaces any EI.CFG on the base ISO.
    # Omitted / $false -> leave the media's channel as it is.
    VolumeLicense = $true

    # Optional: directory DISM uses for temporary scratch space while servicing the image.
    # Omitted/empty -> defaults to work\<version>\scratch (on the same drive as the work tree).
    # Relative paths are repo-relative; absolute paths are used as-is. Needs several GB free.
    # ScratchDir = 'D:\dism-scratch'
}
