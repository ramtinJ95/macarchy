# Macarchy

Macarchy is a cohesive, theme-driven macOS environment. It owns one canonical
palette and command surface while integrating with the existing desktop through
explicit consumer boundaries.

Macarchy is independently authored and inspired by the broader
[Omarchy](https://omarchy.org/) project. It is not an official port.

## Development

Requirements: Apple Silicon macOS 26 and Swift 6.

```sh
swift test
swift run macarchy --version
swift run macarchy version --json
swift run macarchy theme list
swift run macarchy theme set catppuccin-mocha --dry-run
swift run macarchy theme next --dry-run
swift run macarchy theme status --json
swift run macarchy reconcile --dry-run
swift run macarchy doctor --json
```

Development builds discover built-in packages from the checkout containing
their `.build` directory. Installed builds discover them relative to the
executable at `../share/macarchy/themes`, independent of the caller's working
directory. `--themes-root` remains an explicit development/test override. User
packages come from `<state-root>/themes`, and the state root defaults to
`~/.config/macarchy`. Before activation, Macarchy verifies that current
appearance is readable and `/usr/bin/osascript` is executable. Kitty's
configuration must contain an `include` for the expanded absolute path
`<state-root>/state/adapters/kitty.conf`. After canonical commit, Macarchy
atomically rebuilds that ordinary bridge from `current/generated/kitty.conf`
before requesting Kitty reload; it does not edit Kitty's behavioral
configuration. Use `--state-root` and `--kitty-config` to inject development
paths. `--dry-run` validates rendering and required adapter preflight without
writing state or running a command. `theme next` follows the validated package
order and wraps at the end. `theme status` reads the canonical generation
manifest first and reports current, missing, stale, or unreadable reconciliation
state without treating it as active-theme truth.
Status exits nonzero when canonical state is absent or unreadable, status is
missing or stale, or a required adapter is not accepted; optional adapter
failure remains visible without making status unhealthy.

`reconcile [adapter...]` reruns all known adapters, or only the named adapters,
against the strict active generation and replaces its correlated reconciliation
status. A selected run preserves unselected results from a current correlated
record; without that baseline it reruns all known adapters. Unknown or duplicate
adapter identifiers and corrupt active artifacts fail before processes run.
`reconcile --dry-run` checks the active generation and adapter integration seams
without running processes or writing status. The `macos-appearance` adapter
reads the public global appearance preference without mutation and, when needed,
uses System Events' documented Appearance Suite to apply dark or light mode
live. A successful command is followed by another preference read; disagreement
is reported as drift. Appearance reconciliation briefly reacquires the
activation lock and rereads canonical `current`, preventing an older activation
from overwriting newer appearance state. The System Events command has a
two-second timeout. `doctor` independently reports canonical-state validity,
correlated reconciliation health, the non-mutating appearance preflight, and
Kitty's stable include without changing state. Apple Events authorization is
proved only when reconciliation actually needs to change appearance. Both
commands exit nonzero for required or diagnostic failures and support `--json`.

Activation recovers Macarchy-owned staging and temporary-pointer residue left
by an interrupted process. After a commit it retains the active generation and
the immediately previous reusable generation; older immutable generations are
atomically moved out of the live namespace while locked and removed after
publication. Cleanup failure is reported as a postcommit failure and never
described as a rollback.

Spicetify is an awaited optional adapter. Macarchy generates the selected color
scheme, runs a tracked `spicetify --no-restart refresh`, and restarts Spotify
only when it was already running. If Spicetify's macOS restart race leaves the
client closed, Macarchy relaunches it through Launch Services and verifies the
new process. A closed client remains closed. Failures are persisted and visible
but do not fail core theme activation.

Tests use temporary roots and never access `~/.config/macarchy`.

## Release layout

The supported release layout is:

```text
bin/macarchy
share/macarchy/build-info.json
share/macarchy/themes/<theme-id>/...
share/doc/macarchy/theme-json.md
share/doc/macarchy/LICENSE
```

Build a local layout from an arm64 release binary and its caller-supplied Git
revision, then smoke-test it from an unrelated working directory and temporary
`HOME`:

```sh
swift build -c release
Scripts/build-release-layout.sh \
  .build/release/macarchy .build/macarchy-release "$(git rev-parse HEAD)"
Scripts/smoke-release-layout.sh .build/macarchy-release
```

The layout script applies an ad-hoc signature and rejects non-arm64 binaries,
invalid revisions, or an existing destination. Release executables require
neither Developer ID signing nor notarization. Macarchy currently supports only
Apple Silicon macOS 26 and direct distribution outside the Mac App Store.

The package input schema and versioned normalized palette contract are documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

Macarchy is available under the [MIT License](LICENSE). Bundled wallpaper
provenance and licensing are recorded inside each theme package.
