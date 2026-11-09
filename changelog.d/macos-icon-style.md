### Added

- Opt-in macOS icon and widget styling from a theme's optional
  `[macos] icon_style` declaration: default, dark, clear or accent-tinted.
  The isolated helper checks support, reads back native state and reverts
  mismatches. Setup disable and teardown preserve later user changes and
  retain pending writes for recovery.
