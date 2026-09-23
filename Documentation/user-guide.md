# Macarchy user guide

[Back to Macarchy](../README.md) · [Development](development.md)

Detailed setup, customization and troubleshooting reference.

- [Install](#install)
- [Everyday use](#everyday-use)
- [Screenshot capture](#capture-a-screenshot)
- [Themes](#bring-an-omarchy-theme)
- [Screensaver](#choose-your-screensaver-image)
- [Configuration](#make-it-yours)
- [Updates and removal](#updates-diagnostics-and-removal)

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
Macarchy installation. Guided setup opens one selection menu: use Up/Down to
move, Space to toggle, and Enter to review. Providers, optional presets, native
settings and individual standard packages appear together with curated defaults
selected. The desktop choice includes tiling and Macarchy's default keybindings.
Package-only choices do not enable optional presets; selected providers still
require their dependencies. Native settings cycle through unmanaged, true and
false. Press q or Ctrl-C to cancel without saving.

The menu saves a small profile and displays the unified plan. One default-no
**Install & apply** confirmation authorizes its reviewed missing packages,
configuration adoptions, writable native starters, native settings and service changes. Setup then installs
and configures those selections without a separate apply or keybindings command.
Blocked prerequisites still stop setup visibly. An interactive terminal is required.

Enabled zsh, Kitty, Atuin, Starship and Neovim receive writable user configurations
at their standard application paths, separate from generated state. The plan shows
their exact contents before creation; existing files are never replaced. Declining
creates no starters. Run `macarchy setup guided --resume` with the same profile
options to review the retained profile again without rewriting it. Created user
files survive failures and teardown. Retained v0.9.6 questionnaires still resume
at their originally reviewed paths; upgrading does not relocate existing files.

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

To reapply only yabai configuration (including its wallpaper callback), preview
with `macarchy desktop apply --yabai-only --dry-run`, then run
`macarchy desktop apply --yabai-only`. This may restart yabai and run its configured
trusted hook; it does not reload SketchyBar, change keybindings, or reconcile theme
adapters. Use `macarchy reconcile wallpaper` separately when needed. Homebrew
callback paths follow the installed command link; upgrading does not automatically
rewrite older generated configurations.

```sh
macarchy menu                         # Profile editing, native viewers and maintenance checks
macarchy theme browse                 # Preview themes and backgrounds, then Apply
macarchy theme list
macarchy theme set kanagawa-wave
macarchy theme next
macarchy theme background next
macarchy keybindings show --effective # Search the managed shortcut list
macarchy setup status
macarchy setup doctor
```

The default shortcuts include **Control–Option–Space** for the action menu,
**Command–Shift–T** for the theme browser and **Command–K** for the keybinding
viewer. The action menu offers configuration, themes/backgrounds, keybindings, screenshots and maintenance:
use j/k or arrows to navigate, / to focus search, and Return to open. In search,
letters type normally; Escape returns to the list without clearing the filter.
Escape from the list dismisses. A highlighted row and mode hint show keyboard
focus. It closes before handing off to the existing viewer or terminal. Browsing changes nothing.
The native viewers use six-point accent focus outlines matching the desktop highlight.
The theme picker previews the outline with its
selected palette. These window-local borders need no extra permissions or border-service changes.
Maintenance checks run `setup plan`, `setup status`, `setup doctor`, or `update check`
in a centered, floating ordinary Kitty window. Every menu-launched terminal inherits
its native appearance settings, including square or rounded corners, fonts and spacing;
Macarchy supplies the active palette, not separate terminal decoration. The existing
desktop focus-ring provider decorates these windows normally.
Setup checks use the commands' normal portable
and machine profile defaults, including existing symlinks; `menu --profile PATH
--machine-profile PATH` forwards custom inputs to editors and setup checks. Output and the exit
result stay visible until Enter closes the window; checks never apply or install.
**Review & apply configuration** displays the existing layered profile's setup plan
and asks before authorizing its package installation, configuration adoption,
preferences and provider/service changes. It neither creates an onboarding profile
nor implicitly recovers interrupted setup. Changed plans require another review.
**Review & update Macarchy** reads the current stable release without writing the
update cache, shows installed/release/local-tap versions, then asks before refreshing
Homebrew metadata and upgrading only Macarchy. A changed release stops the upgrade;
a lagging tap reports packaging pending. Installation verification uses the existing
update workflow. Declining either review changes no configuration or packages;
declining update also leaves its cache and Homebrew metadata untouched. These actions
retain their results in the same window. Updates do not apply profiles or restart providers.
The managed SketchyBar clock includes a circular-arrow indicator when a newer stable
Macarchy release is known. Hover for details; click to open **Review & update**.
Its minute-by-minute cache refresh checks GitHub only when the last attempt is at
least six hours old, including after failed attempts. Failed checks show a warning
without discarding a previously known update. It never refreshes Homebrew metadata
or installs packages in the background. `MACARCHY_DISABLE_UPDATE_CHECKS=1` in
SketchyBar's environment disables network checks while retaining cached indicators.
Disabling the clock also removes this companion and its polling. After upgrading,
use **Review & apply** to activate changed generated bar configuration; installation
alone does not reload it. Personal native bar configurations can override defaults.
Update check refreshes its local check cache. Maintenance launch requires Kitty and
running yabai. Before launch, it replaces the `macarchy-maintenance` runtime rule,
matching only Kitty's fixed `Macarchy Maintenance` title, to float and center it.
The rule remains until yabai restarts (or `yabai -m rule --remove macarchy-maintenance`)
and is renewed on each launch; no config-file edit, remote control or service restart
is needed. Rule failure is reported rather than silently opening a tiled window.

Configure opens the portable profile, machine overrides, or the personal native
skhd override in Neovim. It edits the physical user source,
preserving dotfile links; missing profiles require confirmation before creation.
The editor uses an ordinary Kitty window, with normal yabai tiling and native
titles—not the maintenance window's floating style. Kitty starts through macOS
LaunchServices so closing the menu's invoking terminal does not kill it.
Generated state is never an editing surface.

**Configure → Keybindings** opens the layered profile's `keybindings.override`
file, never the generated skhdrc. If none is declared, it offers a comment-only
`overrides/keybindings.skhdrc` beside the physical portable profile, then separately
reviews its profile connection and keybinding-only apply. Packaged defaults remain
live; personal chords add bindings or replace default commands. Disable default
identities through `[keybindings] disabled` in the profile. This uses Macarchy's
bounded skhd parser, not arbitrary modes, includes or process maps. Optional
metadata remains a separately declared input requiring reviewed apply.

In these menu-launched sessions only, saving the selected native override—or
`keybindings.disabled` in a profile editor—can reload already-managed, initially
converged keybindings. Unchanged effective bindings need no reload. Validation failures
retain the working generation and the saved edit. Source-path changes, other
settings, inputs outside the selected editor, adoption and stale sessions require review;
save never invokes full setup, installs packages, or changes native preferences.
Broken profiles remain editable without automatic apply; fix/review them and
reopen the editor to enable scoped saves. Other Neovim sessions are unaffected.

**Configure → Neovim** opens the authoritative configuration directory, like
`nvim ~/.config/nvim`, using your normal Neovim directory browser in the same
normally tiled editor. Custom configuration paths are respected. Existing files and writable plugin locks are
preserved. If no tree exists, it previews an absent-only LazyVim starter. It
separately reviews missing theme links, any Neovim profile changes, and the
Neovim-only connection before opening the editor; it never applies other tools.
An active Macarchy theme is required for a new connection. Existing owned legacy
configurations use the established writable/standard-path migrations.

Theme preparation supports LazyVim/lazy.nvim configurations loading `lua/plugins`;
other plugin managers are not inferred from arbitrary Lua. Conflicting personal
theme files are reported, not overwritten. Cancelling retains earlier approved
steps; failed connection does not undo saved profile intent or personal files.
Native Lua saves have **no automatic apply or plugin-restore hook**. Behavior
changes take effect next instance; normal Neovim startup may bootstrap its own
configured plugins. The existing narrow theme watcher remains responsible for
live palette repaint.

**Configure → Starship / Atuin / Kitty / zsh** opens the authoritative personal
source, preserving custom paths and dotfile links. First connections separately
review absent-only starters, profile intent and provider-scoped connections;
they never run full setup. Kitty also reviews preparing its canonical theme cache
without signaling the app. Approved preparation remains after cancellation.
Existing zsh hooks and Kitty override directories retain their shape and need
reviewed environment plan/apply. Legacy managed Kitty/zsh settings open their
profile section instead of copying or replacing the generated configuration.

Native-file save feedback is read-only: Starship/Atuin check TOML and theme seams;
Kitty/zsh do not evaluate arbitrary native syntax. Personal saves are not rolled
back. Starship takes effect on new prompts, Atuin on new invocations, and zsh in
new shells. Use Kitty's native reload; Macarchy does not signal or restart it.
Kitty override directories use Neovim's directory browser, without per-child save
validation.

**Configure → Desktop / Bar** opens a personal `/bin/sh` configuration. First use
separately reviews an absent-only starter beside the physical profile
(`overrides/yabai.sh` or `overrides/sketchybar.sh`) and its profile connection:
`[yabai] configuration = "overrides/yabai.sh"` or the corresponding `[sketchybar]`
field. Dotfile links are preserved. Existing legacy hook code is copied into an
absent starter before its declaration is retired; an existing personal file is
never overwritten. Managed profiles without this field keep their original rules.

Defaults run first; personal code can replace settings, rules, item placement or
items rather than merely add to them. Macarchy snapshots the selected file into
its generation—do not edit the generated entry point. Save feedback checks syntax
without executing code. After a successful editor exit, changed input is checked
again and activates **only yabai via restart** or **only SketchyBar via reload**.
A reviewed first connection also activates on editor exit. There is no every-save
restart, watcher, adoption, installation or aggregate apply. Changed profile layers,
source links, packaged defaults or provider generations invalidate the session.
Unrelated settings already pending before the editor opens also block scoped
activation; keep the personal edit and review desktop apply instead. Older
generations without enough baseline evidence require that same explicit review.

Native status is **partial**: yabai verifies process/Accessibility, completion and
its wallpaper callback; SketchyBar verifies completion, a stable item inventory
and canonical bar color, not your personal layout or item behavior. Keep Macarchy's
hidden bar ready marker and theme color. SketchyBar personal code uses the existing
three-second runner; detached/background work is unsupported. Theme changes also
reload the bar and re-execute personal code. Only the selected file is snapshotted
and syntax-checked, not dynamically sourced dependencies; use explicit paths for
those dependencies rather than assuming the personal file's directory is the
runtime working directory.

Syntax failure keeps the edit without activation. Runtime failure is reported and
uses existing provider recovery, but cannot undo arbitrary shell side effects.
Saved files and profile intent remain for repair; they are not silently reverted.

New curated bindings take effect through reviewed keybinding apply; updating
the executable alone does not change an already-generated shortcut configuration.
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

### Capture a screenshot

Choose **Screenshot to clipboard** in the action menu, or press
**Control–Option–C** after applying the updated keybinding defaults.
The native macOS picker starts in region mode: drag to select, press Space to
switch to window selection, or Escape to cancel. The image goes directly to the
clipboard, without a screenshot file or clipboard-history service.

```sh
macarchy capture screenshot
macarchy capture screenshot --window
macarchy capture screenshot --save "$HOME/Pictures/capture.png"
```

`--save` additionally saves a PNG and copies that same image. The parent directory
must exist; an existing destination, including a symlink, is never overwritten.
This explicit save path uses a private temporary capture, removed after the
operation, rather than reading possibly unrelated current clipboard contents.
Don't hold Control during a file capture: macOS can redirect it to the clipboard
instead of producing the requested file. Saving and clipboard copying are separate
effects; if copying fails after saving, the error identifies the retained file.
`--json` reports only the outcome/path, not image data. Cancellation is not an error.

macOS owns the selector and screen permissions. If it denies access, review
**System Settings → Privacy & Security → Screen & System Audio Recording** for
the app/process responsible for the invocation. Terminal, menu and skhd launch
contexts may differ; Macarchy neither grants permissions nor automatically retries
a failed capture. Source-built CLI and menu captures were verified on macOS 26
with Kitty identified by macOS as the responsible app. First-use permission prompts
and skhd-launched captures are not yet qualified. The shared clipboard can still
be replaced by another application; Macarchy never restores an older clip.
Menu/shortcut failures display a native alert; CLI failures use
stderr and a nonzero exit. No capture, permission change or skhd reload happens
just by installing/building this code. Use the existing reviewed configuration
apply to activate the new shortcut; personal overrides and disabled chords remain
authoritative. Native macOS screenshot shortcuts are unchanged.

#### Annotate with Flameshot

Choose **Annotate screenshot** in the menu, or use **Control–Option–Shift–C**
after applying the updated defaults:

```sh
macarchy capture annotate
macarchy capture annotate --json
```

Select a harmless region, add arrows/shapes/text in Flameshot, then choose **Copy**.
Macarchy waits for completion and checks for a new clipboard image; it does not
save a file, enable history, change Flameshot preferences or manage its background
process. Flameshot retains its own Save/Upload controls: use Copy, not Upload, to
keep this workflow local. Other applications can still replace the shared clipboard.

The provider must be installed at `/Applications/Flameshot.app` and manually opened
before use. The standard package declaration uses the upstream
`flameshot-org/flameshot/flameshot-org-flameshot` cask. Homebrew's former `flameshot`
cask is disabled for failing Gatekeeper checks. **The upstream 14.0.0 cask uses the
same ad-hoc-signed application; changing taps does not fix signing.** Using it
requires your explicit trust decision and may require a manual, per-app **Open
Anyway** exception in macOS Privacy & Security. Macarchy does not grant trust,
bypass Gatekeeper, remove quarantine or grant Screen Recording permission. If you
do not accept that exception, keep using native screenshot capture instead.
An older Homebrew receipt may remain after moving the old app to Trash; this change
does not automatically migrate or uninstall it.

Flameshot 14 uses exit 2 for both cancellation and some capture failures. Therefore
Escape produces an explicit **aborted** error/alert, not a claim of successful
cancellation. Other failures retain provider diagnostics. A successful process
without a new image is also an error; there is no automatic retry or native fallback.
The existing native capture shortcut and cancellation behavior are unchanged.

### Copy text from a region

Choose **Copy text from region** in the action menu, or run:

```sh
macarchy capture ocr
macarchy capture ocr --json
```

Select readable English text; Apple Vision recognizes it on-device and copies
plain text, joining recognized lines with newlines. English (`en-US`) accurate
recognition with language correction is the current supported configuration,
not a promise of arbitrary language, handwriting or complex-layout accuracy.
There is no OCR-specific default shortcut; the existing capture shortcuts stay unchanged.

Escape reports `cancelled`; a blank region reports `noText` (with an informational
alert from the menu). Neither result writes the clipboard. Success reports
`copied`; stdout/JSON never contains recognized text. Errors remain explicit.
Do not hold Control during selection: macOS can redirect the image to the
clipboard instead of producing the requested file; Macarchy reports that as an
error and does not restore old clipboard contents.

The Apple screenshot picker writes a PNG in a private temporary directory.
Macarchy deletes it before recognition, including cleanup on capture failure;
cleanup failure stops publication and reports the directory for manual recovery.
A force-quit or system crash can leave that directory behind. No image/text
history, upload, telemetry or extra OCR application is enabled. Other clipboard
managers you run can still collect the resulting text.
Screen Recording permission belongs to the actual launching context, as with
native screenshots; Macarchy does not grant it or retry automatically.

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

The optional Herdr preset requires Herdr 0.8.2 or newer. Imported palettes include
sidebar, focused-row and selection backgrounds; built-in mappings retain Herdr's
native theme colors. After upgrading Macarchy, select the theme again to regenerate
its palette and live-reload Herdr. Installation alone does not activate a theme.

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

### Writable starter files

Native-source fields accept absolute paths or paths relative to the profile that
declares them, including personal symlinks. Each may explicitly select its own
standard application path, but not generated state or another provider's entry.
Tilde/environment expansion
is not supported. Copied inputs and legacy hooks still stay beside their profile.

For a new native configuration, preview an absent-only starter:

```sh
macarchy environment seed-configuration zsh --destination ~/.zshrc
macarchy environment seed-configuration kitty --destination ~/.config/kitty/kitty.conf
macarchy environment seed-configuration neovim --destination ~/.config/nvim
macarchy environment seed-configuration atuin --destination ~/.config/atuin/config.toml
macarchy environment seed-configuration starship --destination ~/.config/starship.toml
```

Repeat the chosen command with its exact `--approve` digest to create the file.
The parent directory must already exist. Existing files, directories and links
are never replaced. zsh and Kitty starters explicitly load live curated defaults;
remove that include to own all initialization yourself. Neovim, Atuin and
Starship copy shipped behavior once. Neovim seeds a directory with four narrow
theme links and downloads no plugins. Starship requires an active theme for its
initial reserved palette. Set `configuration` for zsh/Kitty or
`native_configuration` for the other tools, then review environment plan/apply
to connect it. Seeding alone changes neither the active configuration nor your
profile, and does not migrate existing personal behavior. Existing owned native
targets require the corresponding reviewed `migrate-* --source` cutover.

### Finding the user-owned configuration

```sh
macarchy environment configuration-source neovim --json
macarchy environment configuration-source zsh --profile /path/to/profile.toml
```

This read-only lookup uses the effective portable/machine profile and existing
native ownership receipts. It reports the declared path, resolved personal link
target and editing status; it never substitutes a generated file. Missing sources,
drift, source conflicts and required native setup return a nonzero exit status.
It opens no editor, evaluates no user configuration and applies no changes.
An editable profile input is not proof that pending connection changes are active.

### User-owned standard configuration

Fresh guided setup uses `~/.zshrc`, `~/.config/kitty/kitty.conf`,
`~/.config/atuin/config.toml`, `~/.config/starship.toml` and `~/.config/nvim/`.
These are personal files or deliberately chosen dotfile links, not mandatory
wrappers. Normal apply, updates and teardown preserve them. Macarchy maintains
only declared defaults and theme integration; arbitrary personal behavior is not
a convergence guarantee. Includes into Macarchy state become inactive after
teardown and may need deliberate removal from personal configuration.

For a profile in `~/.config/macarchy`, explicit standard sources look like:

```toml
[zsh]
configuration = "../../.zshrc"
[kitty]
configuration = "../kitty/kitty.conf"
[atuin]
native_configuration = "../atuin/config.toml"
[starship]
native_configuration = "../starship.toml"
[neovim]
native_configuration = "../nvim"
```

Keep these declarations when reapplying. Existing managed installations do not
switch merely because a profile path changed. First prepare your personal source
and review one scoped migration, for example:

```sh
macarchy environment migrate-standard kitty --source /absolute/dotfiles/kitty/kitty.conf
macarchy environment migrate-standard kitty --source /absolute/dotfiles/kitty/kitty.conf --approve 'digest-from-preview'
```

The same command accepts `zsh`, `atuin`, `starship` and `neovim`. zsh must own its
initialization; Kitty must end with exactly one canonical theme include described
below. Atuin and Starship must already select their reserved themes/palettes.
Neovim must already have its four theme links. Migration does not edit or merge
these personal files. Review any preparatory edits separately.

For the four files, migration replaces only the managed public entry with a
user-owned link; Kitty links its containing directory. Original dotfile link
spelling is preserved when it selects the chosen source. Neovim instead moves
the complete ordinary writable source directory to `~/.config/nvim` on the same
volume, preserving user files, plugins and lockfile without copying or downloading.
For an existing `nvim-native` tree, pass that directory as `--source`.

The preview identifies any retained original backup; it remains untouched and
is not automatically restored by later teardown. Update explicit profile sources
to the standard paths before reapply. Migration restarts no provider; open fresh
shells, reload Kitty or restart Neovim deliberately. Interrupted migrations use
the existing environment recovery path and never run unrelated providers.
Standard-path ownership requires a compatible CLI; older versions reject its
schema rather than overwrite personal files.

The older sibling-seeding and external-source commands below remain supported
for users deliberately keeping those layouts; they are not the new default.

### Live zsh configuration

To keep shell behavior in a writable file beside your profile:

```toml
[zsh]
configuration = "shell/personal.zsh"
```

For an external source, Macarchy manages only the `~/.zshrc` connection. It sources your
file on each new shell; apply, updates and teardown never rewrite that file.
Alternatively, explicitly select `~/.zshrc` itself as user-owned standard
configuration, using an absolute or profile-relative path. Sources must resolve
to a regular file outside Macarchy state. Dotfile symlinks remain user-owned.
Choose this mode or the legacy copied `zsh.hook`, not both.

Your source controls initialization order. To opt into the live curated shell
defaults (including selected Starship/Atuin initialization), add this once:

```zsh
source "$HOME/.config/macarchy/environment/current/zsh/defaults.zsh" || return 1
# Personal paths, aliases and overrides follow here.
```

Adjust the path for a custom state root. External wrappers also expose this path
as `MACARCHY_ZSH_DEFAULTS`; a standard file does not need that wrapper variable.
Do not also initialize those tools in your personal source. Alternatively,
own initialization yourself and omit the defaults include. The existing
environment plan/apply approval and teardown workflow manages the connection;
no personal files are automatically migrated. Status verifies shell startup,
not arbitrary personal behavior. Changes affect new shells.

### Live Kitty configuration

```toml
[kitty]
configuration = "kitty/kitty.conf"
```

An external source preserves its relative includes. Use it instead of the legacy
copied `kitty.override`. The external wrapper adds only the final theme include;
it does not silently layer its behavior underneath
your complete setup. To inherit curated defaults, explicitly include
`~/.config/macarchy/environment/current/kitty/defaults.conf` at the beginning
of your file (adjust for a custom state root), then add personal overrides.

Alternatively, select `~/.config/kitty/kitty.conf` itself as user-owned standard
configuration. End that file with exactly one
`include /absolute/home/.config/macarchy/state/adapters/kitty.conf` directive,
using your actual home and state root. No behavior wrapper is installed in this
mode. Keep external sources outside `~/.config/kitty`; all sources stay outside
Macarchy state. Apply and teardown preserve personal files and dotfile symlinks;
edits take effect on Kitty configuration reload. Paths may contain
spaces but not `$` expansion or control characters. Native includes are trusted
user configuration, not a sandbox; plan/status validate the connected file and
owned theme seam, not arbitrary nested includes or behavior.

### Writable Atuin configuration

To preserve the active Atuin settings as a writable native file:

```sh
macarchy environment migrate-atuin
macarchy environment migrate-atuin --approve 'digest-from-preview'
```

This seeds `~/.config/atuin-native.toml` once and reconnects
`~/.config/atuin/config.toml`. Edit that native configuration directly; profile
behavior options are seed-only after migration. Keep `[theme] name =
"macarchy-current"` to use the separately managed theme file. Edits affect fresh
Atuin invocations. Apply and theme changes preserve behavior; a changed selector
is reported as drift, never silently rewritten. History, sync and daemon state
are untouched. Existing destinations are never replaced, and teardown retains
the native file while restoring the original public entry. Use a compatible
Macarchy release before migrating; older versions reject this ownership mode.

To connect an existing native file on a new installation, declare its
profile-relative path instead of copied Atuin options:

```toml
[atuin]
native_configuration = "dotfiles/atuin.toml"
```

The file must already select `macarchy-current`. Symlinked dotfile sources are
supported; sources inside Macarchy state or managed provider entries are not.
The reviewed environment apply connects it without copying or rewriting behavior.
Do not combine this field with `atuin.configuration` or Atuin behavior options.

For an existing owned installation, reconnect explicitly before applying the
changed profile:

```sh
macarchy environment migrate-atuin --source /absolute/path/to/dotfiles/atuin.toml
macarchy environment migrate-atuin --source /absolute/path/to/dotfiles/atuin.toml --approve 'digest-from-preview'
```

This changes only Atuin's public connection and preserves both old and new
native files. The receipt retains the selected source when no profile source
is declared; a conflicting declared source blocks apply pending reviewed cutover.

### Writable Starship configuration

Starship uses a writable whole-file seed, not a simulated include:

```sh
macarchy environment migrate-starship
macarchy environment migrate-starship --approve 'digest-from-preview'
```

This seeds the active behavior and palette at `~/.config/starship-native.toml`
and switches only the owned public configuration link. An active theme is
required. Existing destinations are never replaced. Edit the native file;
fresh prompts read changes directly, and reapply preserves personal settings.
Profile behavior becomes seed-only after migration.

Macarchy requires `palette = "macarchy_current"` and manages only the seven
colors in `[palettes.macarchy_current]`. Other palettes, modules, comments and
format strings remain personal. Changed selection or unfamiliar reserved-table
syntax is reported as drift, not silently rewritten. A concurrent edit or
ambiguous publication retains displaced data beside the file as
`.starship-native.toml.macarchy-palette`; inspect both files before retrying.
Teardown preserves the native file. Use a compatible release before migrating.

A prepared dotfiles source may instead declare:

```toml
[starship]
native_configuration = "starship/starship.toml"
```

The profile-relative file must already select the reserved palette and contain
its seven color assignments. It cannot be combined with `starship.behavior`.
First reviewed apply connects it directly; existing installations use
`macarchy environment migrate-starship --source /absolute/source.toml`, then
repeat with the preview's `--approve` digest. Source symlinks are preserved;
palette reconciliation updates the resolved file, never the link. Neither apply
nor migration copies personal behavior. Sources within managed entries or
Macarchy state are rejected. Publication residue uses the source filename:
`.<filename>.macarchy-palette`.

### Writable Neovim configuration

The original managed Neovim configuration is immutable. Lazy's install, update,
sync and restore commands write `lazy-lock.json`, so they conflict with that
layout. To keep the **currently active setup** but make it editable, review:

```sh
macarchy environment migrate-neovim
macarchy environment migrate-neovim --approve 'digest-from-preview'
```

The migration seeds `~/.config/nvim-native` once and points `~/.config/nvim` to
it. It preserves the old dotfiles configuration and does not download plugins.
Restart Neovim afterward. Edit the writable configuration through `~/.config/nvim`;
Lazy owns its lockfile. Four reserved theme files remain linked to Macarchy.
Environment reapply updates those theme files, not your behavior or plugin lock.
The generated Neovim behavior remains a seed, not a continuously merged default.

Migration is explicit, not automatic on install or update. An existing destination
is never overwritten. Teardown restores the original entry and retains
`nvim-native` with your edits; its managed theme links are inactive after teardown.
Use a Macarchy version supporting this command before migrating—older versions
cannot manage the new ownership target. Reconnecting a retained native tree after
teardown requires a separately reviewed action, not an automatic reseed.

To connect a prepared native tree (including a retained one), declare a
profile-relative source:

```toml
[neovim]
native_configuration = "nvim"
```

This is exclusive with the older copied `neovim.configuration` input. The
directory must be writable, contain readable `init.lua`, and have a writable
ordinary `lazy-lock.json` if present. These four reserved paths must already be
symlinks to their matching files under
`~/.config/macarchy/environment/current/neovim/` (or your selected state root):

- `colors/macarchy-imported.lua`
- `lua/config/macarchy-theme.lua`
- `lua/macarchy/current.lua`
- `lua/plugins/colorscheme.lua`

First reviewed apply connects that tree without copying Lua or restoring
plugins. Existing ownership requires
`macarchy environment migrate-neovim --source /absolute/native-directory`,
then the same command with the preview's `--approve` digest. This cutover changes
only the public link; prepare conflicting theme paths deliberately rather than
expecting migration to overwrite them. Root source symlinks are preserved.
Sources inside managed entries/state, or containing those entries, are rejected.
Native Lua must load the theme integration through its plugin configuration;
arbitrary plugin behavior is not a convergence guarantee. Restart Neovim after
changing the connection.

GitHub port-443 timeouts are a separate connectivity problem. Logs are normally
under `~/.local/state/nvim/` (`nvim.log`, `lsp.log`, `mason.log`); Lazy task failures
are best inspected in the still-open `:Lazy` session or `:messages` / `:Noice history`.

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
fixes its position unless you set `automatic_clock = true` in `[sketchybar]`.
This enables monitor-dependent placement without changing your module arrays
(for example, when omitting media). `false` fixes the array position; omission
preserves the inherited-versus-explicit behavior. Click the clock for a
four-second ISO-week preview.

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
SketchyBar's own timer and display/wake events relaunch a missing helper, even
while the bar is hidden. A nonblocking ownership lock prevents duplicate workers.
Failures remain visible on the bar and in SketchyBar's service stderr log;
recovery needs no separate daemon or whole-bar reload.

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

The [standard Brewfile](../Environment/Brewfile) lists package-only defaults;
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
