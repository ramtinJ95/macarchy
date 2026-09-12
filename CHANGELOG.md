# Changelog

All notable user-facing changes to Macarchy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.6] - 2026-09-12

### Changed

- Keep zsh, Kitty, Atuin, Starship and Neovim behavior in writable user-owned
  native configuration, with reviewed connections and theme-only reconciliation.
- Default new guided setups to reviewed native starters under a user-owned
  directory, with one apply confirmation and resumable setup.

### Added

- Absent-only configuration starters, scoped Atuin and Starship migrations, and
  authoritative editable-source lookup through `environment configuration-source`.

### Known limitations

- Upgrading does not migrate existing configurations. Review native sources and
  the connection plan before applying; existing user files are not overwritten.

## [0.9.5] - 2026-09-10

### Fixed

- Recognize the exact managed theme links created by Neovim native migration.
  Version 0.9.4 could report false theme drift and block theme activation even
  though Neovim startup and its writable lockfile worked. Keep strict destination,
  loader and watcher-root validation; no repeat migration or config edits needed.

## [0.9.4] - 2026-09-10

### Fixed

- Add an explicitly reviewed Neovim migration that preserves the active setup as
  writable user-owned configuration, allowing Lazy to write its lockfile. Only
  the entry and four theme bridges remain managed; reapply preserves user edits
  and does not restore the stock plugin graph. Rollback and teardown retain the
  writable copy without modifying the old dotfiles configuration.

### Changed

- Guided setup now uses one keyboard selection menu and one reviewed Install &
  apply confirmation instead of a sequence of yes/no questions.

### Known limitations

- Neovim migration is opt-in through `macarchy environment migrate-neovim`;
  installation alone does not migrate an existing configuration. Restart Neovim
  afterward. GitHub connection timeouts are a separate network issue.

## [0.9.0] - 2026-09-08

### Added

- A complete, individually configurable SketchyBar default: Apple menu, Spaces,
  adaptive calendar, battery, volume and output picker, Wi-Fi details and traffic,
  CPU/memory, Spotify/Music controls and artwork, and native-menu auto-hide.
- A separately packaged Apple-menu helper with manual Accessibility permission,
  and module-derived prerequisites for media and native-menu interaction.
- Portable personal Neovim extras, editing bindings and Markdown-preview styling
  derived from the active editor theme, with an explicit browser-reload notice.

### Changed

- Align managed Kitty, zsh, Atuin, Starship and Yabai behavior with the personal
  defaults while preserving canonical theme colors and excluding private data.
  Kitty retains rounded, titlebar-free windows and requires the exact default font.
- Declare shell integrations and bar-module dependencies from selected providers;
  disabling the relevant provider or module removes its requirements.

### Fixed

- Recognize current and legacy Homebrew service labels without accepting
  conflicting registrations, including Borders/SketchyBar recovery and previews.
- Preserve both the original environment apply failure and a subsequent rollback
  failure instead of masking the first error.

### Known limitations

- Full visual and interaction acceptance is scheduled for a fresh Macarchy
  reinstall on the existing user account; this is not a clean macOS/TCC test.
- Wi-Fi names remain privacy-restricted without Location permission. Apple-menu
  permission is manual, and an existing external bar-toggle must be stopped before
  the owned toggle can run. Spicetify initialization and Spotify restart remain
  manual; its managed appearance will be checked after reinstall.

## [0.8.3] - 2026-09-08

### Fixed

- Block selected Spicetify before setup mutation when Spotify is not prepared
  for no-restart refresh, rather than relying on installed versions alone.
- Add `setup recover` with an explicit `--acknowledge-unverified-spicetify`
  option for rollback to original configuration. Desktop/theme recovery can
  finish while Spotify runtime restoration remains visibly unverified; no
  automatic Spotify initialization, restart, or journal deletion is performed.

## [0.8.2] - 2026-09-08

### Fixed

- Package installation now preserves the selected XDG Homebrew configuration
  location, so existing formula trust is not lost in the sanitized subprocess.
  The same location is included in approval and checked for `brew.env` overrides.
  No trust grants are added; unrelated environment settings remain excluded.

## [0.8.1] - 2026-09-08

### Fixed

- First-install setup planning with Herdr or Slack selected now previews the
  planned bootstrap theme without requiring an active generation. Preview does
  not activate a theme or change applications; existing active-state validation,
  adoption approval and Slack compatibility checks remain enforced.

## [0.8.0] - 2026-09-08

First integrated alpha dogfooding release for existing macOS 26 developer
environments. Fresh-user installation and first-use permission flows remain
unqualified; review plans and reported prerequisites before applying changes.

### Added

- Standard Homebrew workstation packages, personal Brewfile layering, individual
  package exclusions, and guided package choices. Unified setup installs the
  reviewed missing packages before configuring providers, with explicit approval
  and interrupted-installation recovery.
- Named package additions through `setup add-packages`, including formulae,
  casks and third-party taps, with persistent profile intent and visible native
  installation/trust boundaries.
- Managed, theme-coherent JankyBorders focus highlighting with profile opt-out,
  service/status integration, drift checks and restoration.
- Deletion of inactive user-installed themes from the native picker through
  Trash, with confirmation and protection for built-in and active themes.
- A stable Photos screensaver image source that follows theme/background
  changes. Native Photos folder selection remains a one-time manual step.
- Opt-in Dock autohide and Finder filename-extension preferences, with preview,
  exact approval, current-value observation, drift protection and recovery.
  Standalone and unified/guided setup retain originals for guarded restoration.

### Changed

- Rounded six-point focus borders and title-bar-free Kitty defaults. Window
  decoration changes may require a fresh Kitty process.
- Reworked the README around installation, daily use, customization and removal.

### Fixed

- Preserve the effective machine profile in desktop doctor status.
- Avoid requesting keybinding adoption when the desktop role is disabled.
- Safely collect sealed setup-owned theme generations during teardown and retain
  explicit recovery behavior for interrupted native preference writes.

## [0.7.1] - 2026-09-05

### Fixed

- Unified apply now retains component rollback evidence until its own commit
  point, so a later failure restores the immediately prior managed desktop and
  environment state instead of releasing ownership.
- Unified setup now gives desktop and environment reconciliation the same
  complete selected theme-consumer inventory.
- Interrupted unified teardown now keeps consumer-path identity stable while
  restoring shell symlinks and resumes pending component transactions forward.

## [0.7.0] - 2026-09-04

### Added

- Added the read-only unified `macarchy setup plan`, which composes built-in
  defaults, an optional portable profile, and an optional machine-local overlay
  before reporting providers, packages, files, services, permissions, adoption
  evidence, and manual boundaries.
- Added the clean unified `setup apply`, `status`, `doctor`, and reverse-order
  `teardown` lifecycle. It bootstraps the canonical theme, delegates to the
  existing desktop and environment owners with one layered model, installs
  only explicitly approved selected Homebrew requirements, reports partial
  failures, and leaves Homebrew packages and unrelated state untouched.
- Added machine-bound unified adoption approvals through explicit component
  options or one strict JSON approval file. Unified apply validates the complete
  approval set against the current plan before mutation and delegates each
  digest to its existing component owner for revalidation.
- Added a strict unified setup transaction and lock. Later apply failures and
  interrupted applies roll provider stages back in reverse order; interrupted
  teardown resumes forward, and pending recovery blocks plan, status, doctor,
  and dry-run mutation without hiding partial ownership.
- Added `macarchy setup guided`, which records defaults-with-opt-outs as a new
  sparse portable profile, presents the unified plan, stops for external
  prerequisites, and requires explicit adoption, dependency-installation, and
  final apply confirmations.

### Changed

- Replaced the unreleased flat `macarchy setup` command and its direct
  dependency-installation flags with the unified lifecycle subcommands.

## [0.6.2] - 2026-09-04

### Fixed

- Bat and Yazi now recognize only their exact Macarchy-managed environment
  configuration links during theme reconciliation, while foreign links remain
  rejected.

## [0.6.1] - 2026-09-04

### Fixed

- Environment teardown and transitions that disable the managed environment
  entirely now reconcile the restored default theme-consumer set, so global
  `doctor` reports complete evidence without a separate manual `reconcile`.

## [0.6.0] - 2026-09-04

### Added

- Added `environment plan` with typed Kitty, zsh, Starship, and Atuin provider
  selections, package-owned defaults, bounded native customization, exact
  rendered artifacts, and fail-closed theme ownership validation.
- Added aggregate `environment apply`, `status`, `doctor`, and `teardown` with
  profile-selected prerequisites, immutable generations, reviewed multi-entry
  adoption, theme reconciliation, fresh-shell verification, interrupted-state
  recovery, drift-safe rollback, and exact restoration of retained entries.
- Added package-owned managed defaults and full environment lifecycle for bat,
  eza, btop, and Yazi, with bounded native customization and restoration.
- Added hybrid Neovim ownership with a curated managed baseline or a complete
  profile-relative native configuration composed with Macarchy's theme seam.
- Added the optional tuicr environment preset with approved Homebrew setup,
  bounded theme configuration, external-ownership preservation, and an honest
  fresh-launch boundary.
- Added the optional Pi environment preset with bounded theme ownership and a
  manual npm prerequisite that Macarchy reports but never installs.
- Added the optional Codex CLI environment preset with approved Homebrew cask
  setup, bounded theme configuration, and explicit external/private-state
  ownership boundaries.
- Added the optional first-class Herdr environment preset with strict version
  and live-reload contracts, bounded 16-token theme ownership, reviewed Stow
  target adoption, legacy-journal migration, and exact disable restoration.
- Added the optional Spicetify environment preset with strict CLI and Spotify
  version evidence, selector-only reviewed adoption, exact external Stow
  tuples, serialized no-restart refresh, correlated no-op evidence, and
  recoverable exact disable restoration.
- Added the optional Slack environment preset with official-app and renderer-v2
  payload readiness, applied manual-import authority, exact per-workspace
  instructions, and no Slack process or private-state mutation.
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

[Unreleased]: https://github.com/ramtinJ95/macarchy/compare/v0.9.6...HEAD
[0.9.6]: https://github.com/ramtinJ95/macarchy/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/ramtinJ95/macarchy/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/ramtinJ95/macarchy/compare/v0.9.3...v0.9.4
[0.9.0]: https://github.com/ramtinJ95/macarchy/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/ramtinJ95/macarchy/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/ramtinJ95/macarchy/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ramtinJ95/macarchy/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ramtinJ95/macarchy/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/ramtinJ95/macarchy/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/ramtinJ95/macarchy/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/ramtinJ95/macarchy/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/ramtinJ95/macarchy/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/ramtinJ95/macarchy/compare/v0.5.0...v0.6.0
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
