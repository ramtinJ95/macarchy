# Changelog

All notable user-facing changes to Macarchy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `environment plan` with typed Kitty, zsh, Starship, and Atuin provider
  selections, package-owned defaults, bounded native customization, exact
  rendered artifacts, and fail-closed theme ownership validation.
- Added aggregate `environment apply`, `status`, `doctor`, and `teardown` with
  profile-selected prerequisites, immutable generations, reviewed multi-entry
  adoption, theme reconciliation, fresh-shell verification, interrupted-state
  recovery, drift-safe rollback, and exact restoration of retained entries.
- Added the optional first-class Herdr environment preset with strict version
  and live-reload contracts, bounded 16-token theme ownership, reviewed Stow
  target adoption, legacy-journal migration, and exact disable restoration.
- Added the first-class default desktop shell: deterministic no-SA yabai
  tiling, managed skhd shortcuts, and a clean-room Space-aware themed
  SketchyBar with role opt-outs and sparse portable profile controls.
- Added reviewed adoption, immutable provider generations, service/runtime
  evidence, trusted local yabai and SketchyBar hooks, drift reporting, recovery,
  and exact restoration for the desktop providers.
- Added aggregate `desktop plan`, `apply`, `status`, `doctor`, and `teardown`
  behavior with selected-role prerequisite reporting, reverse-order rollback,
  theme reconciliation, and an opt-in event-driven volume module.

## [0.5.0] - 2026-08-31

### Added

- Added portable managed keybindings composed from immutable curated defaults,
  explicit disabled chords, and sparse native skhd command and metadata
  overrides, without copying packaged defaults into user configuration.
- Added shared `keybindings plan`, `apply`, `status`, effective list/doctor, and
  setup behavior with immutable generated state, reviewed adoption of existing
  skhd entries, live lifecycle evidence, crash recovery, rollback, and exact
  teardown restoration.
- Added source-attributed effective keybinding rows and convergence states to
  the searchable popup while preserving source-based inspection for externally
  managed skhd configuration.

### Fixed

- Slack theme imports now contain the four colors accepted by the current
  custom-theme UI: window background, selected items, presence indication, and
  notification badges.
- Theme and keybinding generations now publish their owner-writable root before
  sealing it, preserving atomic immutable publication on macOS 26 versions that
  reject renaming a mode-0555 directory.
- `keybindings show` now opens before the first theme activation using a
  deterministic bundled appearance; malformed canonical theme state still
  fails explicitly.

## [0.4.3] - 2026-08-29

### Fixed

- Personal backgrounds are now applied exactly once when selecting or cycling
  them through `theme background` or the active-theme picker, avoiding a
  duplicate-ID collision while preserving the complete effective gallery.

## [0.4.2] - 2026-08-29

### Added

- Bundled every validated wallpaper from the pinned Omarchy revision for
  Catppuccin Mocha, Kanagawa, and Tokyo Night, preserving upstream order and
  exact asset bytes.
- Added ordered `[[wallpaper_additions]]` configuration so personal PNG, JPEG,
  and WebP files extend any theme's package gallery without replacing it.
  Existing schema-1 wallpaper overrides remain readable as additive entries.
- Added `macarchy theme get slack`, backed by a generic manual-consumer lookup,
  to print the active generation's exact Slack import value on demand.

### Fixed

- Raised Pi's tertiary `dim` text independently to readable contrast against
  the page and every derived conversation background, including Tokyo Night
  and Lavender-like palettes.

## [0.4.1] - 2026-08-29

### Changed

- Tokyo Night and Kanagawa now exactly match Macarchy's accepted conversion of
  Omarchy's default palettes across every generated consumer theme.
- The three generated built-in wallpapers were replaced with exact Omarchy
  defaults. Validated WebP support preserves the Tokyo Night and Catppuccin
  assets without transcoding, while Kanagawa ships its upstream JPEG.
- Catppuccin uses an Omarchy wallpaper as its redistributable fallback while
  the configured personal Samurai image remains an unbundled local override.

### Fixed

- The theme browser now previews and labels a configured personal wallpaper
  override instead of showing package bytes that activation would replace.

## [0.4.0] - 2026-08-29

### Added

- Added ordered background inventories with remembered per-theme selections
  and `theme background current`, `set`, and `next` commands.
- Added deterministic generated palette previews and validated, lazily loaded
  preview galleries for imported themes.
- Added `macarchy theme browse`, a theme-aware AppKit picker with search,
  keyboard theme, preview, and wallpaper navigation, and explicit Apply.

### Changed

- Generation manifests now record the selected background, its actual media
  type, and a separate non-background theme digest.
- Changing only the active theme's background reconciles wallpaper without
  reloading unrelated consumers. Themes without backgrounds deliberately leave
  wallpaper unmanaged.
- Imported themes use one explicit `[[backgrounds]]` contract. Packages created
  with the older `[wallpaper]` contract must be reinstalled.

### Fixed

- Wallpaper reconciliation rereads canonical intent under the activation lock,
  applies every display on AppKit's required thread, and preserves lazy
  inactive-Space convergence.
- Large imported wallpapers are decoded into bounded thumbnails off the AppKit
  event thread so keyboard browsing remains responsive.

## [0.3.1] - 2026-08-29

### Added

- Added startup and cross-layer consistency checks that reject duplicate
  consumer and artifact identities, unknown selected consumers, and incomplete
  setup or dependency coverage.
- Added a generated-palette fixture consumer that proves a new integration can
  extend rendering through one catalog entry without editing theme packages or
  unrelated consumer lists.

### Changed

- Consolidated renderer metadata, runtime adapter selection and requirements,
  setup participation, dependency capabilities, named-theme compatibility, and
  manual notices behind one typed internal consumer catalog.
- Preserved generated bytes and paths, manifest renderer versions, setup
  ownership records, public CLI and JSON output, and required or optional
  adapter outcomes across the maintainability refactor.

## [0.3.0] - 2026-08-28

### Added

- Added strict inspection of enabled skhd bindings through
  `macarchy keybindings list`, with stable human and JSON output and explicit
  diagnostics for unsupported syntax or duplicate effective chords.
- Added a metadata-only keybinding catalog for curated labels, categories,
  ordering, and search aliases, plus `macarchy keybindings doctor` diagnostics
  for missing and stale metadata.
- Added a short-lived, theme-aware AppKit keybindings popup through
  `macarchy keybindings show`, with immediate keyboard search, navigation, and
  reliable Escape or focus-loss dismissal.

### Security

- Keybinding commands remain opaque display text and are never executed by the
  parser, doctor, or popup. The popup requires no Accessibility or Screen
  Recording grant and installs no resident helper.

### Known limitations

- Popup selection is informational. Executing a selected binding requires a
  separate future security and interaction decision.

## [0.2.2] - 2026-08-28

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

[Unreleased]: https://github.com/ramtinJ95/macarchy/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/ramtinJ95/macarchy/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/ramtinJ95/macarchy/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/ramtinJ95/macarchy/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/ramtinJ95/macarchy/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/ramtinJ95/macarchy/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/ramtinJ95/macarchy/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/ramtinJ95/macarchy/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/ramtinJ95/macarchy/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/ramtinJ95/macarchy/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ramtinJ95/macarchy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ramtinJ95/macarchy/releases/tag/v0.1.0
