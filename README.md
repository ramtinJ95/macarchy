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
[v0.7.1](https://github.com/ramtinJ95/macarchy/releases/tag/v0.7.1).
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
- Plans package, configuration, service, permission, and ownership changes
  before mutation.
- Records managed changes so teardown can reverse only what Macarchy created.

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
macarchy setup guided
```

The formula installs the immutable arm64 release archive and its bundled
themes, normalized-theme contract, changelog, and license. Guided setup creates
a sparse portable profile, shows the unified plan, and asks before adoption,
dependency installation, or provider mutation. The profile-driven plan remains
read-only: it reports selected providers, missing packages, configuration and
service actions, permissions, adoption evidence, and manual boundaries.

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
macarchy keybindings apply [--profile <path>] [--adopt <evidence-digest>] [--dry-run] [--json]
macarchy keybindings status [--profile <path>] [--state-root <path>] [--json]
macarchy keybindings list [--json] [--skhd-config <path>] [--catalog <path>]
macarchy keybindings list --effective [--profile <path>] [--state-root <path>] [--json]
macarchy keybindings doctor [--json] [--skhd-config <path>] [--catalog <path>]
macarchy keybindings doctor --effective [--profile <path>] [--state-root <path>] [--json]
macarchy keybindings show [--skhd-config <path>] [--catalog <path>] [--state-root <path>]
macarchy keybindings show --effective [--profile <path>] [--state-root <path>]
macarchy desktop plan [--profile <path>] [--json]
macarchy desktop apply [--profile <path>] [--dry-run] [--json]
macarchy desktop status [--profile <path>] [--json]
macarchy desktop doctor [--profile <path>] [--json]
macarchy desktop teardown [--dry-run] [--json]
macarchy environment plan [--profile <path>] [--state-root <path>] [--json]
macarchy environment apply [--profile <path>] [--adopt <evidence-digest>] [--dry-run] [--json]
macarchy environment status [--profile <path>] [--json]
macarchy environment doctor [--profile <path>] [--json]
macarchy environment teardown [--dry-run] [--json]
macarchy reconcile [adapter ...] [--dry-run]
macarchy doctor [--json]
macarchy setup guided [--output-profile <path>] [--machine-profile <path>]
macarchy setup plan [--profile <path>] [--machine-profile <path>] [--state-root <path>] [--package-impact] [--json]
macarchy setup apply [--profile <path>] [--machine-profile <path>] [--install-dependencies] [--adoption-file <path>] [--yabai-adopt <digest>] [--keybindings-adopt <digest>] [--sketchybar-adopt <digest>] [--environment-adopt <digest>] [--json]
macarchy setup status [--profile <path>] [--machine-profile <path>] [--json]
macarchy setup doctor [--profile <path>] [--machine-profile <path>] [--json]
macarchy setup teardown [--profile <path>] [--machine-profile <path>] [--dry-run] [--json]
macarchy teardown [--dry-run] [--json]
macarchy update status [--json]
macarchy update check [--json]
macarchy update
```

Development builds find bundled themes from the checkout containing `.build`.
Installed builds resolve resources relative to the executable, so commands do
not depend on the current working directory. `--themes-root`, `--state-root`,
and consumer-specific path options are available for development and testing.

## Managed daily tool environment

The `environment` lifecycle manages M3's Kitty, zsh, Starship, Atuin, Neovim,
and daily TUI environment as one outcome. `plan` composes package-owned defaults
with the portable profile,
reports selected-package prerequisites, provider ownership, exact artifacts,
and one aggregate adoption digest without mutation. `apply` publishes one
immutable generation, installs stable provider bridges, reconciles the active
theme, and verifies a fresh login shell before finalizing.

Review existing configuration before adopting it:

```sh
macarchy environment plan --profile /path/to/profile.toml --json
macarchy environment apply \
  --profile /path/to/profile.toml \
  --adopt 'sha256:digest-from-the-reviewed-plan'
macarchy environment status --profile /path/to/profile.toml
macarchy environment doctor --profile /path/to/profile.toml
```

The digest covers every selected external entry, lexical link destination,
retained identity and metadata, Kitty inventory, provider selection, native
inputs, and rendered artifacts. Apply recaptures that evidence before changing
any entry. If the plan reports no adoption requirement, omit `--adopt`.

All curated providers are enabled when the profile is absent. Roles can be disabled
without Macarchy touching their external configuration:

```toml
schema_version = 1

[terminal]
provider = "kitty" # or "disabled"

[shell]
provider = "zsh" # or "disabled"

[prompt]
provider = "starship" # or "disabled"

[history]
provider = "atuin" # or "disabled"

[editor]
provider = "neovim" # or "disabled"
```

Optional presets are closed, typed opt-ins and remain disabled when the profile
is absent. Codex CLI, Herdr, Pi, Slack, Spicetify, and tuicr integrations are selected
independently:

```toml
[presets]
codex = true
herdr = true
pi = true
slack = true
spicetify = true
tuicr = true
```

Selected Spicetify requires `spicetify-cli` 2.44.0 or newer and a Spotify app
with a parseable bundle version. Missing dependencies use the approved
Homebrew formula and cask; compatible existing installations remain external.
After reviewed adoption of only `current_theme` and `color_scheme`, Macarchy
owns those selectors and an absent exact `Themes/text/color.ini` link. A
complete exact Stow tuple remains external and unclaimed. Refresh uses
`spicetify --no-restart refresh`: Spotify is never opened, quit, signalled, or
restarted. A running client reports `restart_required`; a closed client remains
closed and receives the palette on its next launch. Backup/apply/restore remain
manual Spicetify operations.

Selected Slack requires the official app at version 4.51.191 or newer and a
valid renderer-v2 four-color canonical payload. Apply changes no Slack state;
it publishes only selection authority and reports `manual_required` with the
exact payload and per-workspace import path. Disable and teardown remove only
that authority. `macarchy theme get slack` remains available even when the
preset is disabled.

Selected Codex CLI uses the approved official Homebrew `codex` cask when the
command is missing. A compatible pre-existing `/opt/homebrew/bin/codex`,
including an npm-provided binary at that path, remains external and unclaimed.
Macarchy requires exact `codex-cli X.Y.Z` version output at or above 0.151.0,
with no upper cap, before configuration mutation. `environment apply` owns only
`theme = "macarchy-current"` under the canonical `[tui]` table in
`~/.codex/config.toml` and
`~/.codex/themes/macarchy-current.tmTheme`. It preserves every unrelated byte,
including Codex rewrites, and restores an adopted divergent selector at its
exact original boundary. Authentication, sessions, project trust, MCP servers,
plugins, hooks, caches, histories, and all other Codex state remain external.
A complete personal Stow topology—with an external `config.toml` link, a
separate external `themes` directory link, and the nested exact theme
link—remains `external_exact` and is never written through or adopted; partial
or divergent external tuples block. Codex loads theme changes only in a fresh
TUI launch, so apply and theme reconciliation report `restart_required` and
never restart a running session. `macarchy setup plan` reports a selected
missing cask while leaving Codex integration configuration to `environment apply`.

Selected Herdr uses the approved official Homebrew `herdr` formula when the
command is missing. A compatible pre-existing `~/.local/bin/herdr` remains
external and unclaimed. Macarchy requires exact `herdr X.Y.Z` version output at
or above 0.8.0, with no upper cap. `environment apply` owns only
`[theme].name` and the established 16 keys under `[theme.custom]` in the
canonical `~/.config/herdr/config.toml`. The three optional fields introduced
in Herdr 0.8.2 are deliberately outside that contract; those and any newer
optional theme fields keep Herdr's defaults, so Macarchy does not claim a
complete custom palette beyond its 16 managed tokens. Existing unrelated bytes
and provider rewrites are preserved. A reviewed `~/.config/herdr` directory
symlink is the sole Stow exception: Macarchy preserves the lexical directory
symlink and writes the resolved regular `config.toml` target atomically. Other
symlink topologies block. A complete authenticated older Herdr theme journal is
migrated into aggregate ownership and its exact Catppuccin selector boundary is
restored on disable; partial, stale, or unauthenticated evidence blocks.

Herdr's configuration path cannot be overridden while this preset is selected:
`HERDR_CONFIG_PATH` is unsupported because Macarchy cannot inspect or prove
ownership of a second live configuration. A running Herdr server must return
the exact successful reload result with no diagnostics; partial or ambiguous
responses fail and roll the environment change back. A stopped server reports
that the configuration will take effect on next launch. Macarchy never starts,
stops, restarts, configures, or otherwise owns the Herdr service. The unified
setup plan reports a selected missing formula while leaving Herdr configuration
to `environment apply`.

Pi is a manual prerequisite: install it yourself with
`npm install --global @earendil-works/pi-coding-agent`. Macarchy reports that
instruction only and never executes npm. Selected Pi must report a parseable
version of at least 0.84.3; there is no upper version cap. The lifecycle owns
only the root `theme` member in `~/.pi/agent/settings.json` and the watched
`~/.pi/agent/themes/macarchy-current.json` link. It preserves every unrelated
settings byte and all Pi conversations, credentials, extensions, models,
sessions, caches, and other private state. Pi 0.84.4 watches replacement of that
directory entry, not replacement of the stable generated target, and exposes no
external reload API. When Macarchy owns the link, or a complete older setup
record owns it, theme reconciliation atomically refreshes the watched entry and
reports `applied`; running sessions repaint automatically. For a complete exact
externally owned Stow tuple, reconciliation preserves the link inode and
metadata and reports the accepted `restart_required` boundary instead. Existing
Pi sessions then need Pi's `/reload` action or a new launch to use the active
palette.

Run `macarchy setup plan` after selecting tuicr to review its approved Homebrew
formula and install that formula before `environment apply`. Environment apply
never installs software; it reports and blocks before configuration mutation
when a selected executable or compatible Pi, Herdr, or Codex version is
missing. For tuicr, the
environment lifecycle owns only the root `theme` selector in
`~/.config/tuicr/config.toml` and the `macarchy-current.toml` palette and
`macarchy-current.tmTheme` syntax links under `~/.config/tuicr/themes`. It
preserves unrelated configuration and does not own repositories, review
behavior, credentials, caches, or other tuicr settings. Theme commands follow
the last successfully applied environment selection, not un-applied profile
edits, and a running tuicr session must be restarted to observe a newly
activated theme. Complete exact Stow-owned Codex, Pi, or tuicr tuples remain external
and are never adopted. For Pi this includes never replacing the externally
owned watched-link inode merely to request repaint. Complete older setup-owned
integrations remain active until explicitly migrated or torn down; partial
tuples block rather than being guessed or repaired.

Common options remain sparse. Advanced inputs use native provider files beside
the resolved profile source:

```toml
[kitty]
font_size = 15
background_opacity = 0.92
override = "kitty"

[zsh]
editor = "nvim"
hook = "zshrc"

[starship]
behavior = "starship.toml"

[atuin]
search_mode = "daemon-fuzzy"
keymap_mode = "vim-insert"
configuration = "atuin.toml"

[neovim]
configuration = "nvim"
```

The Kitty override is a bounded, symlink-free directory containing
`kitty.conf`; exact relative includes must resolve inside it. The zsh hook is
trusted local code but is copied, not executed, during planning. Starship
behavior cannot define `palette` or `palettes`, and Atuin behavior cannot define
`[theme]`, because those values remain owned by Macarchy's active theme.

When `neovim.configuration` is absent, Macarchy supplies its curated, locked
LazyVim baseline. When present, it accepts a complete profile-relative native
configuration, including arbitrary Lua and binary native files. Planning copies
that tree as inert bytes; it never edits or executes the source. The tree must
contain `init.lua`, use Lazy with a `lazy-lock.json`, and leave
`lua/plugins/colorscheme.lua`, `lua/config/macarchy-theme.lua`,
`lua/macarchy/current.lua`, and `colors/macarchy-imported.lua` unclaimed. All
symlinks fail except the prior Macarchy integration's one
`lua/macarchy/current.lua` canonical-pointer link: its destination must be an
absolute path ending in `/.config/macarchy/current/generated/neovim.lua`.
Macarchy also owns the `aether`, `catppuccin`, `kanagawa.nvim`, and
`tokyonight.nvim` entries in the generated `lazy-lock.json`; every other lock
entry remains native-config owned. Recognized older Macarchy theme files are
replaced in the generated copy only. Apply restores and verifies the pinned
plugin graph from a temporary writable copy before validating the immutable
effective configuration's active theme and fresh headless editor.

Generated state lives under
`~/.config/macarchy/environment/generations/e-<id>` behind `environment/current`.
Macarchy retains adopted files and lexical symlinks by inode until teardown.
Atuin history and daemon state remain untouched. Neovim plugin/cache state stays
in Neovim's normal data directories and is retained across teardown.
Disabling a previously managed role restores only that role's adopted entries;
an entirely disabled session installs nothing.

Use teardown only after reviewing its aggregate preflight:

```sh
macarchy environment teardown --dry-run
macarchy environment teardown
```

Drift in any owned entry blocks all restoration. Interrupted apply or teardown
is recovered before another mutation and requires the command to be rerun.
Kitty receives its supported reload signal, Starship changes on the next prompt,
and Atuin changes on the next history interface. Existing shells keep their
already-loaded startup state; `environment doctor` launches a fresh login shell
and reports trusted hook behavior as semantically unverifiable.

## Managed desktop shell

The default desktop outcome combines no-SA yabai tiling, the authoritative
managed skhd shortcuts, and a Space-aware themed SketchyBar. Run
`macarchy setup plan` first to inspect the `yabai`, `skhd`, and
`sketchybar` package prerequisites. The
third-party Homebrew formulae remain an explicit trust decision; Macarchy never
runs `brew trust`. yabai and skhd also require the user-granted Accessibility
permission reported by `desktop doctor`.

The same portable profile used by managed keybindings controls both desktop
roles. An absent profile selects the curated `yabai-skhd` and `sketchybar`
defaults. Sparse controls and role opt-outs do not require copying packaged
configuration:

```toml
schema_version = 1

[desktop]
provider = "yabai-skhd" # or "disabled"

[yabai]
layout = "bsp"
window_gap = 8
hook = "personal-yabai.sh"

[top_bar]
provider = "sketchybar" # or "disabled"

[sketchybar]
left = ["spaces"]
center = []
right = ["volume", "clock"]
hook = "personal-sketchybar.sh"
```

Hook paths are relative to the resolved profile source. They are bounded,
validated, copied into sealed generated state, and never executed during
planning. The SketchyBar hook has a three-second execution bound and cannot
leave supported detached or background work. A configured hook makes status
honestly `partial` because Macarchy verifies its managed namespace but cannot
claim complete behavior equivalence.

Review the aggregate plan and its exact adoption evidence before mutation:

```sh
macarchy desktop plan --profile /path/to/profile.toml
macarchy desktop apply --profile /path/to/profile.toml --dry-run
macarchy desktop apply \
  --profile /path/to/profile.toml \
  --adopt 'sha256:yabai-plan-digest' \
  --keybindings-adopt 'sha256:skhd-plan-digest' \
  --sketchybar-adopt 'sha256:sketchybar-plan-digest'
macarchy desktop status --profile /path/to/profile.toml
macarchy desktop doctor --profile /path/to/profile.toml
```

Only digests required by the reviewed plan need to be supplied. Apply preflights
all selected packages, provider conflicts, hooks, service boundaries, the
Accessibility-dependent yabai query, and the canonical theme before the first
provider mutation. It then converges yabai, skhd, and SketchyBar under one
durable aggregate transaction, releases the activation lock, and reconciles
the selected wallpaper and SketchyBar theme adapters. A later-provider or
required-theme failure rolls completed provider boundaries back in reverse
order.

`desktop status` correlates desired profile input with provider generations,
ownership, service/runtime evidence, skhd lifecycle evidence, the active theme,
and any interrupted aggregate transaction. `desktop doctor` adds selected-role
package and manual-prerequisite findings. Neither command repairs or hides
drift.

Teardown previews and then restores SketchyBar, skhd, and yabai in reverse
dependency order:

```sh
macarchy desktop teardown --dry-run
macarchy desktop teardown
```

Existing regular files and supported symlinks are retained and restored at
their established exact-inode boundaries. Portable profile and hook sources
remain user-owned; immutable generations and lifecycle records remain under
`~/.config/macarchy` and must not be copied into dotfiles. If status reports
`recovery_required`, rerun the same aggregate apply or teardown command first;
the durable transaction completes forward after its commit boundary and rolls
back otherwise.

`keybindings list`, `doctor`, and `show` preserve source-based inspection for
externally managed skhd configuration. They parse enabled key-to-command
bindings from the selected skhd file without executing them. List preserves
chained shell commands as opaque display text, normalizes modifier order,
ignores disabled lines, and returns explicit nonzero diagnostics for unsupported
enabled syntax or duplicate effective chords. The default source is
`~/.config/skhd/skhdrc`.
Optional labels, categories, ordering, and search aliases come from the strict
metadata-only `~/.config/macarchy/keybindings.toml` catalog. Catalog entries
are keyed by normalized chord identity and cannot contain commands. The
source-based `keybindings doctor` warns about missing or stale metadata and
parser/duplicate diagnostics, while unreadable or invalid inputs fail
explicitly.

Pass `--effective` to `keybindings list`, `doctor`, or `show` to inspect desired
managed keybindings composed from packaged defaults and the portable profile,
plus their agreement with the canonical generated state. This route is
explicit so source-based inspection remains available before Macarchy adopts
provider ownership. Its JSON reports use schema version 2 and the distinct
`keybindings_list_effective` or `keybindings_doctor_effective` operation;
legacy source reports retain their established schema-version-1 contracts.
Effective list and popup rows follow metadata order with normalized identity as
the tie-break, while generated `skhdrc` bytes retain deterministic identity
order. The shared effective model composes desired inputs, generation agreement,
authoritative provider ownership, pending recovery, generation-correlated
lifecycle evidence, and bounded UID-scoped skhd executable and argument
evidence. Missing, drifted, externally managed, blocked, and recovery-required
states are labeled as desired or proposed rather than active, and
`doctor --effective` fails closed on corrupt or interrupted transaction
evidence.

`keybindings status` reports that complete model directly. Its schema-version-1
`keybindings_status` JSON distinguishes `clean`, `converged`, `drifted`,
`externally_managed`, `blocked`, and `recovery_required`. Convergence proves
validated inputs, generated bytes, provider ownership, a successful reload or
restart recorded for that generation, and a supported UID-scoped process
without an explicit `-c` selection. The lifecycle record proves command
success and observable process evidence, not complete in-memory binding
equivalence: skhd exposes no query for its effective binding table. Missing
legacy lifecycle evidence is drift and plans a reload rather than being
silently treated as converged.

`keybindings plan` is the read-only entry point for managed keybindings. It
composes immutable packaged defaults with an optional sparse native override,
explicit disabled default identities, and an optional metadata-only overlay.
The default portable profile is `~/.config/macarchy/profile.toml`. To use only
the packaged defaults, leave that file absent and inspect the exact effective
bytes:

```sh
macarchy keybindings plan
macarchy keybindings plan --json
```

An explicit missing `--profile` is an error. For sparse customization, keep the
profile and its referenced files together in the portable source you control:

```text
keybindings/
  profile.toml
  keybindings.skhdrc
  keybindings-metadata.toml
```

Relative input paths resolve beside the resolved profile source, including
when the default profile path is a symlink into that directory. A profile can
replace one default, disable another, and add a binding without copying the
untouched packaged inventory:

```toml
schema_version = 1

[keybindings]
override = "keybindings.skhdrc"
metadata = "keybindings-metadata.toml"
disabled = ["alt-k"]
```

```text
alt - j : yabai -m window --focus recent
cmd - x : open -a 'Example'
```

The override is strict native skhd syntax. A matching normalized chord replaces
the packaged command; a new chord adds one. Do not both disable and override
the same identity. Unknown disables, duplicate chords, and unsupported enabled
syntax block the plan before mutation.

Metadata is optional and never contains commands. Each user record is complete
and either replaces packaged display metadata or describes a user addition:

```toml
schema_version = 1

[[bindings]]
identity = "cmd-x"
label = "Open Example"
category = "Applications"
order = 10
aliases = ["sample"]
```

The plan reports replacement, addition, disablement, source attribution,
deterministic effective bytes, current-generation state, and provider-entry
ownership in human or JSON form. It never publishes a generation, changes
`~/.config/skhd`, reloads skhd, or executes a configured command.
The expanded effective-state JSON contract uses schema version 2; apply keeps
its established schema-version-1 mutation report.

`keybindings apply` consumes the same plan model. It publishes and selects an
immutable generation and claims `~/.config/skhd/skhdrc` transactionally.
Existing regular files, entry symlinks, and bounded directory-level symlinks
require `--adopt <evidence-digest>`, where the digest is copied from the
reviewed plan. The digest authenticates the previewed entry kind, exact link
text, source bytes, and bounded inventory; any mismatch blocks before
keybinding state mutates. When the preferred entry is absent but `~/.skhdrc`
exists, the fallback is also external state requiring reviewed adoption; it is
never shadowed as a clean install, remains untouched while the preferred
managed entry is active, and becomes authoritative again after teardown.

Regular-file adoption restores exact bytes plus the authenticated restorable
metadata contract: permissions, owner, group, supported nonrestrictive flags,
modification time, extended attributes, and ACL. Immutable, append-only,
no-unlink, restricted, and data-vault flags are rejected before mutation
because copying them before backup and restoration cleanup could strand
transaction artifacts. Access, change, and creation times are not part of the
contract because reads and safe inode replacement necessarily change them.
Multiply linked regular entries are also not eligible for adoption.

Private recovery claims use a per-record nonce and a no-follow inode marker.
Recovery removes only a claim carrying that exact marker; an empty, partial, or
same-target foreign replacement is preserved and blocks for explicit recovery.

Installing or adopting the entry restarts the incumbent skhd service once
because skhd 0.3.9 does not rediscover a newly created preferred config path on
reload; later same-entry generation updates use reload. A lifecycle or
postcondition failure restores the prior pointer, entry, ownership record, and
service path. Inspection retries a bounded before/after canonical snapshot and
fails closed if transaction, generation, provider, lifecycle, or process
identity changes during inspection. Teardown verifies all restoration
artifacts without mutation before restoring the exact supported prior state.

Preview before applying. These commands use the same composition path; only the
last command publishes state:

```sh
macarchy keybindings plan --profile /path/to/keybindings/profile.toml
macarchy keybindings apply --profile /path/to/keybindings/profile.toml --dry-run
macarchy keybindings apply --profile /path/to/keybindings/profile.toml
```

On an initial unclaimed install, apply claims an absent `skhdrc` only inside an
existing ordinary `~/.config/skhd` directory. It does not require `--adopt`
because no prior entry is displaced. Once that entry is managed, reapply keeps
the provider path, publishes a changed generation when needed, and uses reload;
it also does not require `--adopt`.

An existing unclaimed regular file, leaf symlink, or eligible bounded
directory-level symlink is never adopted implicitly. Review the plan's exact
adoption delta and `provider.adoption_evidence_digest`, then pass that digest
back unchanged:

```sh
REVIEWED_EVIDENCE_DIGEST='sha256:copy-the-exact-plan-value-here'
macarchy keybindings apply \
  --profile /path/to/keybindings/profile.toml \
  --adopt "$REVIEWED_EVIDENCE_DIGEST" \
  --dry-run
macarchy keybindings apply \
  --profile /path/to/keybindings/profile.toml \
  --adopt "$REVIEWED_EVIDENCE_DIGEST"
```

Apply recaptures the evidence before replacement. If the entry kind, link
text, source bytes, or bounded inventory changed after review, adoption blocks
without publishing keybinding state and requires a new plan.

To review a packaged-default update, save `keybindings plan --json` output
before and after installing the updated package and diff the two files. The
plan shows inherited command and digest changes while leaving `profile.toml`,
the native override, and metadata overlay untouched.

Saved JSON reports contain complete configured commands and absolute paths for
profile, override, metadata, state, provider, and adoption sources. Create them
with restrictive permissions (for example, run `umask 077` first), keep them
out of source control, and redact commands and absolute paths before sharing.

Portable inputs and generated state have separate ownership boundaries:

```text
portable source (user-owned)              runtime state (Macarchy-owned)
profile.toml                               ~/.config/macarchy/keybindings/
keybindings.skhdrc                           current -> generations/k-<id>
keybindings-metadata.toml                    generations/k-<id>/skhdrc
```

Do not copy a generated `skhdrc`, generation manifest, `current` link, or
transaction evidence into dotfiles, and do not edit generated files. Edit the
portable profile, override, or metadata and plan again instead.

`keybindings show` opens source-correlated rows, or metadata-ordered attributed
managed rows with `--effective`, in a short-lived searchable AppKit popup. The
popup distinguishes converged evidence from desired, proposed external,
drifted, blocked, and recovery-required state; it never describes a proposed
managed row as the authoritative external source. It follows the active
Macarchy theme, supports keyboard search and navigation, closes on Escape or
focus loss, and remains strictly informational: selecting a row never executes
its displayed command.

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
pointer remains the only theme authority. Herdr receives a generated 16-token
custom palette within the bounded contract described above and repaints through
its live config reload. Macarchy edits only the allowlisted theme
selector/custom keys, rejects unowned custom colors, and removes its custom
values when returning to a built-in. Missing wallpaper provenance is
reported as a personal-use warning; imported assets are not release-eligible
without verified rights.

Slack does not expose a supported theme automation API, configuration file, or
preferences deep link. Every canonical generation stores a four-color payload
for Slack's window background, selected items, presence indication, and
notification badges as inert `generated/slack.txt` data. A committed activation
prints it proactively only while applied Slack preset authority is enabled.
Slack maps these values to its supported
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

## Unified setup lifecycle

`macarchy setup guided` asks about every core provider and daily tool, then
offers each optional preset. Core choices default on and presets default off.
It writes only choices that differ from those defaults to a new portable
profile, normally `~/.config/macarchy/profile.toml`; `--output-profile` selects
another destination. Guided setup never follows or replaces an existing file,
link, or directory. Use the noninteractive profile-driven commands below when a
profile already exists.

After writing the profile, guided setup prints the same unified plan described
below. Missing external prerequisites stop the flow for explicit remediation.
Each adoption digest requires a separate default-no confirmation, missing
Homebrew dependencies require installation confirmation, and applying the plan
requires a final default-no confirmation. Cancelling or encountering a blocked
plan retains the new profile for review.

`macarchy setup plan` compiles built-in defaults, the optional portable
`~/.config/macarchy/profile.toml`, and the optional machine-local
`~/.config/macarchy/machine.toml` into one effective core model. An explicit
`--profile` or `--machine-profile` path must exist; an absent default file is an
empty layer.

`setup plan`, `setup status`, and `setup doctor` also report a read-only
`package_inventory` (nested under `plan` for status/doctor). It previews 51
additional standard declarations plus selected provider requirements: 62 packages
with default providers (47 formulae and 15 casks). Provider opt-outs still remove
their package requirements. Each package retains any built-in standard declaration
and contributing provider's profile provenance separately. Standard Slack,
Spotify and Herdr packages do not enable their optional behavior/theme presets.

The report separates declarations from Homebrew installation records and runtime
availability; package-only declarations have no runtime probe. A working external
executable does not establish a Homebrew installation. Local listings are corroborated
with inert receipts; package Ruby is not loaded, metadata is not refreshed,
and aliases or old tap identities are not silently resolved. Unavailable,
ambiguous, or unsupported observations remain explicit.

The inventory is **read-only**: apply does not yet provision the standard baseline
or implicitly adopt packages. Existing provider dependency installation and core
readiness are unchanged; no Brewfile is imported. Installer compatibility and
dependency effects are not verified by this report. Third-party trust remains manual;
installation does not authorize permissions, accounts, services/helpers,
model/toolchain downloads or shell hooks. Installed packages outside the proposed
set are not implicitly adopted.

`setup adopt-packages` explicitly records ownership of named, already installed
declarations without installing, upgrading or removing anything:

```sh
macarchy setup adopt-packages formula:jq cask:slack --json
macarchy setup adopt-packages formula:jq cask:slack --approve <reviewed-digest> --json
```

Output is scoped to the named packages, including their receipt evidence and
declaration provenance; use plan/status/doctor for the full package inventory.
The first command only previews. Approval binds the named declarations, receipt
contents and file identities, current adoption ledger, profile paths and local
home/state context. Macarchy revalidates under the setup lifecycle lock before
atomically publishing `state/setup/packages.json`. No unrelated theme/provider
setup runs, and the existing provider `--adoption-file` contract is unchanged.
An identical repeat is a no-op; dependencies and undeclared packages are never
implicitly adopted. `--profile`, `--machine-profile` and `--state-root` select the
same inputs used by other setup commands.

Package inventory reports `adopted`, `unadopted`, `missing`, `changed` or `unknown`.
Missing, ambiguous and changed evidence blocks adoption; this slice does not
overwrite an existing adoption after installation drift. Records remain visible
when a declaration leaves the profile, and configuration teardown retains them.
An interrupted confirmation after publication reports `commit_unverified` rather
than pretending to roll back; inspect the inventory before retrying. Receipt
evidence does not verify installed file integrity or waive later install/update/
prune impact gates. Homebrew can change independently of Macarchy's setup lock.

`setup plan --package-impact` explicitly downloads official metadata into
disposable scratch storage and adds `package_impact` to the report. Homebrew's
native formula resolver runs with network access and writes outside scratch
denied. This optional preview requires `sandbox-exec` on Apple Silicon macOS 26
and the qualified, unmodified Homebrew revision
`571381a8a7b42bf38f94c65b6be340466945d217` (`6.0.21-81-g571381a`). Other revisions
and `brew.env` configurations are not yet qualified; there is no unrestricted
fallback. Normal plan/status and apply are unchanged.

Resolved formula entries show candidate versions and pending dependencies,
including whether those dependencies already have Homebrew installations.
Missing/stale evidence, casks and third-party taps stay explicit. The overall
report remains **partial**, not a complete installation plan: conflicts,
dependent repair and apply-time revalidation are still unqualified. It grants
no installation or adoption authority. An unavailable inspection returns a
failure exit code while retaining the ordinary inventory. Metadata staging is
bounded to 180 seconds and 64 MiB of response bodies; no package archives are
downloaded, taps trusted, or persistent Homebrew configuration changed.

The machine layer uses the same strict schema as the portable profile. Its
declared fields replace portable fields individually, arrays replace as whole
values, and omitted fields continue to inherit portable intent or built-in
defaults. Relative native inputs resolve beside the layer that declares them,
so machine-only paths do not leak into a dotfiles-owned portable profile.

Keep the sparse portable file with the dotfiles reused on each Mac. A machine
that should not run the managed top bar can add only this local `machine.toml`;
no hostname branch or copy of the portable settings is needed:

```toml
schema_version = 1

[top_bar]
provider = "disabled"
```

Run `setup plan` with the same portable profile on each Mac and review its local
prerequisites and adoption evidence before applying. A role opt-out is a
desired-state transition: apply restores or removes only that role's owned
provider state while other managed roles remain converged. Unknown providers,
unsupported values, and contradictory combinations in the merged effective
profile block before actions or mutation.

The plan delegates to the existing keybinding, desktop, and environment
planners and reports their complete machine-readable results under
`components`. Its summary exposes selected providers, the active theme or
clean-machine Catppuccin Mocha default, scoped Homebrew formulae and casks,
external trust or npm prerequisites, owned file boundaries, service lifecycle,
Accessibility and Automation boundaries, and per-domain adoption digests.
Missing packages are planned work; malformed or contradictory profile input,
unsafe ownership, drift, or interrupted component state blocks the plan before
actions are emitted.

Planning does not write files, run lifecycle mutations, install software, or
change canonical state. After reviewing it, `macarchy setup apply` uses that
same layered model to bootstrap the canonical theme and converge desktop and
environment providers in order. Missing selected formulae and casks are
installed only when `--install-dependencies` is supplied; Homebrew remains the
package owner and mutator. Existing state that requires adoption is rejected by
default rather than claimed implicitly. To approve the exact machine state
shown by the current plan, pass its digests with `--yabai-adopt`,
`--keybindings-adopt`, `--sketchybar-adopt`, and
`--environment-adopt`.

Several approvals can instead be kept in one bounded JSON file and supplied
with `--adoption-file`; omit keys for components that do not require adoption:

```json
{
  "schema_version": 1,
  "yabai": "<digest from setup plan>",
  "keybindings": "<digest from setup plan>",
  "sketchybar": "<digest from setup plan>",
  "environment": "<digest from setup plan>"
}
```

The file and named options are mutually exclusive. Adoption digests authorize
the exact files, links, and provider state observed on one machine; stale or
copied evidence fails against a newly compiled plan. Keep portable intent in
`profile.toml` and machine-specific intent in `machine.toml` rather than
persisting adoption authorization in either profile.

Unified provider mutation is journaled separately from each provider's own
transaction. Apply recompiles the reviewed plan after acquiring the setup lock
and stops without mutation if it changed. If a later apply stage fails, started
stages are preflighted and rolled back in reverse order; the apply reports
`rolled_back` rather than convergence. An interrupted apply is rolled back
before another apply can start, while an interrupted teardown resumes forward in
environment/desktop/theme order. `setup plan`, `setup status`, and
`setup doctor` remain blocked while recovery is pending, and teardown
`--dry-run` reports `recovery_required` without changing the journal. Recovery
also refuses a different home or consumer-path context. Homebrew packages stay
outside this rollback boundary and remain externally owned.

`macarchy setup status` and `macarchy setup doctor` inspect the same theme,
desktop, environment, capability, and ownership boundaries. A successful
repeat apply is a no-op. Preview `macarchy setup teardown --dry-run` before
restoring setup-owned environment, desktop, and canonical-theme state in
reverse order. Teardown retains Homebrew packages and does not remove an active
theme that predates unified setup.

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
macarchy setup plan
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

Spicetify and Slack are disabled without applied preset authority. Their
generated artifacts remain deterministic canonical data, but only selected
Spicetify reconciliation and selected Slack notices run proactively.

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
