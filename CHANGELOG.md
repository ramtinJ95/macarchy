# Changelog

All notable user-facing changes to Macarchy are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The lean focus outline could get left behind on one Space and stop appearing on any
  other until its service was restarted. It now notices within a couple of seconds and
  comes back on the Space you are using.
- Setup apply now reactivates your theme when it predates the current bar palette.
  Before, the plan listed that step but apply rolled back with "the active theme predates
  the current managed SketchyBar palette contract".
- `macarchy theme set` no longer fails with "must be a symbolic link" when a Macarchy
  theme link has not been created yet. The theme activates and the missing link is
  reported as drift until setup creates it; a file of your own at that path still stops
  activation.
- Command-A, Command-C, Command-V, Command-X and Command-Z now work in the search fields
  of the action menu, the theme browser and the keybindings viewer. Before, Command-A did
  not select the query, so typing a new search added to the old one.
- Environment apply no longer refuses to update an unchanged configuration file, such as
  Herdr's `config.toml`, with "changed after setup; refusing to overwrite it". This
  happened when the file lacked the provenance tag macOS adds to files Macarchy writes. A
  file you edited is still never overwritten.
- When a desktop or environment apply failed and its rollback also failed, the report
  named only the rollback failure. It now shows the original error as well.
- Setup apply no longer fails and rolls back when the playing song, the Wi-Fi network,
  the computer name or an update error contains a quotation mark, a backslash or a line
  break. The volume popup now works when an output device name contains one, clicking a
  Wi-Fi detail copies it exactly, and the microphone hover text shows quotation marks in a
  device name instead of replacing them.
- Macarchy no longer reports bat as themed when bat skipped the Macarchy theme. One
  unreadable file in `~/.config/bat/themes`, such as a broken link, makes bat drop every
  custom theme and warn "Unknown theme 'Macarchy Current'" on each run. Reconcile now
  reports bat as drifted and shows bat's message naming the file to fix.

## [0.14.4] - 2026-10-19

### Fixed

- A failed environment apply could delete an existing link that already pointed at
  Macarchy's own target, leaving setup stuck in recovery. Macarchy now retains the
  original before any change and never deletes it unverified (#292).
- The keep-awake cup and the paused screensaver sign left of the bar clock now use SF Symbols,
  so they match the size of the microphone and screensaver icons instead of rendering smaller
  from a fallback font (#293).
- Click-opened bar popups (Wi-Fi, volume, battery, and media controls) now close once the
  pointer leaves them, instead of staying open until the pointer returns to the bar. The
  battery popup needs the regenerated bar configuration, so review and apply it to get this
  (#295).

## [0.14.2] - 2026-10-19

### Fixed

- Setup apply no longer fails and rolls back when the microphone toggle's hover text
  names the default microphone. SketchyBar reported the name's quotation marks
  unescaped, which the bar check could not read (#290).

## [0.14.1] - 2026-10-19

### Added

- `macarchy saver idle toggle` and the **Toggle idle screensaver** menu action turn
  idle activation of the animated screensaver off while it is on, otherwise on after
  5 minutes. When the menu or the bar turns it on and the
  macOS screensaver or display sleep would come first, an alert says that Macarchy's
  screensaver will not show.

### Changed

- Macarchy enters alpha. It is in daily use on real Macs, but expect rough edges:
  fresh-Mac setup and first-use permission flows are not yet fully tested.
- The three icons left of the managed bar clock are now always shown and turn their
  feature on or off when clicked. The cup toggles keep-awake, the microphone mutes or
  unmutes the default microphone, and a new screen with sparkles toggles idle
  activation of the animated screensaver. Each icon is dimmed in the theme's muted
  color while its feature is off and lit in the accent color while it is on. While
  idle activation is paused, the screen shows the lit pause icon, and a click resumes
  it. When a feature cannot change, such as a microphone with no mute or input-level
  control, the icon stays dimmed, the hover text says why, and a click shows the error
  in an alert. To get the toggles, review and apply the generated bar configuration.
  Until then, the bar shows each icon only while keep-awake is on, the microphone is
  muted, or idle starts are paused.

## [0.14.0] - 2026-10-18

### Added

- `macarchy saver start` and the **Start screensaver** menu action fill every
  display with text animated in the active theme's colors, in one Kitty panel per
  display. Any key press or mouse movement dismisses it everywhere. It is
  decorative, not a lock, and changes no native screensaver, lock, password or
  sleep settings. Put your own text in `~/.config/macarchy/screensaver.txt`.
  `saver stop` and `saver status` act only on the panels Macarchy opened. The
  release archive bundles the ttfx animation engine (MIT) at `libexec/ttfx`, built
  from a pinned upstream commit, with its licences in `share/doc/macarchy/ttfx/`.
  Source builds report the engine as missing.
- `macarchy saver idle on` starts the animated screensaver after 5 minutes without
  input, or after 1 minute to 4 hours with `--after`. It stays off until you turn it
  on, and `saver idle off` removes its launch agent and record. Pause, keep-awake, a
  locked screen, the macOS screensaver and display sleep hold it off. Locking the
  screen, the macOS screensaver or display sleep closes a showing screensaver.
  Macarchy changes no macOS settings: `idle on` and `saver status` warn when the
  macOS screensaver or display sleep would come first. `saver pause`, `saver resume`,
  `saver toggle-pause` and the **Toggle screensaver pause** menu action hold idle
  starts off. While paused, a pause icon left of the managed bar clock resumes them
  on click. To activate the icon after upgrading, review and apply the generated bar
  configuration.
- `macarchy keep-awake` and the **Toggle keep-awake** menu action keep the display
  awake and stop the idle screensaver and idle lock from starting until you turn
  keep-awake off. `keep-awake on --for` ends the session after 1 minute to 24 hours.
  Macarchy runs one Apple `caffeinate` process and never stops other apps'
  keep-awake sessions. While keep-awake is on, a cup left of the managed bar clock
  shows when it ends. Click the cup to turn keep-awake off. To activate the cup
  after upgrading, review and apply the generated bar configuration.
- `macarchy mic` and the **Choose microphone** and **Toggle microphone mute** menu
  actions choose the default microphone and mute it. Mute uses the microphone's own
  hardware mute when it has one. Otherwise Macarchy sets its input level to zero,
  restores the level on unmute, and labels the result "silenced by input level, not
  a hardware mute". Macarchy reports a microphone with neither control and changes
  nothing. Both act on the system default input only. Apps that choose their own
  input are not affected, so neither is a privacy guarantee. While the default
  microphone is muted, a slashed microphone left of the managed bar clock shows how
  it is muted. Click it to unmute. To activate the icon after upgrading, review and
  apply the generated bar configuration.
- `macarchy image prepare` and the **Prepare an image** menu action save a
  separate copy of an image file or the clipboard image with the `share` preset
  (JPEG, up to 2048 px), the `small` preset (JPEG, up to 1280 px), or the `png`
  preset (lossless, original size). The copy has the orientation applied, sRGB
  colors, and none of the original's EXIF, GPS, TIFF, XMP, or IPTC metadata, and
  it is never larger than the original. Macarchy saves it beside the original, or in `~/Downloads`
  for a clipboard image, and never replaces a file. Macarchy copies the result to
  the clipboard, and the menu action also shows it in Finder.
- `macarchy clipboard` and the **Clipboard history** and **Clear clipboard history**
  menu actions work with Maccy, an optional app that keeps your clipboard history.
  Install it with `macarchy setup add-packages cask:maccy` or
  `brew install --cask maccy`; no upgrade or setup run installs it on its own.
  `macarchy clipboard enable` turns on Maccy's `clearOnQuit` and
  `clearSystemClipboard` settings and saves their earlier values, which
  `macarchy clipboard disable` puts back unless you changed them in Maccy since.
  **Clipboard history** opens Maccy's history. **Clear clipboard history** asks for
  confirmation, and `macarchy clipboard clear` does not. A clear quits Maccy so its
  own clear runs, deletes its history database and its Shortcuts image export, pinned
  items included, empties the clipboard, and restarts Maccy if it was running. With a
  Maccy version other than 2.7.1, Macarchy deletes no files, reports that pinned items
  may remain, and exits with an error. Macarchy never reads Maccy's history.
- `macarchy clipboard enable` also turns on an automatic clear. Once 24 hours have
  passed since the last clear, a Macarchy launch agent quits Maccy, so Maccy clears
  its unpinned history. The agent then empties the clipboard and starts Maccy again
  if it was running. Every clear of the history restarts the 24 hours. The agent
  checks hourly while the Mac is awake, so a due clear runs within about an hour of
  the Mac being awake. Pinned items survive it. The automatic
  clear never reaches Maccy's protected folder, so it raises no permission dialog,
  and it relies on the two Maccy settings that `enable` turned on.
  `macarchy clipboard auto-clear off` and `on` turn it off and on without changing
  Maccy's settings, and `disable` turns it off. `macarchy clipboard status` shows the
  last and next clear and the last failure. A failed automatic clear shows an alert
  at most once a day.
- `macarchy clipboard save` saves the image on the clipboard, such as an older item
  you picked in Maccy's history, to a new file or to standard output. The file's
  extension picks PNG, JPEG, TIFF, or HEIC, and `--format` picks it for standard
  output. An image already in that format is saved unchanged, and any other is
  converted at its own size. Macarchy never replaces a file and refuses to write
  image data to a terminal. `save` works without Maccy. For text, use `pbpaste`.

## [0.13.1] - 2026-10-17

### Fixed

- Standalone environment apply and teardown now refuse while a unified setup
  operation is pending, preserving its recovery decision. Recover through
  `setup apply` or `setup teardown` before retrying (#270).

### Changed

- Shared internal ownership transaction mechanics and retired the unused legacy
  setup apply path while preserving released ownership formats and teardown
  support (#265–#269).

## [0.13.0] - 2026-10-16

### Added

- Opt-in managed lean focus outlines through `[focus_ring] provider = "lean"`.
  The separate, packaged helper follows the active theme without restarting and
  supports setup, status/doctor, repair and teardown. Borders remains the default.
- To switch, set `provider = "lean"` in your active profile, review `setup plan`
  with that profile, then run `setup apply`. To roll back, set `provider = "borders"`
  and review/apply again; `"disabled"` removes managed focus. Installation alone
  does not switch providers, and unmanaged Borders is never stopped or adopted
  implicitly.

### Changed

- Simplified internal CLI, theme-core and release-script paths without changing
  their ownership or permission boundaries (#239–#261).

### Known limitations

- Lean uses narrow private SkyLight APIs only in its separate helper, with no new
  TCC grants, scripting addition or SIP change. Retina/multiple displays, ordinary
  Spaces, broad real-app compatibility and long-running stability remain
  unqualified; guest evidence is not physical-machine or universal visual parity.
- Lean runtime state is written only at startup or palette changes; idle guest
  checks observed zero writes. Liveness uses process identity, not a heartbeat or
  hung-runloop guarantee. Upgrading an owned helper requires repair/apply to restart
  it through its stable launch path; startup refusals remain visible and stopped.
- In minimal setups, missing default theme consumers can still block overall
  teardown after successful removal of the owned lean service.

## [0.12.4] - 2026-10-14

### Added

- Tokyo Night's Liftoff rocket wallpaper is selectable in the theme browser and CLI.
- Explicit, read-only-first `environment migrate-ownership herdr` repairs legacy
  Herdr directory-link identity after reviewed approval, without changing user
  configuration or restarting applications.

### Fixed

- Herdr directory-link ownership now uses a persistent volume UUID plus inode,
  preserving link-target and metadata checks across reboot-time device renumbering.
- Herdr detects a stopped server through its native JSON status contract.
- Fresh native environment starters, setup consent and optional-package defaults,
  native skhd/yabai service restoration, SketchyBar readiness, and bounded process
  output draining include the previously merged onboarding fixes.

- Retained SketchyBar, yabai, and skhd originals now use persistent volume UUIDs
  plus inode identity so mount-device renumbering after reboot does not cause
  ownership drift. Legacy records require a separately reviewed, provider-scoped
  `desktop migrate-ownership` operation; migration does not restart services or
  regenerate configuration.

## [0.12.3] - 2026-09-23

### Fixed

- Continue bounded Spotify replacement-process verification after the specific
  transient Launch Services error -600. A stable replacement is still required;
  no extra launch attempts occur, and exhaustion preserves the original error.

## [0.12.2] - 2026-09-23

### Added

- Native region screenshots to clipboard or file, a separate Flameshot annotation
  action, and on-device English region-to-text OCR in the menu and capture CLI.
  Cancellation and empty OCR results preserve the clipboard.

### Fixed

- Imported Herdr themes now color sidebar, focused-row and selection backgrounds.
  Existing managed palettes migrate without losing rollback or original settings.
- SketchyBar waits briefly for yabai's socket during startup, showing an explicit
  waiting or error state instead of silently leaving an Apple-only bar.

### Changed

- The optional Herdr preset now requires Herdr 0.8.2 or newer.

### Known limitations

- Installation alone does not activate generated theme or bar changes. Select the
  theme again to regenerate them; Herdr applies its palette through live reload.
- OCR is English-only and requires macOS screen-capture permission in the launching
  application's context. Fresh-user permission onboarding remains unqualified.

## [0.12.1] - 2026-09-20

### Fixed

- Give maintenance commands terminal foreground ownership so Review & apply and
  Review & update wait for confirmation instead of immediately reporting closed
  input. Restore terminal ownership before the result window's Enter dismissal.

## [0.12.0] - 2026-09-20

### Added

- Review & apply configuration and Review & update Macarchy in the action menu,
  with explicit consent, stale-plan/release rejection and retained terminal results.
- A circular-arrow update indicator beside the SketchyBar clock, following its
  automatic display placement. Stable-release checks share the update cache and
  run at most every six hours during normal operation; hover shows details and
  clicking opens the reviewed updater. Failed checks remain visibly distinct from
  an up-to-date installation. No background Homebrew update or upgrade.

### Fixed

- Reviewed updates revalidate the active Homebrew prefix and build rather than
  trusting an old executable retained in a previous Cellar keg.

### Known limitations

- Installing a release does not apply profiles or reload providers. Review & apply
  the bar configuration to activate the new clock companion. Native menu/bar visual
  acceptance remains pending; personal bar configurations may override the defaults.

## [0.11.1] - 2026-09-20

### Fixed

- Configure keybindings now edits personal skhd commands rather than the profile's
  disabled list, with reviewed first connection and keybinding-only save/reload.
- Configure Desktop and Bar now open personal shell configurations that can
  override shipped defaults. Successful editor exit validates and restarts only
  yabai or reloads only SketchyBar; ordinary saves do not execute shell code.
- Reject unrelated pending settings and stale hook consent during scoped native
  configuration changes. Preserve saved edits on validation or runtime failure.

### Known limitations

- First connections require review; upgrading does not create personal files or
  restart providers. Native behavior is only partially observable, while theme,
  readiness and permission checks remain explicit. SketchyBar theme reloads also
  re-execute personal code. Live editor/provider acceptance remains pending.

## [0.11.0] - 2026-09-19

### Added

- Configure actions for profiles, keybindings, Neovim, Starship, Atuin, Kitty,
  zsh, desktop and bar settings, using normally tiled native Kitty editors.
- Reviewed native starters and provider-scoped connections that preserve personal
  files, dotfile links and unrelated providers during setup and recovery.
- Themed floating terminals for menu maintenance checks, with visible results.

### Changed

- Validate native configuration saves without applying unrelated settings.
  Eligible managed keybinding edits retain their scoped save-to-apply path.
- Keep existing native hooks and overrides in their original shape. Managed
  desktop/bar settings continue to require reviewed apply.
- Improve native viewer handoff and focus indicators.

### Known limitations

- Native behavior takes effect on new prompts, invocations or shells as reported;
  Kitty requires its native reload. No automatic application restart or migration
  occurs on upgrade. Review & apply/update menu actions remain future work.

## [0.9.11] - 2026-09-14

### Fixed

- Keep SketchyBar toggle failures to a short indicator instead of crowding out
  the clock and other widgets. Preserve full diagnostics in the service log
  without corrupting the JSON ownership state needed for automatic recovery.

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
