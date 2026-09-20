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

Choose your tools, review the plan, then confirm **Install & apply**.
Nothing is applied before confirmation; macOS permissions remain yours to grant.
The Homebrew flags avoid unrelated automatic upgrades and cleanup.

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

Shortcuts require the corresponding defaults to be applied.
Theme changes repaint supported apps where possible; some need a reload or fresh
session. Optional Spotify theming can restart an already-running Spotify.

## Go further

- [Customize your setup](Documentation/user-guide.md#make-it-yours) — profiles, dotfiles and packages
- [Everyday use](Documentation/user-guide.md#everyday-use) — menu, screenshots, themes and screensaver
- [Update, troubleshoot or remove](Documentation/user-guide.md#updates-diagnostics-and-removal)
- [Build from source](Documentation/development.md) · [Theme format](Documentation/theme-json.md)

## License

[MIT](LICENSE). Wallpaper credits and licensing live in their theme packages.
