/// Default consumer configuration locations, relative to the user's home directory.
///
/// These are path strings, not URLs: each caller appends them to its home directory with its
/// own `directoryHint`, because URLs built with different hints compare unequal.
package enum ConsumerHomePath {
  package static let atuinDirectory = ".config/atuin"
  package static let atuinConfiguration = ".config/atuin/config.toml"
  package static let batDirectory = ".config/bat"
  package static let batConfiguration = ".config/bat/config"
  package static let bordersConfiguration = ".config/borders/bordersrc"
  package static let btopDirectory = ".config/btop"
  package static let btopConfiguration = ".config/btop/btop.conf"
  package static let codexDirectory = ".codex"
  package static let codexConfiguration = ".codex/config.toml"
  package static let ezaDirectory = ".config/eza"
  package static let herdrDirectory = ".config/herdr"
  package static let herdrConfiguration = ".config/herdr/config.toml"
  package static let kittyDirectory = ".config/kitty"
  package static let kittyConfiguration = ".config/kitty/kitty.conf"
  package static let neovimDirectory = ".config/nvim"
  package static let piDirectory = ".pi/agent"
  package static let piSettings = ".pi/agent/settings.json"
  package static let shellConfiguration = ".zshrc"
  package static let sketchyBarDirectory = ".config/sketchybar"
  package static let sketchyBarConfiguration = ".config/sketchybar/sketchybarrc"
  package static let skhdConfiguration =
    ".config/\(SkhdLayout.directoryName)/\(SkhdLayout.configurationName)"
  package static let spicetifyDirectory = ".config/spicetify"
  package static let spicetifyConfiguration = ".config/spicetify/config-xpui.ini"
  package static let starshipConfiguration = ".config/starship.toml"
  package static let starshipBehavior = ".config/starship/behavior.toml"
  package static let tuicrDirectory = ".config/tuicr"
  package static let tuicrConfiguration = ".config/tuicr/config.toml"
  package static let yabaiDirectory = ".config/yabai"
  package static let yabaiConfiguration = ".config/yabai/yabairc"
  package static let yaziDirectory = ".config/yazi"
  package static let yaziTheme = ".config/yazi/theme.toml"
}
