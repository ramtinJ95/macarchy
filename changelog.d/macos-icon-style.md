### Added

- Opt-in macOS icon and widget styling from a theme's optional
  `[macos] icon_style` declaration: default, dark, clear or accent-tinted.
  The isolated helper checks support, reads back native state and reverts
  mismatches. Setup disable and teardown preserve later user changes and
  retain pending writes for recovery.
  Editing the style on an existing theme also invalidates its cached generation
  and any earlier apply review; themes without macOS options keep their existing
  generation digests.
