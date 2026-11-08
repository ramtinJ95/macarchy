### Fixed

- `macarchy environment status` no longer reports drift when Herdr or Neovim
  reports that the active theme has no named mapping; it now agrees with
  `macarchy doctor`, which treats that state as a warning.
