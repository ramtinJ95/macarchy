# Macarchy

https://github.com/user-attachments/assets/3a88e8f8-7213-4313-a2b7-4075d1570a4a

Macarchy makes a macOS desktop follow one coherent theme. A single command
selects the canonical palette, regenerates application themes, and updates each
supported surface at its best proven boundary: live when possible, otherwise on
the next invocation or restart.

Macarchy is independently authored and inspired by
[Omarchy](https://omarchy.org/). It is not an official port, a dotfile bundle,
or a general application installer.

The current stable release is
[v0.4.3](https://github.com/ramtinJ95/macarchy/releases/tag/v0.4.3).
See the [changelog](CHANGELOG.md) for release details.

## What it does

- Keeps one authoritative active theme under `~/.config/macarchy`.
- Ships Catppuccin Mocha, Tokyo Night, and Kanagawa Wave themes.
- Safely installs compatible Omarchy themes from public GitHub repositories
  without running repository-provided code.
- Renders native configuration for the terminal, shell tools, TUIs, editor,
  status bar, wallpaper, and macOS appearance.
- Reconciles supported applications without hiding failures or restart limits.
- Diagnoses canonical state, generated artifacts, application seams, and stale
  reconciliation results.
- Establishes allowlisted setup integrations without taking ownership of
  existing dotfiles.
- Records every setup-owned change so teardown can reverse only what Macarchy
  created.

Current integrations include macOS appearance, wallpaper, Kitty, SketchyBar,
bat, eza, btop, Yazi, Atuin, Neovim, Starship, Pi, Herdr, tuicr, Codex CLI, and
optional Spicetify support. Macarchy also generates manual Slack theme imports.

## Requirements

- Apple Silicon
- macOS 26
- Swift 6 for development builds

Macarchy runs with normal SIP. It does not require yabai's scripting addition,
Developer ID signing, notarization, an Apple Developer account, or telemetry.

## Install

Macarchy is distributed through the personal Homebrew tap. Homebrew 6 requires
an explicit trust decision for third-party formulae:

```sh
brew tap ramtinj95/tap
brew trust --formula ramtinj95/tap/macarchy
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
  brew install --formula --no-ask ramtinj95/tap/macarchy
macarchy setup
macarchy doctor
```

The formula installs the immutable arm64 release archive and its bundled
themes, normalized-theme contract, changelog, and license. Setup reports
missing personal profile capabilities and establishes only the allowlisted
integration seams it can own safely.

## Try it from source

```sh
swift build
swift run macarchy --version
swift run macarchy theme list
swift run macarchy theme set catppuccin-mocha --dry-run
swift run macarchy theme set catppuccin-mocha
swift run macarchy theme status
```

Useful commands:

```sh
macarchy theme list
macarchy theme browse
macarchy theme background list <theme-id> [--state-root <path>]
macarchy theme background current [--state-root <path>]
macarchy theme background set <background-id> [--dry-run]
macarchy theme background next [--dry-run]
macarchy theme set <theme-id> [--dry-run]
macarchy theme next [--dry-run]
macarchy theme install <github-url> [--dry-run] [--json]
macarchy theme status [--json]
macarchy theme get slack
macarchy keybindings plan [--profile <path>] [--state-root <path>] [--json]
macarchy keybindings list [--json] [--skhd-config <path>] [--catalog <path>]
macarchy keybindings doctor [--json] [--skhd-config <path>] [--catalog <path>]
macarchy keybindings show [--skhd-config <path>] [--catalog <path>] [--state-root <path>]
macarchy reconcile [adapter ...] [--dry-run]
macarchy doctor [--json]
macarchy setup [--dry-run] [--json]
macarchy setup --install-dependencies [--dry-run]
macarchy teardown [--dry-run] [--json]
macarchy update status [--json]
macarchy update check [--json]
macarchy update
```

Development builds find bundled themes from the checkout containing `.build`.
Installed builds resolve resources relative to the executable, so commands do
not depend on the current working directory. `--themes-root`, `--state-root`,
and consumer-specific path options are available for development and testing.

`keybindings list` parses enabled key-to-command bindings from the configured
skhd file without executing them. It preserves chained shell commands as
opaque display text, normalizes modifier order, ignores disabled lines, and
returns explicit nonzero diagnostics for unsupported enabled syntax or
duplicate effective chords. The default source is `~/.config/skhd/skhdrc`.
Optional labels, categories, ordering, and search aliases come from the strict
metadata-only `~/.config/macarchy/keybindings.toml` catalog. Catalog entries
are keyed by normalized chord identity and cannot contain commands. The
keybindings doctor warns about missing or stale metadata and parser/duplicate
diagnostics, while unreadable or invalid inputs fail explicitly.

`keybindings plan` is the read-only entry point for managed keybindings. It
composes immutable packaged defaults with an optional sparse native override,
explicit disabled default identities, and an optional metadata-only overlay.
The default portable profile is `~/.config/macarchy/profile.toml`; an absent
default profile means packaged defaults, while an explicit missing `--profile`
is an error. Relative input paths resolve beside the resolved profile source:

```toml
schema_version = 1

[keybindings]
override = "keybindings.skhdrc"
metadata = "keybindings-metadata.toml"
disabled = ["alt+shift-m"]
```

The plan reports replacement, addition, disablement, source attribution,
deterministic effective bytes, current-generation state, and provider-entry
ownership in human or JSON form. It never publishes a generation, changes
`~/.config/skhd`, reloads skhd, or executes a configured command.

`keybindings show` opens the same correlated rows in a short-lived searchable
AppKit popup. The popup follows the active Macarchy theme, supports keyboard
search and navigation, closes on Escape or focus loss, and remains strictly
informational: selecting a row never executes its configured command.

`theme browse` opens a short-lived AppKit browser for every valid built-in and
installed theme. Search and navigation change only the local generated palette
preview, optional validated import gallery, and background selection. Enter or
the Apply button performs one canonical activation of the selected theme and
background; closing or changing focus without applying leaves state unchanged.
The personal skhd configuration opens it with Cmd-Shift-T.

Built-in and imported themes may expose any number of validated PNG, JPEG, and
WebP backgrounds. Personal files can be appended without replacing package
choices by using schema-2 configuration; they remain local and are copied into
the immutable generation only when selected:

```toml
schema_version = 2

[[wallpaper_additions]]
theme_id = "catppuccin-mocha"
id = "samurai"
path = "/absolute/path/to/samurai.png"
```

Repeat `[[wallpaper_additions]]` with a unique stable ID for additional files.
Schema-1 `[wallpaper_overrides]` remains readable as one legacy personal
addition so an upgrade does not hide the package gallery.

`update status` reads cached GitHub release evidence and the locally installed
Homebrew tap without refreshing either source. `update check` explicitly
refreshes the GitHub evidence. Macarchy may perform that same conditional
request at most once per 24 hours during an eligible interactive command; set
`MACARCHY_DISABLE_UPDATE_CHECKS=1` to disable only automatic checks.

`macarchy update` is available only to stable Homebrew-owned installations. It
streams an explicit Homebrew metadata refresh, compares the latest stable
GitHub release with the refreshed tap, and upgrades only
`ramtinj95/tap/macarchy`. A release newer than the tap is reported as packaging
pending. Upgrade verification reopens the installed build metadata and bundled
resources even when the installed version is current; Macarchy never downloads
or replaces itself outside Homebrew.

## Install an Omarchy theme

Use a dry run to inspect conversion and capability evidence before changing
canonical state:

```sh
macarchy theme install --dry-run https://github.com/owner/theme-repository
macarchy theme install https://github.com/owner/theme-repository
```

The installer accepts only public HTTPS GitHub repository URLs. It shallowly
fetches the default branch without tags or submodules, records the resolved
commit, and imports only palette data, supported files directly under
`backgrounds/`, and inert previews. Symlinks and invalid or oversized images
fail validation. Scripts, hooks, executables, Lua, application overrides,
templates, nested backgrounds, and unknown active configuration are ignored,
named in the report, and never executed or installed.

Each valid package exposes an ordered background inventory with explicit stable
IDs. PNG and JPEG entries are fully decoded within the documented image bounds.
Theme packages created by an older Macarchy release with a `[wallpaper]` table
must be reinstalled so the importer rebuilds them with `[[backgrounds]]`.

Reinstalling the same URL validates the replacement before atomically swapping
the package and activating it. A failure before canonical commit restores the
previous package and generation; a postcommit consumer failure remains visible
without pretending the commit was rolled back.

Imported palettes drive macOS appearance, wallpaper, Kitty, SketchyBar, shell
tools, Neovim, and every other generated-palette consumer. Neovim receives a
strictly data-only palette rendered through a pinned, preinstalled Aether v3
plugin; repository-provided Lua remains ignored and Macarchy's canonical
pointer remains the only theme authority. Herdr receives a complete generated
16-token custom palette and repaints through its live config reload. Macarchy
edits only the allowlisted theme selector/custom keys, retains first-import
backup and ownership evidence, rejects unowned custom colors, and removes its
custom values when returning to a built-in. Missing wallpaper provenance is
reported as a personal-use warning; imported assets are not release-eligible
without verified rights.

Slack does not expose a supported theme automation API, configuration file, or
preferences deep link. Every committed activation therefore prints a
four-color payload for Slack's window background, selected items, presence
indication, and notification badges, and stores the same value in the active
generation as `generated/slack.txt`. Slack maps these values to its supported
color palettes rather than preserving arbitrary colors exactly, as described
in [Slack's redesign](https://slack.design/articles/a-new-visual-language-for-slack/).
Run `macarchy theme get slack` at any time to print only that active import
value. The target is resolved through the manual-consumer catalog so future
import-only applications can use the same `theme get <target>` command. In
Slack, open **Preferences → Appearance → Custom theme → Theme colors → Import
theme**, paste the payload, and apply it. This manual boundary follows
[Slack's documented import
flow](https://slack.com/help/articles/205166337-Change-your-Slack-theme) rather
than editing Slack's private Electron storage.

## Setup without dotfile takeover

`macarchy setup` inspects the supported personal dependency profile and the
configuration seams Macarchy needs. It is non-mutating unless an allowlisted
integration is missing from an eligible ordinary local path.

Correct pre-existing configuration remains external and unclaimed. Macarchy
does not write through GNU Stow or other symlink-owned configuration. When it
does make a change, it writes a private backup and a strict ownership record
before atomically replacing a file or creating an exact canonical link.

The current setup surface covers:

- Kitty's stable bridge include;
- bat's theme selector and canonical theme link;
- eza's configuration-directory environment directive and theme link;
- btop's canonical theme link, while its runtime-writable selector must remain
  externally managed;
- Yazi's TOML flavor selector plus flavor and syntax-theme links; and
- Atuin's TOML theme selector and canonical theme link.

Yazi's `flavors/macarchy-current.yazi` directory is an external structural
prerequisite. Setup may own the exact links inside it, but it does not claim the
directory. TOML edits preserve unrelated bytes and formatting, reject malformed
or conflicting selectors, and support interruption-safe resume.

`macarchy teardown` first checks every ownership record. It then restores only
recorded file edits and removes only recorded links. User themes, generated
palettes, generations, logs, and rebuildable application caches are preserved.
Software removal is a separate Homebrew-owned step:

```sh
macarchy teardown
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  brew uninstall --formula ramtinj95/tap/macarchy
```

Reinstalling preserves the state under `~/.config/macarchy`:

```sh
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
  brew install --formula --no-ask ramtinj95/tap/macarchy
macarchy setup
macarchy doctor
```

If Homebrew reports a successful upgrade but Macarchy's installed-layout
verification fails, use the exact recovery path printed by `macarchy update`:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 \
  HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
  brew reinstall --formula --no-ask ramtinj95/tap/macarchy
/opt/homebrew/bin/macarchy update
```

This is a reinstall, not an automatic rollback claim. Purging
`~/.config/macarchy` is deliberately not part of teardown or uninstall.

Dependency installation is separately authorized with
`--install-dependencies`. Macarchy reports the exact Homebrew formulae and casks
before mutation, does not edit a Brewfile, and leaves npm installation and
third-party Homebrew trust as explicit external actions.

## Activation and recovery

Theme activation validates the complete package before changing canonical
state. It publishes a new immutable generation atomically, then reconciles
applications and records their individual outcomes. Required failures remain
visible and nonzero; optional failures remain visible without pretending the
entire activation failed.

Interrupted activation and setup operations retain enough evidence to resume
or fail explicitly. Unknown drift is never overwritten by a best-effort
fallback. The canonical `current` pointer and its validated generation remain
authoritative; notifications and reload commands are only update mechanisms.

Spicetify is optional. Macarchy refreshes its generated colors and restarts
Spotify only when Spotify was already running; a closed client remains closed.

## Development

Run the same core checks used by continuous integration:

```sh
swift format lint --strict --recursive Package.swift Sources Tests
swift test
swift build -c release
```

Tests use temporary roots and do not access the developer's live Macarchy
state.

Build and smoke-test an installed layout from an unrelated working directory:

```sh
Scripts/build-release-layout.sh \
  .build/release/macarchy .build/macarchy-release "$(git rev-parse HEAD)"
Scripts/smoke-release-layout.sh .build/macarchy-release
```

Build the versioned archive and checksum used by the release workflow:

```sh
Scripts/build-release-archive.sh \
  .build/release/macarchy dist "$(git rev-parse HEAD)"
```

The supported installed layout is:

```text
bin/macarchy
share/macarchy/build-info.json
share/macarchy/themes/<theme-id>/...
share/doc/macarchy/CHANGELOG.md
share/doc/macarchy/theme-json.md
share/doc/macarchy/LICENSE
```

The theme package and normalized palette format is documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

Macarchy is available under the [MIT License](LICENSE). Bundled wallpaper
provenance and licensing are recorded inside each theme package.
