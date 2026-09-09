# Macarchy

https://github.com/user-attachments/assets/2634deb7-fadb-46f4-995e-3425e18bb98d

An opinionated macOS developer environment inspired by
[Omarchy](https://omarchy.org/): a tiling desktop, coordinated themes, useful
developer tools, and a portable configuration you can reuse on another Mac.

Macarchy brings the pieces together through one CLI. Review the setup, keep the
defaults you want, and change your environment without maintaining a pile of
copied configuration files. It is independently authored, not an official port
or a replacement for your dotfile manager.

> **Status:** early alpha dogfooding for Apple Silicon on macOS 26.
> [v0.8.0](https://github.com/ramtinJ95/macarchy/releases/tag/v0.8.0) is the first
> integrated dogfooding release, distributed through the existing Homebrew channel.
> Fresh-user installation and first-use permission flows are not yet qualified.
> See [release history](CHANGELOG.md), or [build from source](#development).

## What you get

- **A coordinated desktop:** yabai tiling, skhd shortcuts, a Space-aware
  SketchyBar, and a theme-colored JankyBorders focus ring.
- **A ready-to-use terminal environment:** Kitty, zsh, Starship, Atuin, a
  LazyVim-based Neovim configuration, and themed bat, eza, btop, and Yazi.
- **One theme across your tools:** built-in palettes and wallpapers, a native
  theme browser, remembered background choices, and compatible Omarchy imports.
- **A useful package baseline:** developer tools and applications installed
  through Homebrew, with personal additions and individual opt-outs.
- **Portable choices:** a small TOML profile plus native override files, rather
  than a snapshot of one machine. Keep them in your own dotfile workflow.
- **Changes you can inspect:** guided setup, read-only plans, explicit approval
  before taking over existing configuration, status, diagnostics, and teardown.

Optional integrations for **Codex CLI, Herdr, Pi, tuicr, Spicetify, and Slack**
are off by default. Installing an application does not enable its integration:
the standard package set includes Herdr, Spotify, and Slack independently.

## Install

You need **Apple Silicon, macOS 26, and [Homebrew](https://brew.sh/)**.
Intel and older macOS versions are not currently supported.

Review the third-party tap before granting Homebrew's formula trust:

```sh
brew tap ramtinj95/tap
brew trust --formula ramtinj95/tap/macarchy
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
  brew install --formula --no-ask ramtinj95/tap/macarchy
macarchy setup guided
```

The Homebrew controls avoid unrelated automatic upgrades and cleanup during
Macarchy installation. Guided setup offers the curated defaults and opt-outs,
saves a small profile, then asks before installing missing packages, adopting
existing configuration, or applying the setup.

**Already have a profile?** Use `macarchy setup plan --profile /path/to/profile.toml`
and the [profile-driven workflow](#make-it-yours) instead. Guided setup will not
overwrite an existing profile.

Some steps remain yours: trust for selected third-party packages, Accessibility
for yabai/skhd, and Automation approval for macOS appearance control. The plan
and `macarchy setup doctor` report prerequisites. Pi, when selected, requires
manual installation with `npm install --global @earendil-works/pi-coding-agent`.

Macarchy keeps **normal SIP**, does not use yabai's scripting addition, and
does not grant permissions for you. It sends no telemetry. Homebrew owns package
installers and dependencies; their effects are not rolled back with configuration.

## Everyday use

```sh
macarchy theme browse                 # Preview themes and backgrounds, then Apply
macarchy theme list
macarchy theme set kanagawa-wave
macarchy theme next
macarchy theme background next
macarchy keybindings show --effective # Search the managed shortcut list
macarchy setup status
macarchy setup doctor
```

The default shortcuts include **Command–Shift–T** for the theme browser and
**Command–K** for the keybinding viewer. Browsing alone changes nothing.
The browser can move inactive user-installed themes to Trash after confirmation;
built-in and active themes are protected.

Macarchy ships **Catppuccin Mocha, Tokyo Night, and Kanagawa Wave**. Theme changes
update supported running applications where possible. Some changes take effect
on the next prompt or launch; Codex and tuicr need a fresh session. Selected
Spicetify integration automatically restarts an already-running Spotify client
after refreshing its palette, which may briefly interrupt playback; a closed
client stays closed. Commands report these limits and failures
rather than treating every application as live-reloadable.

Use Kitty's config reload for ordinary changes; shell startup changes need a
fresh login shell. Kitty does not guarantee live reload of window decorations.

### Bring an Omarchy theme

```sh
macarchy theme install --dry-run https://github.com/owner/theme-repository
macarchy theme install https://github.com/owner/theme-repository
```

Installation imports and activates a compatible theme from a public HTTPS
GitHub repository. The dry run previews the conversion first. Macarchy imports
palette data, supported wallpapers, and inert previews—not repository scripts
or application code. Unsupported content is identified in the report.

Slack remains a manual import: run `macarchy theme get slack`, then paste the
value under **Slack → Preferences → Appearance → Custom theme → Theme colors →
Import theme**. Slack may map the colors to its own supported palette.

### Choose your screensaver image

By default, Macarchy keeps an image of your chosen wallpaper in the stable folder
**`~/.config/macarchy/screensaver`**. Select that folder in macOS once:

1. Run `macarchy theme screensaver` after activating a theme with a background.
   This prepares the image without changing your desktop or macOS settings.
2. Open **System Settings → Wallpaper → Screen Saver** and choose **Custom**.
3. Under **Other**, select **Photos**, then **Options → Choose Folder**.
4. Press **Command–Shift–G**, enter `~/.config/macarchy/screensaver`, and select
   the folder. Confirm the options, then click **Preview**.

If your image shows black bars on an ultrawide or differently proportioned
display, try **Photos → Style → Ken Burns**, then **Preview**. This native style
pans and zooms the image rather than keeping it still; check the result on each
display. Macarchy preserves the source image's proportions and does not crop it
for a specific monitor or change the native screen saver style for you.

Use **Photos**, not macOS's Automatic option. Theme changes refresh the image
automatically; `macarchy theme screensaver` prepares it explicitly without
changing the desktop. The next Preview picked up image changes in supported-machine
testing. Live repaint of an already-running screensaver is not guaranteed.

To use a different image, open the theme picker, select a theme and preview one
of its backgrounds, then click **Use image as screensaver**. This saves a separate
choice **for that theme** without applying the theme or changing its wallpaper.
Each theme remembers its own choice. **Follow wallpaper** clears that theme's
separate choice and restores the default behavior.

Saved images are retained copies in Macarchy state, independent of package and
Homebrew version paths. They stay selected until you choose again or return to
following the wallpaper, even if the original package image changes. The Photos
folder does not change and needs no reselection.

The equivalent commands are:

```sh
macarchy theme background list kanagawa-wave
macarchy theme screensaver --theme kanagawa-wave --background <background-id>
macarchy theme screensaver --theme kanagawa-wave --follow-wallpaper
```

Omit `--theme` to change the active theme's choice. Saving an inactive theme's
choice leaves the currently exported image unchanged until that theme is active.
Export failures retain the saved choice and report how to retry; they never
silently revert to the wallpaper.

To opt out, choose another screensaver or Photos folder in System Settings.
Macarchy preserves that choice. To return, select Photos and the Macarchy folder
again. Keep personal files out of this generated folder. With a custom
`--state-root`, use `<state-root>/screensaver` instead. Themes without backgrounds
leave the previous desktop wallpaper unchanged; without a saved screensaver image,
they also retain the previous screensaver image.

The native **Control–Command–Q** lock background inherits the desktop wallpaper;
Macarchy does not offer a separate lock image or make locking start the saver.
Authentication, password and idle settings, startup/login, and FileVault remain
untouched. No custom screensaver plugin or additional permission is needed.

## Make it yours

The default portable profile is `~/.config/macarchy/profile.toml`. Omitted
settings inherit Macarchy's defaults. For example:

```toml
schema_version = 1

[kitty]
font_size = 15
background_opacity = 0.92

[yabai]
window_gap = 8

[focus_ring]
provider = "disabled"

[presets]
herdr = true

[keybindings]
override = "keybindings.skhdrc"
```

Put `keybindings.skhdrc` beside this profile to replace or add selected bindings:

```text
alt - j : yabai -m window --focus recent
```

Relative override paths resolve beside the profile. You can disable a role
with `provider = "disabled"` in its section: `desktop`, `top_bar`, `focus_ring`,
`terminal`, `shell`, `prompt`, `history`, or `editor`. An optional
`~/.config/macarchy/machine.toml` supplies machine-only overrides.

Review and apply your choices:

```sh
macarchy setup plan --profile ./profile.toml
macarchy setup apply --profile ./profile.toml
macarchy setup doctor --profile ./profile.toml
```

Apply does not implicitly approve the plan. If packages are missing, supply
`--approve-packages 'digest-from-plan'`. Existing configuration may also require
the plan's `--yabai-adopt`, `--keybindings-adopt`, `--sketchybar-adopt`, or
`--environment-adopt` approvals; `macarchy setup apply --help` lists the options.
Selected native preference changes require `--approve-preferences 'digest-from-plan'`.
Review fresh evidence on each Mac rather than copying approval values.

Edit your profile and native inputs, not generated application files. Keep those
inputs in dotfiles; do not sync the whole `~/.config/macarchy` directory, which
also contains machine-local state and backups. Merely editing a profile does
not start services or change running applications.

### SketchyBar modules

The default bar includes Apple menu, Spaces, adaptive calendar, battery, volume
and output-device controls, Wi-Fi traffic/details, CPU/memory, media, and native
menu-bar coordination. Palette colors remain managed by the active Macarchy theme.

Use positioned module arrays to enable, omit, or reorder individual modules:

```toml
[sketchybar]
left = ["spaces"]
center = []
right = ["clock", "volume", "cpu", "memory"]
```

Omitted arrays inherit defaults; empty arrays hide that position's modules.
A module may appear only once. An inherited clock moves to center when an
external display is online, otherwise compact right. Explicitly placing `clock`
fixes its position. Click it for a four-second ISO-week preview.

Volume supports scrolling (Ctrl for fine steps), a slider, safe output-device
selection, and right-click Sound settings. Wi-Fi never requests Location access:
its network-name row explicitly reports privacy restriction. Media requires
Homebrew `nowplaying-cli`; its private MediaRemote code runs outside Macarchy.

`apple` uses the separately packaged `macarchy-menu` executable. Enable its
Accessibility permission manually if required; `macarchy-menu --check` only checks
readiness, never prompts or grants permission. Private SkyLight use is confined
to that helper. Check permission again after upgrades and in the bar's launch
context; a successful terminal check does not guarantee another process context.

`toggle` coordinates the native auto-hidden menu bar with the managed bar using
public mouse-position polling. It does not change macOS preferences, require new
permissions, or launch the external `sketchybar-toggle` daemon. Stop an existing
personal toggle before adopting this module, or omit `toggle`. Macarchy refuses
that conflict rather than killing another process. Its owned process exits on
configuration replacement or bar shutdown; status detects a dead/stale helper.

### Spicetify prerequisites and interrupted setup

The optional `presets.spicetify` integration refreshes an **already initialized**
Spicetify installation and restarts Spotify only if it was already running,
including when restoring configuration. Restart completion is verified and
failures remain visible. Its `config-xpui.ini` must
contain an explicit absolute `spotify_path` pointing to an unpacked, writable
Spotify application. Setup checks this before activating a theme or changing the
desktop. Installing Spotify and `spicetify-cli` alone does not initialize it;
Spicetify backup, apply, and restore remain manual operations.

Recover an interrupted setup without starting a new apply:

```sh
macarchy setup recover
```

If an interrupted apply is already rolling back to the original Spicetify
configuration, but Spotify cannot be refreshed, you may explicitly accept
unverified Spotify runtime restoration:

```sh
macarchy setup recover --acknowledge-unverified-spicetify
```

This restores recorded configuration ownership and continues the existing
desktop/theme rollback. It does **not** repair Spotify or claim its runtime was
restored. A persistent **UNVERIFIED** warning remains in plan/status/doctor until
a later verified Spicetify refresh. It cannot bypass restoration of previously
managed Spicetify, ownership drift, or a mismatched recovery context. Use the same
state root and consumer-path options as the interrupted command; never delete
transaction files to bypass recovery.

After recovery, set `spicetify = false` in `[presets]` to defer the integration,
then review `macarchy setup plan` and obtain fresh approvals before applying.
Changing the profile alone does not recover an interrupted transaction.

### Opt into macOS preferences

Native preferences are **off by default**, including in guided setup. Currently
supported on macOS 26: Dock autohide and Finder filename extensions. Add only
the controls you want to manage:

```toml
[macos_preferences]
enabled = true
dock_autohide = true
finder_show_extensions = true
```

Unified setup previews these changes and requires their separate approval before
any setup mutation. To manage just this module:

```sh
macarchy preferences plan
macarchy preferences apply --approve 'digest-from-plan'
macarchy preferences status
macarchy preferences teardown --dry-run
macarchy preferences teardown
```

Only declared controls are owned. Removing a control or disabling the module
restores its original value on the next approved apply. Teardown does the same;
external changes block restoration rather than being overwritten. `preferences
doctor` diagnoses drift and unavailable access. Recovery instructions are explicit
when an interrupted OS write may still be running.

Changes take effect without restart or logout. Inspection may start Apple's
System Events helper; Finder must already be running. Unsupported macOS versions
or missing Automation access block visibly—Macarchy never prompts for or grants
access. Keep other preference editors idle during apply/recovery. A custom
`--state-root` relocates receipts, **not** the current user's native preferences.

### Choose your packages

The [standard Brewfile](Environment/Brewfile) lists package-only defaults;
selected providers add their own requirements. Add a personal Brewfile beside
your profile and reference it:

```toml
[packages]
brewfile = "Brewfile"
exclude_casks = ["spotify"]
```

```ruby
# Brewfile
brew "just"
cask "visual-studio-code"
```

Personal Brewfiles accept literal `brew`, `cask`, and `tap` declarations, not
arbitrary Ruby, hooks, or package options. Set `baseline = "personal"` in
`[packages]` to replace the standard extras with your own manifest; selected
provider requirements still apply. Exclusions do not uninstall software.

For a named addition without applying the rest of your setup:

```sh
macarchy setup add-packages formula:just
macarchy setup add-packages formula:just --approve 'digest-from-preview'
```

The first command previews; the approved command saves your declaration, then
installs a missing package or records adoption of an installed one. Use
`--machine-only` for a local addition. Homebrew remains the package manager;
Macarchy does not yet provide managed-package upgrades or removal.

## Updates, diagnostics, and removal

```sh
macarchy update check   # Check for a stable release
macarchy update         # Upgrade only Macarchy through Homebrew
macarchy setup doctor  # Diagnose the configured environment
macarchy doctor        # Diagnose the active theme and integrations
macarchy reconcile     # Retry theme integration with installed consumers
```

Self-update requires a stable Homebrew installation. Set
`MACARCHY_DISABLE_UPDATE_CHECKS=1` to disable automatic release checks; explicit
`update check` remains available. Many inspection commands offer `--json`;
check `--help` for each command's options.

Diagnostics distinguish missing prerequisites, external configuration, drift,
manual work, and restart requirements. If an operation is interrupted, follow
its reported recovery instructions rather than deleting state or forcing a
replacement. Redact local paths and configured commands before sharing reports.

To undo unified setup, preview the restoration first:

```sh
macarchy setup teardown --dry-run
macarchy setup teardown
```

Teardown reverses recorded configuration changes and preserves unrelated data
and installed packages. For separately recorded legacy theme integrations,
also inspect `macarchy teardown --dry-run` before running `macarchy teardown`.
After restoration, remove the CLI separately if wanted:

```sh
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  brew uninstall --formula ramtinj95/tap/macarchy
```

Uninstalling does not purge your Macarchy state directory.

## Development

Development builds require Swift 6.2 or newer on the supported Mac:

```sh
git clone https://github.com/ramtinJ95/macarchy.git
cd macarchy
swift build
.build/debug/macarchy theme list
```

Use `.build/debug/macarchy` in place of `macarchy` to run the current code.
It uses your normal configuration unless you supply alternate paths; building
alone does not install or activate anything.

```sh
swift format lint --strict --recursive Package.swift Sources Tests
swift test
swift build -c release
```

Tests use temporary roots, not your live Macarchy state. CI also validates the
release archive and installed layout. The theme format is documented in
[`Documentation/theme-json.md`](Documentation/theme-json.md).

## License

[MIT](LICENSE). Bundled wallpapers carry provenance and licensing information
inside their theme packages.
