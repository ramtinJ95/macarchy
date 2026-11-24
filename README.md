# Macarchy

An opinionated macOS developer setup inspired by [Omarchy](https://omarchy.org/).
Tiling windows, a keyboard-first workflow, and one theme across your desktop and tools.

**Requires:** Apple Silicon, **macOS 26**, working [Homebrew](https://brew.sh/)
at **`/opt/homebrew`**, and **Xcode Command Line Tools**. Install these prerequisites
first; Macarchy checks them but does not install them. Intel, Rosetta and other
macOS versions or Homebrew prefixes are unsupported.

> **Alpha:** in daily use on real Macs; the complete fresh-account setup and native
> permission journey still need real-hardware qualification.
> [Releases](https://github.com/ramtinJ95/macarchy/releases) · [Changelog](CHANGELOG.md)

https://github.com/user-attachments/assets/b3efc2ce-e763-465a-a928-10628b43b8c0

## Install

Run this one command in an interactive terminal:

```sh
(/bin/bash -c 'set -eu; f="$(mktemp -t macarchy-install)"; trap '\''rm -f "$f"'\'' EXIT; curl --fail --silent --show-error --location https://raw.githubusercontent.com/ramtinJ95/macarchy/main/Scripts/install.sh -o "$f"; /bin/bash "$f"')
```

It downloads the complete installer before running it. You are trusting this
repository's **mutable `main` branch over GitHub HTTPS**, not a separately pinned
or attested script. See the [installer reference](Documentation/install.md) to
inspect it first or recover a partial installation.

The installer shows the tapped formula for review before asking for persistent
trust in **only `ramtinj95/tap/macarchy`**, including future formula revisions.
Homebrew verifies the release checksum, installs Macarchy, checks it, then opens
guided setup. It does not upgrade unrelated packages or run cleanup. Rerunning
an existing installation verifies it and prints next steps; it does not upgrade
or start setup again.

### Complete guided setup

1. **Choose components.** Arrows move, Space toggles, Enter reviews. Desktop,
   terminal and editor defaults start selected; optional extras start off.
2. **Review configuration and packages.** Existing `~/.zshrc`,
   `~/.config/kitty/kitty.conf` and `~/.config/nvim/` can be backed up and replaced
   with starters. Replacement starts selected but can be deselected per item.
   Review exact paths before the default-no **Install & apply** confirmation.
   Originals stay in timestamped sibling backups; dotfile symlink targets are
   never changed. Teardown restores originals and preserves starter edits too.
3. **Grant permissions manually when asked.** **Accessibility** lets yabai tile
   windows, skhd dispatch shortcuts, and the SketchyBar-launched Apple-menu helper
   open the native Apple menu. Setup names installed paths and opens System
   Settings; enable the responsible entries identified by macOS. Keep an ordinary
   app window open for yabai's check. **Automation → System Events** lets Macarchy
   match light/dark appearance. Setup asks before requesting native consent and
   verifies access without changing appearance. A terminal grant does not cover
   the bar or keybinding launcher. Optional features may need their own grants.

A saved profile or a `plan [ready]` heading is **not** an applied desktop. Read the
final result: blocked setup needs its named remedy; **configuration applied,
permissions incomplete** means configuration remains but the listed features are
unavailable or not yet verified. If cold-start Atuin/eza/Starship verification
times out, configuration is kept; run `macarchy reconcile`, then `macarchy doctor`.
For a saved profile, resume with:

```sh
macarchy setup guided --resume
macarchy setup status
macarchy setup doctor
```

Resume reuses your choices, skips satisfied packages and rechecks permissions;
configuration still needing changes requires fresh review. If no profile was saved,
use `macarchy setup guided`. For keybinding-origin Automation, use
**Command–Shift–T** and apply a theme with the opposite macOS appearance.
The bundled themes are dark: if already in Dark mode, first choose Light in
**System Settings → Appearance**, then apply a different bundled theme.
Answer macOS's consent dialog in that context. Terminal checks cannot verify
that grant and may still report it unverified—not denied. After a denial, enable
System Events for the responsible app in **Privacy & Security → Automation**.
See [permission and recovery details](Documentation/user-guide.md#permissions-and-resuming-setup).

## Try it

With desktop defaults applied, open Kitty: windows should tile and SketchyBar
should be visible. Try the theme picker and check that colors change. If a selected
feature does not work, use the status/doctor commands above rather than reinstalling.

```sh
macarchy menu
macarchy theme browse
macarchy keybindings show --effective
```

| Shortcut | Action |
| --- | --- |
| Control–Option–Space | Open the action menu |
| Command–Shift–T | Browse themes and backgrounds |
| Command–K | Search keybindings |
| Control–Option–C | Capture a screenshot to the clipboard |

Shortcuts require the corresponding defaults to be applied. Theme changes repaint
supported apps where possible; some need a reload or fresh session.

## Make it yours

The default setup includes yabai, skhd, SketchyBar, a focus ring, Kitty, zsh,
Starship, Atuin and LazyVim-based Neovim. Three themes ship with Macarchy:
Catppuccin Mocha, Tokyo Night and Kanagawa Wave; compatible Omarchy themes can
be imported. Pi, Codex, Herdr and Spotify integrations are opt-in.

Guided choices live in `~/.config/macarchy/profile.toml`; machine overrides go in
`~/.config/macarchy/machine.toml`. **Configure** in the action menu opens personal
sources. Keep your profile and ordinary tool configuration in your dotfiles—not
the whole Macarchy state directory. Never edit generated files. After profile
changes, choose **Review & apply configuration** in the menu.
See the [configuration guide](Documentation/user-guide.md#make-it-yours).

## Update or remove

```sh
macarchy update check   # Check for a new release
macarchy update         # Upgrade only Macarchy through Homebrew
```

Updating does not apply new configuration defaults or restart tools. Use the menu's
**Review & apply configuration** when you want those changes.

If enabled, run `macarchy clipboard disable` and `macarchy saver idle off` first;
those jobs have separate lifecycles. Preview configuration restoration, then run it:

```sh
macarchy setup teardown --dry-run
macarchy setup teardown
```

Teardown restores recorded originals (including replaced dotfile links), preserves
starter edits in sibling backups, and leaves installed dependencies and personal
files. Keep original backups intact until restoration succeeds; afterward, archives
remain until you delete them. `macarchy setup status` lists recorded backup paths.
If teardown fails, follow recovery guidance; do not delete state to force it.
**Only after successful restoration**, uninstall the CLI separately:

```sh
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  brew uninstall --formula ramtinj95/tap/macarchy
```

Uninstall does not purge Macarchy state. See [removal and recovery](Documentation/user-guide.md#updates-diagnostics-and-removal).

Independent project—not an official Omarchy port. No telemetry, no SIP changes,
and no yabai scripting addition.

## Go further

- [Installation and trust details](Documentation/install.md)
- [Everyday use](Documentation/user-guide.md#everyday-use) · [Customize your setup](Documentation/user-guide.md#make-it-yours)
- [Build from source](Documentation/development.md) · [Theme format](Documentation/theme-json.md)

## License

[MIT](LICENSE). Wallpaper credits and licensing live in their theme packages.

The release archive bundles [ttfx](https://github.com/omacom/ttfx) (MIT), a port of
[TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects), for the
animated screensaver. Its licence and notice, and the licences of the Rust crates
compiled into it, are installed in `share/doc/macarchy/ttfx/` under the Macarchy
prefix, for example `/opt/homebrew/opt/macarchy/share/doc/macarchy/ttfx/`.
