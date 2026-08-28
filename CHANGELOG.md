# Changelog

All notable user-facing changes to Macarchy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Generate a Slack legacy-theme import payload for every canonical theme,
  include it in committed human and JSON activation reports, and retain it as
  `generated/slack.txt` in the active immutable generation.

### Fixed

- Give Pi user, extension, pending-tool, successful-tool, and failed-tool
  regions distinct palette-derived backgrounds, and raise overly dim secondary
  text to readable contrast against those regions.

### Known limitations

- Slack exposes no supported API or configuration seam for automatic personal
  theme changes. Applying the generated payload remains a per-workspace manual
  action in Slack's Appearance preferences.

## [0.2.1] - 2026-08-28

### Added

- Added complete data-only Neovim palettes for imported Omarchy themes through
  a pinned, preinstalled Aether v3 renderer and the existing live
  canonical-pointer watcher.
- Added complete 16-token Herdr custom palettes for imported themes with live
  config reload, first-import backup, and durable managed-value evidence.

### Changed

- Imported Neovim palettes are now required generated artifacts. Activation
  preflight requires the pinned source-controlled renderer seams, while
  reconciliation and `doctor` validate the active palette.
- Imported Herdr palettes are now required generated artifacts. Reconciliation
  atomically updates only the theme selector and exact custom-token allowlist,
  preserves unrelated config edits, retries interrupted ownership transactions,
  and removes managed custom values when returning to a built-in.

### Security

- Imported `neovim.lua` remains ignored. Executable watcher/plugin behavior is
  source-controlled, generated Lua contains only validated identities and color
  values, and Aether's competing Omarchy/Aether filesystem watchers are not
  enabled.
- Imported Herdr configuration remains ignored. Macarchy derives colors only
  from validated canonical palette data and rejects ambiguous TOML shapes,
  automatic switching, unknown custom keys, and unowned active custom colors.

## [0.2.0] - 2026-08-27

### Added

- Added `macarchy theme install <github-url>` for safe installation and
  activation of public GitHub Omarchy theme repositories.
- Added deterministic conversion for current semantic-first and legacy ANSI
  Omarchy palettes, including typed compatibility and fallback evidence.
- Added bounded PNG/JPEG background and preview import with media-type,
  dimension, pixel-count, and full-decode validation.
- Added structured human, JSON, and dry-run reports for source commits,
  imported and ignored files, compatibility fallbacks, asset provenance,
  package replacement, canonical commit state, and per-consumer reconciliation.
- Added immutable per-generation capability evidence so unsupported named-theme
  consumers remain distinguishable from drift and failure.

### Changed

- Imported theme packages now activate every generated-palette consumer without
  inventing Neovim or Herdr mappings. Those two consumers visibly report
  `unsupported` and retain their prior named appearance.
- Reinstalling an imported theme now atomically swaps the validated package and
  activates the resolved commit without a missing-package interval.
- Imported packages retain all validated backgrounds for later cycling while
  schema v1 deterministically selects the first sorted background as default.
- SketchyBar reconciliation now retries transient query-process timeouts only
  within its existing bounded repaint-settle window.

### Security

- Remote staging accepts only strict public HTTPS GitHub repository URLs and
  performs shallow default-branch clones with isolated Git configuration, no
  tags, no submodule recursion, bounded time, and post-clone size/entry limits.
- Theme conversion rejects symlinks and non-regular entries, never runs remote
  scripts, hooks, templates, Lua, application overrides, or executables, and
  reports every ignored file category.
- Package publication uses exclusive rename for first installs and atomic swap
  for replacements. Precommit failures restore the previous package and
  canonical generation; interrupted transaction evidence remains fail-closed.
- Missing wallpaper provenance remains an explicit personal-use warning and
  imported assets are not treated as release-eligible.

### Known limitations

- Safe automatic Neovim and Herdr mapping import is not included. Imported
  repositories keep those consumers on their prior named themes.
- Theme update, removal, and explicit Git ref selection remain deferred.

## [0.1.0] - 2026-08-27

### Added

- First stable Apple Silicon macOS 26 release.
- Canonical immutable theme generations with atomic activation, typed
  reconciliation, status, doctor, crash recovery, and normalized `theme.json`.
- Built-in Catppuccin Mocha, Tokyo Night, and Kanagawa Wave themes.
- Integrations for macOS appearance, wallpaper, Kitty, SketchyBar, bat, eza,
  btop, Yazi, Atuin, Neovim, Starship, Pi, Herdr, tuicr, Codex CLI, and optional
  Spicetify.
- Homebrew setup, teardown, update awareness, scoped upgrade, installed-layout
  verification, immutable release archives, checksums, and attestations.

[Unreleased]: https://github.com/ramtinJ95/macarchy/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/ramtinJ95/macarchy/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ramtinJ95/macarchy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ramtinJ95/macarchy/releases/tag/v0.1.0
