### Added

- Guided setup offers reviewed backups and replacement starters for existing zsh,
  Kitty and Neovim configurations. Backups stay beside the originals and appear in
  `setup status`. Teardown restores originals (including exact symlinks), retains
  starter edits in sibling backups, and never automatically deletes backups.
  Interrupted replacement or restoration continues through `setup recover`.

- Setup status and doctor flag missing, modified or retargeted original backups
  as restoration-blocking drift only while restoration is still required. After
  restoration, archives remain listed but user edits or deletion do not affect
  health or hide other inspection results. Recorded ownership is unchanged.
