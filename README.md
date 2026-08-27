# Macarchy

Macarchy makes a macOS desktop follow one coherent theme. A single command
selects the canonical palette, regenerates application themes, and updates each
supported surface at its best proven boundary: live when possible, otherwise on
the next invocation or restart.

Macarchy is independently authored and inspired by
[Omarchy](https://omarchy.org/). It is not an official port, a dotfile bundle,
or a general application installer.

> Macarchy is pre-release software. There is no stable `v0.1.0` release yet.

## What it does

- Keeps one authoritative active theme under `~/.config/macarchy`.
- Ships Catppuccin Mocha, Tokyo Night, and Kanagawa Wave themes.
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
optional Spicetify support.

## Requirements

- Apple Silicon
- macOS 26
- Swift 6 for development builds

Macarchy runs with normal SIP. It does not require yabai's scripting addition,
Developer ID signing, notarization, an Apple Developer account, or telemetry.

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
macarchy theme set <theme-id> [--dry-run]
macarchy theme next [--dry-run]
macarchy theme status [--json]
macarchy reconcile [adapter ...] [--dry-run]
macarchy doctor [--json]
macarchy setup [--dry-run] [--json]
macarchy setup --install-dependencies [--dry-run]
macarchy teardown [--dry-run] [--json]
macarchy update status [--json]
macarchy update check [--json]
```

Development builds find bundled themes from the checkout containing `.build`.
Installed builds resolve resources relative to the executable, so commands do
not depend on the current working directory. `--themes-root`, `--state-root`,
and consumer-specific path options are available for development and testing.

`update status` reads cached GitHub release evidence and the locally installed
Homebrew tap without refreshing either source. `update check` explicitly
refreshes the GitHub evidence. Macarchy may perform that same conditional
request at most once per 24 hours during an eligible interactive command; set
`MACARCHY_DISABLE_UPDATE_CHECKS=1` to disable only automatic checks.

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
share/doc/macarchy/theme-json.md
share/doc/macarchy/LICENSE
```

The theme package and normalized palette format is documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

Macarchy is available under the [MIT License](LICENSE). Bundled wallpaper
provenance and licensing are recorded inside each theme package.
