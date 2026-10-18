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
settings and individual optional packages appear together. Core components start
selected; package-only extras start off. The desktop choice includes tiling and Macarchy's default keybindings.
Package-only choices do not enable optional presets; selected providers still
require their dependencies, shown as required rather than independently toggleable.
Optional package selections are saved in a personal Brewfile beside the profile.
Native settings cycle through unmanaged, true and
false. Press q or Ctrl-C to cancel without saving.

The menu saves a small profile and displays the unified plan. One default-no
**Install & apply** confirmation authorizes its reviewed missing packages,
configuration adoptions, writable native starters, native settings and service changes. Setup then installs
and configures those selections without a separate apply or keybindings command.
Blocked prerequisites still stop setup visibly. An interactive terminal is required.

For skhd and yabai, approved setup registers and starts missing native user services.
Rollback and teardown restore its previous running/stopped state and remove only
an unchanged registration created by Macarchy. Existing/custom LaunchAgents are
not replaced; explicitly disabled or failed loaded services require attention.
Accessibility grants remain manual; yabai must observe an ordinary application
window with Accessibility references before setup can succeed. Empty native configuration directories may
remain after rollback or teardown; user configuration is not deleted.

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
viewer. The action menu offers configuration, themes/backgrounds, keybindings, screenshots, image preparation, clipboard history, keep-awake, microphone controls and maintenance:
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

### Prepare an image

To share a photo or screenshot without its location, camera details, or full size,
prepare a separate copy. Choose **Prepare an image** in the action menu, pick a
preset, then choose **Use clipboard image** or **Choose file…**. Macarchy saves the
result, copies it to the clipboard, and shows it in Finder. **Cancel**, in the
dialog or in the file panel, writes nothing. Menu failures show in an alert.

You can also run:

```sh
macarchy image prepare ~/Pictures/beach.heic --preset share
macarchy image prepare --clipboard --preset small
macarchy image prepare diagram.png --preset png --no-copy --reveal
macarchy image prepare photo.jpg --preset small --output ~/Desktop/photo-small.jpg
macarchy image prepare photo.jpg --preset share --json
```

The command needs exactly one source, either a path or `--clipboard`, and a
`--preset`. It copies the result to the clipboard unless you pass `--no-copy`, and
it shows the result in Finder only when you pass `--reveal`. `--json` reports the
saved path, the pixel size, the byte count, and whether only the primary frame was
used. Errors go to stderr with a nonzero exit.

The presets are:

| Preset | Format | Longest edge | Quality |
| --- | --- | --- | --- |
| `share` | JPEG | Up to 2048 px | 0.8 |
| `small` | JPEG | Up to 1280 px | 0.7 |
| `png` | PNG | Original size | Lossless |

Every preset applies the photo's orientation to the pixels and converts the colors
to sRGB. Macarchy never enlarges an image, so a source smaller than the limit keeps
its size. JPEG has no transparency, so `share` and `small` turn transparent areas
white, while `png` keeps them. For an animated GIF or another image with several
frames, Macarchy uses the primary frame and says so in its output.

The result holds the pixels, an sRGB color profile, and the three fields the
encoder writes about the new file itself: color space, width, and height.
Macarchy copies none of the original's EXIF, GPS, TIFF, XMP, or IPTC metadata, so
the location, camera, capture date, and captions stay in the original.

Macarchy saves the result beside the original as `<name>-<preset>.<ext>`, such as
`beach-share.jpg`. A clipboard image goes to `~/Downloads` as
`clipboard-<yyyyMMdd-HHmmss>-<preset>.<ext>`, named after the local time. Macarchy
never replaces a file. If the name is taken, it tries `beach-share-2.jpg`,
`beach-share-3.jpg`, and so on up to `-99`, and then stops with an error. With
`--output`, Macarchy saves to the path you give. That file must not exist, its
folder must exist, and its extension must match the preset: `.jpg` or `.jpeg` for
`share` and `small`, and `.png` for `png`. Macarchy only reads the original, so its
contents and modification date stay the same.

The clipboard copy is one item that holds the saved file and its image data.
Macarchy reads only PNG, JPEG, HEIC, and TIFF images from the clipboard. If the
clipboard has no image, Macarchy reports `The clipboard has no image.` and writes
nothing. If copying fails after the file is saved, Macarchy keeps the file, reports
`Saved <path>, but copying it to the clipboard failed`, and exits with an error.

Image preparation does not edit, crop, or enlarge images, and it does not write HEIC
or WebP. Macarchy refuses source files larger than 256 MiB.

### Clipboard history

Macarchy uses the Maccy app to keep your clipboard history. It adds a full clear
that also removes pinned items, and an automatic clear that runs once 24 hours have
passed since the last clear. Maccy is an optional package, and no
Macarchy upgrade or setup run installs it. To install it and record it in your
personal Brewfile, preview and then approve the addition:

```sh
macarchy setup add-packages cask:maccy
macarchy setup add-packages cask:maccy --approve 'digest-from-preview'
```

You can also run `brew install --cask maccy`. Open Maccy once, so that it creates
its settings, then turn on clearing and the automatic clear:

```sh
macarchy clipboard enable
```

Maccy keeps its settings and history in its own protected folder. The first time
Macarchy reaches it, macOS asks whether the app you ran Macarchy from, such as
Kitty, may access data from other apps. Choose **Allow** once. The action menu runs
its commands under the same app, so one answer covers both. If you refuse, enable,
status and clear stop with an error that names this permission and change nothing.
Allowing it lets every command you run in that app read other apps' data, not just
Macarchy. The automatic clear never reaches that folder, so it never raises this
dialog.

To see your history, choose **Clipboard history** in the action menu, run
`macarchy clipboard open`, or press Maccy's own shortcut, **Shift–Command–C** by
default. If Maccy is not running, Macarchy starts it and says to press the shortcut,
in an alert when you use the menu. Macarchy adds no keybinding. Maccy's own
**Launch at login** setting decides whether it starts at login, and
`macarchy clipboard status` reports whether Maccy is running.

```sh
macarchy clipboard status         # Maccy, clearing, the two settings, the automatic clear
macarchy clipboard status --json
macarchy clipboard open
macarchy clipboard clear          # Deletes everything, including pinned items
macarchy clipboard auto-clear off # Stops the automatic clear; `on` starts it again
macarchy clipboard disable
```

Enabling changes two Maccy settings. It turns on `clearOnQuit`, so Maccy clears its
unpinned history when it quits, and `clearSystemClipboard`, so that clear also empties
the clipboard. Macarchy saves each setting's earlier value in
`~/.config/macarchy/run/clipboard-maccy-settings.json` first. Running `enable` again
keeps the saved values and turns either setting back on if you turned it off.
`macarchy clipboard disable` puts back each setting that still has the value Macarchy
set. If you changed a setting in Maccy since, your change stays, and `disable` says
which one. Disabling never deletes history. Every other Maccy setting, such as the
history size, ignored apps and types, and **Launch at login**, stays Maccy's.

To clear everything, choose **Clear clipboard history** in the action menu. It asks
`Clear all clipboard history, including pinned items?` first. **Clear** goes ahead,
and **Cancel** changes nothing. `macarchy clipboard clear` does not ask, so scripts
can call it. Clearing needs `macarchy clipboard enable` first. A clear does this:

1. If Maccy is running, Macarchy asks it to quit. Maccy runs its own clear as it
   quits. If Maccy has not quit after five seconds, Macarchy stops with an error
   and deletes nothing. If Maccy quits later, open it again.
2. Macarchy deletes Maccy's history database, `Storage.sqlite` with its
   `Storage.sqlite-shm` and `Storage.sqlite-wal` files, from
   `~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/`.
   It also deletes `Documents/image.png` in the same container, the image Maccy's
   Shortcuts action saves, which no Maccy clear removes.
3. Macarchy empties the clipboard, which also covers a Maccy that was not running.
4. If Maccy was running, Macarchy starts it again in the background, now with an
   empty history.

A full clear, with **Clear clipboard history** or `macarchy clipboard clear`, deletes
pinned items too, and it cannot be undone. The automatic clear keeps pinned items.
Macarchy deletes only those exact files. It never follows a symbolic link or deletes
a folder. If anything other than an ordinary file has one of those names, Macarchy
deletes none of them, restarts Maccy if it was running, and reports the path.

Macarchy knows where Maccy 2.7.1 keeps its history. With any other Maccy version, or
when that folder is missing from the container, Macarchy deletes no files. Maccy's
own clear still runs if Maccy was running, and the clipboard is emptied, but pinned
items may remain. The menu says so in its confirmation, which then asks
`Clear unpinned clipboard history?`. The command exits with an error, and the menu
shows it in an alert, for example:

```text
Cleared Maccy's unpinned history and the clipboard, but pinned items may remain: Maccy 2.8.0 is not the supported 2.7.1, so its storage layout is unknown. Maccy restarted.
```

`macarchy clipboard enable` also turns on the automatic clear, which limits how long
a copied password or token stays in your history. Once 24 hours have passed since the
last clear, Macarchy asks Maccy to quit, so Maccy clears its unpinned history. Then
Macarchy empties the clipboard and starts Maccy again in the background. If Maccy is
not running, Macarchy starts it in the background for its own clear and quits it
again. Whatever is on the clipboard at that moment is gone too. Every clear of the
history restarts the 24 hours, so a full clear from the menu or
`macarchy clipboard clear` also postpones the next automatic clear.

A Macarchy launch agent,
`~/Library/LaunchAgents/io.github.ramtinj95.macarchy.clipboard-auto-clear.plist`,
checks once an hour while you are logged in. launchd skips the checks that fall while
the Mac sleeps, so a due clear runs within about an hour of the Mac being awake. The
automatic clear differs from a full clear in these ways:

- Pinned items survive it.
- It never reaches Maccy's protected folder or its settings, so it raises no
  permission dialog while you are away. It works with any Maccy version.
- It relies on `clearOnQuit` and `clearSystemClipboard`, which `enable` turned on,
  and cannot check them in the background. `macarchy clipboard status` reports when
  either setting changed in Maccy. While `clearOnQuit` is off, an automatic clear
  still empties the clipboard but leaves the history.

`macarchy clipboard auto-clear off` unloads and deletes the launch agent and its
record, `~/.config/macarchy/run/clipboard-auto-clear.json`. It does not change
Maccy's settings. `macarchy clipboard auto-clear on` starts it again, with a new
24-hour window, and needs clearing enabled. `disable` also turns the automatic clear
off, and running `enable` again turns it back on. Macarchy installs the launch agent
only when no file has its name, and it changes or deletes only the exact file it
wrote. If another file has that name, `auto-clear on` and `auto-clear off` stop with
an error that names the file and how to remove it, and status reports the conflict.
`enable` still turns on Maccy's settings and then reports that error. `disable` leaves
the settings on, because the automatic clear relies on them while it may still run;
it reports the error and restores them once the launch agent is off.

Status shows whether the automatic clear is on, whether its launch agent is loaded,
the last clear, the next one, and the last failure. If an automatic clear fails, for
example because Maccy does not quit within five seconds or is no longer installed,
Macarchy keeps the time of the last clear and tries again an hour later. It shows an
alert at most once a day:

```text
Automatic clipboard clear failed
Maccy did not quit within five seconds, so its history and the clipboard were not cleared. Run `macarchy clipboard clear` to clear now.
```

The launch agent logs to `~/.config/macarchy/run/clipboard-auto-clear.stdout.log`
and `clipboard-auto-clear.stderr.log` in the same folder. The logs never contain
clipboard content.

Macarchy never reads Maccy's history. Of the `macarchy clipboard` commands, only
`save` reads the clipboard, and only its image. Status reports the Maccy version,
whether it runs, whether clearing is enabled, the two settings, and the automatic
clear's state, but no items, titles, or counts. Maccy does not record
content that an app marks as concealed or transient, which is what password managers
do with copied passwords.

If clipboard history does not behave as expected, check these points:

- `macarchy clipboard status` shows what Macarchy sees. Every command except
  `status` and `save` reports
  `Maccy is not installed. Install it with: brew install --cask maccy` when Maccy is
  missing.
- If `enable` reports that Maccy has not run yet, open Maccy once and run it again.
  Settings written before Maccy's first start might not reach it.
- If Macarchy reports that its record of Maccy's settings is damaged, it no longer
  knows their earlier values. Set `clearOnQuit` and `clearSystemClipboard` in Maccy
  as you want them, delete the file it names, and run `macarchy clipboard enable` if
  you want clearing again.
- If Macarchy reports that its record of the last clear is damaged, the automatic
  clear stops and shows an alert. After you dismiss it, the next hourly check shows
  it again. No automatic clear runs while that alert is open. Run
  `macarchy clipboard auto-clear on` to start a new 24-hour window.
- Menu launches show failures in an alert.

#### Use history in the terminal

To use an older item in a terminal, pick it in Maccy's history first. Picking an
item makes it the current clipboard. For text, `pbpaste` then prints it:

```sh
pbpaste > notes.txt
pbpaste | grep error
```

For an image, `macarchy clipboard save` saves the image that is on the clipboard
now, to a new file or to standard output:

```sh
macarchy clipboard save ~/Desktop/shot.png
macarchy clipboard save photo.heic --json
macarchy clipboard save - > shot.png
macarchy clipboard save - --format jpeg | ssh devbox 'cat > shot.jpg'
```

The file's extension picks the format: `.png`, `.jpg` or `.jpeg`, `.tiff` or `.tif`,
or `.heic`. If the clipboard already holds that format, Macarchy saves its bytes
unchanged. Otherwise Macarchy converts the image at its own size and keeps its color
profile and its metadata, where the new format can hold them. To share a copy without
metadata, use `macarchy image prepare --clipboard --preset share`. JPEG has no
transparency, so transparent areas turn white. The file must not exist, and its folder
must exist. Macarchy never replaces a file. On success, the command prints a line such
as this one:

```text
Saved the clipboard image to ~/Desktop/shot.png (PNG, 412 KB).
```

`--json` reports the saved path, the format as a type identifier such as
`public.png`, the byte count, and whether Macarchy converted the image.

With `-` instead of a file, Macarchy writes only the image to standard output. The
format is PNG unless you pass `--format jpeg`, `--format tiff`, or `--format heic`.
If standard output is a terminal, Macarchy refuses and suggests a redirect such as
`macarchy clipboard save - > image.png`. Errors go to stderr.

`save` reads only PNG, JPEG, HEIC, and TIFF data from the clipboard, and it works
without Maccy. If the clipboard has no image, Macarchy reports
`The clipboard has no image. For text, use pbpaste.`, writes nothing, and exits with
an error.

#### Reuse several items

Maccy 2.7.1 cannot select several items at once or paste them as a stack, so
Macarchy adds no paste queue. To paste several earlier items in order, reuse them
one at a time:

1. Open the history with **Clipboard history** in the action menu or with
   **Shift–Command–C**.
2. Select the first item you need and press **Return**. Maccy puts it on the
   clipboard.
3. Paste it with **Command–V**.
4. Repeat these steps for each remaining item.

**Option–Return** puts the item on the clipboard and pastes it in one step. For
that, Maccy needs the Accessibility permission in **System Settings → Privacy &
Security → Accessibility**.

To keep an item you reuse often, select it in the history and press **Option–P**,
Maccy's default pin shortcut. Maccy keeps pinned items at the top of the history and
gives each one its own keyboard shortcut. When the history is full, and when Maccy
runs its own clear, Maccy removes only unpinned items. Press **Option–P** again to
unpin the item. Maccy's **Pin to** setting can move pinned items to the bottom
instead. A full clear, with **Clear clipboard history** or `macarchy clipboard clear`,
deletes pinned items too.

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

### Keep the Mac awake

To keep the idle screensaver and idle lock from starting during a presentation, a
video, or a long-running job, turn on keep-awake. Choose **Toggle keep-awake** in
the action menu, or run:

```sh
macarchy keep-awake on              # Until you turn it off
macarchy keep-awake on --for 90m    # Turns off by itself after 90 minutes
macarchy keep-awake off
macarchy keep-awake toggle
macarchy keep-awake status --json
```

`--for` takes minutes, hours, or both, such as `30m`, `2h`, or `1h30m`, from one
minute up to 24 hours. The menu toggle always turns keep-awake on until you turn it
off, so use the command for a bounded session. Running `on` during a session
replaces that session with the new request. The exception is an unbounded request
while an unbounded session is on, which changes nothing.

While keep-awake is on, a cup icon appears left of the bar clock. Hover over it to
see when keep-awake ends, and click it to turn keep-awake off. A bounded session
ends on time even when the bar is not running, and the icon disappears within 30
seconds.

Keep-awake runs Apple's `caffeinate -d -i` as one process that Macarchy owns. The
display stays on, and the idle screensaver and idle lock do not start. You can still
lock the screen with **Control–Command–Q**, choose **Sleep**, or close the lid.
Logging out ends the session, and Macarchy does not restart it at login. Macarchy
changes no power settings. It never stops keep-awake sessions that other apps start,
including other `caffeinate` processes.

If keep-awake does not behave as expected, check these points:

- `macarchy keep-awake status` reports Macarchy's session. `pmset -g assertions`
  lists the `caffeinate` assertions that keep the display awake. Other apps can
  hold their own assertions.
- If turning keep-awake off fails, the session stays on and the command reports the
  error. Menu launches show the error in an alert.
- The bar icon is part of the generated bar configuration. After upgrading, use
  **Review & apply configuration** to activate it. Installing the upgrade alone
  does not reload the bar. Removing the clock module also removes the icon.
- If the icon shows `!`, its helper failed. SketchyBar's stderr log has the details.

### Control the microphone

To change which microphone the Mac uses, choose **Choose microphone** in the action
menu. It lists every microphone with the current default selected. **Choose** makes
your pick the default, and **Cancel** changes nothing. To mute or unmute the default
microphone, choose **Toggle microphone mute**. You can also run:

```sh
macarchy mic list                # * marks the default; shows how each one mutes
macarchy mic select "USB Mic"    # Exact name, or the identity from `mic list --json`
macarchy mic mute
macarchy mic unmute
macarchy mic toggle
macarchy mic status --json
```

Selecting and muting act on the system default microphone only. Apps that choose
their own microphone in their settings keep using it, so muting here does not
silence them. Check an app's own audio settings when it matters. Neither kind of
mute is a privacy guarantee.

Macarchy mutes in one of two ways and always says which:

- **Hardware mute.** When the microphone has its own mute control, Macarchy turns
  it on, for example `Microphone "USB Mic" muted (hardware mute).` Unmuting turns it
  off.
- **Silenced by input level, not a hardware mute.** When the microphone has no mute
  control but its input level can be changed, Macarchy saves the level, sets it to
  zero, and restores the saved level when you unmute. Any app, or the input volume
  in **System Settings** › **Sound**, can raise the level again.

A microphone with neither control is reported as `this microphone has no mute or
input-level control`, and Macarchy changes nothing.

If you raise a silenced level yourself, for example in **System Settings**,
Macarchy treats the microphone as live again. It drops the saved level and never
overwrites your change. Macarchy keeps a saved level for one microphone at a time,
so muting a different microphone first restores the one it silenced.

While the default microphone is muted, a slashed microphone appears left of the bar
clock. Hover over it to see which microphone is muted and how. Click it to unmute.

If the microphone does not behave as expected, check these points:

- `macarchy mic status` reports the default microphone and whether it is muted.
  `macarchy mic list` shows how each microphone can be muted.
- If an app still hears you while the microphone is muted, the app probably uses
  its own microphone setting rather than the system default.
- If a command reports that a change was accepted but not applied, the microphone
  ignored the request. When this happens partway through silencing by level,
  Macarchy restores the levels it already changed. Menu launches show the error in
  an alert.
- If a change stops partway, so that only some of a microphone's channels are
  muted or silenced, `macarchy mic status` reports it live, because the other
  channels still hear you. Macarchy keeps the saved levels of the channels it left
  at zero. Run `macarchy mic unmute` to finish restoring them, or `macarchy mic mute`
  to mute every channel.
- If you disconnect a silenced microphone, Macarchy keeps its saved level. After you
  reconnect it, unmuting restores that level while it is the default. If you mute
  another microphone while the first is still disconnected, the saved level is
  replaced, and you must raise the reconnected microphone's level yourself in
  **System Settings**.
- The saved level is stored in `~/.config/macarchy/run/microphone-silence.json`.
  Macarchy ignores this file if it is damaged, and then you must raise the level
  yourself.
- The bar icon is part of the generated bar configuration. After upgrading, use
  **Review & apply configuration** to activate it. Installing the upgrade alone
  does not reload the bar. Removing the clock module also removes the icon.
- If the icon shows `!`, its helper failed. SketchyBar's stderr log has the details.

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

The first connection of an unchanged curated Neovim starter at `~/.config/nvim`
previews plugin preparation before theme verification. It uses a temporary config
copy and a 180-second limit to download/build and verify the locked plugins,
without rewriting your files or lock. Plugin/cache changes survive rollback;
an unchanged, unconnected starter can be retried. Edited or external native
configurations and already-connected native setups manage plugins themselves;
ordinary reapply never restores the starter's plugin graph.

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
four-second ISO-week preview. The clock module also places up to three indicators
beside the clock. The circular arrow on its right appears when a newer Macarchy
release is known. On its left, the cup appears while keep-awake is on, and a slashed
microphone appears while the default microphone is muted. See
[Keep the Mac awake](#keep-the-mac-awake) and
[Control the microphone](#control-the-microphone).

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

The [optional catalog](../Environment/Brewfile) lists package-only extras, off by
default. The default `core` baseline includes only selected components' requirements
and explicit personal additions. Existing unselected software is not removed.
Add a personal Brewfile beside
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
arbitrary Ruby, hooks, or package options. An explicit `baseline = "standard"`
opts into the entire catalog. `baseline = "personal"` requires your own manifest
and never loads catalog extras. Both retain selected-provider requirements.
Omitting the baseline uses `core`, including in older profiles; explicit package
choices are preserved. Exclusions do not uninstall software.

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

If a reboot makes a retained SketchyBar, yabai, or skhd original fail ownership
inspection, do not edit receipts or re-adopt the provider. New adoptions record
a persistent volume UUID and inode instead of relying on a mount-time device
number. Older ownership records can be explicitly reviewed and migrated:

```sh
macarchy desktop migrate-ownership sketchybar --json
macarchy desktop migrate-ownership sketchybar --approve 'digest-from-preview'
```

Use `yabai` or `skhd` to review those providers separately. This command handles
the canonical `~/.config/macarchy` installation. Without `--approve` it is
read-only. Review the retained path, inode, observed volume UUID, and warning:
legacy records cannot prove their historical volume UUID. Approval binds the
otherwise matching surviving original to the observed volume. Other drift,
stale consent, or pending provider/setup transactions block migration.
Only the ownership record changes; originals, generated configuration, and
services remain untouched. Applying configuration updates is a separate review.

The same reboot-stable identity applies to an adopted Herdr directory symlink.
If theme switching reports `Herdr directory symlink` ownership drift after a
reboot, review the Herdr-specific migration rather than changing your dotfiles:

```sh
macarchy environment migrate-ownership herdr --json
macarchy environment migrate-ownership herdr --approve 'digest-from-preview'
```

Review its path, inode, observed volume UUID and historical-identity warning.
It requires the link target, permissions, metadata, and managed theme surface
to still match; a changed link, stale approval or pending transaction blocks it.
Approval adds only the persistent identity to the existing ownership record.
It does not change Herdr configuration, restart applications or activate a theme.
Repeat the theme selection after migration. New Herdr adoptions record the
stable identity immediately and need no migration after a reboot.

To undo unified setup, preview the restoration first:

```sh
macarchy setup teardown --dry-run
macarchy setup teardown
```

Teardown reverses recorded configuration changes and preserves unrelated data
and installed packages. It does not cover clipboard history: if you enabled
clearing, run `macarchy clipboard disable` first. That removes the hourly
automatic-clear job, restores Maccy's two settings and keeps its history. For
separately recorded legacy theme integrations,
also inspect `macarchy teardown --dry-run` before running `macarchy teardown`.
After restoration, remove the CLI separately if wanted:

```sh
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  brew uninstall --formula ramtinj95/tap/macarchy
```

Uninstalling does not purge your Macarchy state directory.
