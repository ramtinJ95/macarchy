# Macarchy

An opinionated macOS developer setup inspired by [Omarchy](https://omarchy.org/).
Tiling windows, a keyboard-first workflow, and one theme across your desktop and tools.

https://github.com/user-attachments/assets/2634deb7-fadb-46f4-995e-3425e18bb98d

> **Early alpha · Apple Silicon · macOS 26**
> Actively dogfooded, but fresh-Mac setup and first-use permission flows are not yet
> fully tested. [Releases](https://github.com/ramtinJ95/macarchy/releases) · [Changelog](CHANGELOG.md)

## The setup

- **Desktop:** yabai tiling, skhd shortcuts, SketchyBar, and a matching focus ring.
- **Terminal & editor:** Kitty, zsh, Starship, Atuin, and LazyVim-based Neovim.
- **Themes:** a visual picker, wallpapers, and coordinated colors across supported
  apps. Ships with Catppuccin Mocha, Tokyo Night, and Kanagawa Wave;
  imports compatible Omarchy themes.
- **Daily actions:** a searchable menu for configuration, themes, screenshots,
  and reviewed updates.
- **Your configuration:** choose the pieces you want and keep personal settings
  in your own dotfiles. Optional integrations include Pi, Codex, Herdr and Spotify.

Independent project—not an official Omarchy port. No telemetry, no SIP changes,
and no yabai scripting addition.

## Get started

Install [Homebrew](https://brew.sh/) first. Review the tap before trusting its formula:

```sh
brew tap ramtinj95/tap
brew trust --formula ramtinj95/tap/macarchy
HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
  brew install --formula --no-ask ramtinj95/tap/macarchy
macarchy setup guided
```

Guided setup lets you choose desktop tools, terminal/editor components and extra
packages. Use arrows to move, Space to toggle, then Enter to review the plan.
Confirm **Install & apply** to install and configure your selections; existing
configuration requires explicit approval before Macarchy takes it over.
Use an interactive terminal. The Homebrew flags avoid unrelated automatic
upgrades and cleanup.

Some permissions remain manual: **Accessibility** for yabai/skhd and
**Automation** for macOS appearance control. Setup reports missing prerequisites;
Macarchy never grants permissions for you. Optional integrations are off by
default—installing an app does not enable its integration.

Already have a setup? Read the [installation guide](Documentation/user-guide.md#install)
before connecting existing configuration.

## Make yourself at home

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
| Control–Option–Shift–C | Annotate a screenshot with Flameshot |

Shortcuts require the corresponding defaults to be applied.
Theme changes repaint supported apps where possible; some need a reload or fresh
session. Optional Spotify theming can restart an already-running Spotify.

## Make it yours

Your choices live in `~/.config/macarchy/profile.toml`; optional machine-specific
overrides go in `~/.config/macarchy/machine.toml`. Guided setup creates the profile
for you. Open **Configure** in the action menu to edit your profile or personal
tool configuration.

Shell, terminal and editor settings stay in ordinary user-owned files such as
`~/.zshrc`, `~/.config/kitty/kitty.conf` and `~/.config/nvim/`. Keep these and your
profile in your dotfiles—not the whole Macarchy state directory, which also holds
generated files and backups. Edit personal sources, never generated files.

After changing your profile, choose **Review & apply configuration** in the menu.
You see the plan and confirm before it changes your setup. For package choices,
custom shortcuts and advanced options, see the [configuration guide](Documentation/user-guide.md#make-it-yours).

## Updates & troubleshooting

```sh
macarchy update check   # Check for a new release
macarchy update         # Upgrade Macarchy through Homebrew
macarchy setup status   # See the configured environment
macarchy setup doctor   # Diagnose missing prerequisites or configuration problems
```

The menu also offers **Review & update Macarchy**. Updating the CLI does not
automatically apply new configuration defaults or restart your tools; use
**Review & apply configuration** when you want those changes.

If setup is interrupted, follow its recovery instructions rather than deleting
state. See the [troubleshooting and removal guide](Documentation/user-guide.md#updates-diagnostics-and-removal)
for more detail, including how to preview restoration before uninstalling.

## Go further

- [Customize your setup](Documentation/user-guide.md#make-it-yours) — profiles, dotfiles and packages
- [Everyday use](Documentation/user-guide.md#everyday-use) — menu, screenshots, themes and screensaver
- [Update, troubleshoot or remove](Documentation/user-guide.md#updates-diagnostics-and-removal)
- [Build from source](Documentation/development.md) · [Theme format](Documentation/theme-json.md)

## License

[MIT](LICENSE). Wallpaper credits and licensing live in their theme packages.
