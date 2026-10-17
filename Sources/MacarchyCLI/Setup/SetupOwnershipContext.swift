import Foundation
import ThemeCore

extension SetupOwnershipManager {
  struct Context {
    let homeDirectory: URL
    let stateRoot: URL
    let kittyConfiguration: URL
    let batConfiguration: URL
    let batThemeLink: URL
    let batThemeDestination: URL
    let shellConfiguration: URL
    let ezaThemeLink: URL
    let ezaThemeDestination: URL
    let btopConfiguration: URL
    let btopThemeLink: URL
    let btopThemeDestination: URL
    let yaziConfiguration: URL
    let yaziFlavorDirectory: URL
    let yaziFlavorLink: URL
    let yaziFlavorDestination: URL
    let yaziSyntaxLink: URL
    let yaziSyntaxDestination: URL
    let atuinConfiguration: URL
    let atuinThemeLink: URL
    let atuinThemeDestination: URL
    let neovimWatcherConfiguration: URL
    let neovimThemeLink: URL
    let neovimThemeDestination: URL
    let starshipBehavior: URL
    let starshipConfigurationLink: URL
    let starshipBridgeDestination: URL
    let piConfiguration: URL
    let piThemeLink: URL
    let piThemeDestination: URL
    let herdrConfiguration: URL
    let tuicrConfiguration: URL
    let tuicrThemeLink: URL
    let tuicrThemeDestination: URL
    let tuicrSyntaxLink: URL
    let tuicrSyntaxDestination: URL
    let codexConfiguration: URL
    let codexThemeLink: URL
    let codexThemeDestination: URL
    let spicetifyConfiguration: URL
    let spicetifyColorLink: URL
    let spicetifyColorDestination: URL
    let manifestURL: URL

    init(homeDirectory: URL) {
      let homeDirectory = homeDirectory.standardizedFileURL
      let stateRoot = homeDirectory.appending(
        path: ".config/macarchy", directoryHint: .isDirectory)
      self.homeDirectory = homeDirectory
      self.stateRoot = stateRoot
      kittyConfiguration = homeDirectory.appending(path: ".config/kitty/kitty.conf")
      batConfiguration = homeDirectory.appending(path: ".config/bat/config")
      batThemeLink = homeDirectory.appending(
        path: ".config/bat/themes/\(BatAdapter.themeFileName)")
      batThemeDestination = stateRoot.appending(
        path: "current/\(TextMateThemeArtifact.outputPath)"
      )
      shellConfiguration = homeDirectory.appending(path: ".zshrc")
      ezaThemeLink = homeDirectory.appending(
        path: ".config/eza/\(EzaAdapter.themeFileName)")
      ezaThemeDestination = stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
      btopConfiguration = homeDirectory.appending(path: ".config/btop/btop.conf")
      btopThemeLink = homeDirectory.appending(
        path: ".config/btop/themes/\(BtopAdapter.themeFileName)")
      btopThemeDestination = stateRoot.appending(path: "current/\(BtopAdapter.outputPath)")
      yaziConfiguration = homeDirectory.appending(path: ".config/yazi/theme.toml")
      yaziFlavorDirectory = homeDirectory.appending(
        path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi")
      yaziFlavorLink = yaziFlavorDirectory.appending(path: "flavor.toml")
      yaziFlavorDestination = stateRoot.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
      yaziSyntaxLink = yaziFlavorDirectory.appending(path: "tmtheme.xml")
      yaziSyntaxDestination = stateRoot.appending(
        path: "current/\(TextMateThemeArtifact.yaziOutputPath)"
      )
      atuinConfiguration = homeDirectory.appending(path: ".config/atuin/config.toml")
      atuinThemeLink = homeDirectory.appending(
        path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml")
      atuinThemeDestination = stateRoot.appending(path: "current/\(AtuinAdapter.outputPath)")
      neovimWatcherConfiguration = homeDirectory.appending(
        path: ".config/nvim/lua/plugins/colorscheme.lua")
      neovimThemeLink = homeDirectory.appending(
        path: ".config/nvim/lua/macarchy/current.lua")
      neovimThemeDestination = stateRoot.appending(
        path: "current/\(NeovimAdapter.outputPath)")
      starshipBehavior = homeDirectory.appending(path: ".config/starship/behavior.toml")
      starshipConfigurationLink = homeDirectory.appending(path: ".config/starship.toml")
      starshipBridgeDestination = stateRoot.appending(path: StarshipAdapter.bridgePath)
      piConfiguration = homeDirectory.appending(path: ".pi/agent/settings.json")
      piThemeLink = homeDirectory.appending(
        path: ".pi/agent/themes/\(PiAdapter.themeName).json")
      piThemeDestination = stateRoot.appending(path: "current/\(PiAdapter.outputPath)")
      herdrConfiguration = homeDirectory.appending(path: ".config/herdr/config.toml")
      tuicrConfiguration = homeDirectory.appending(path: ".config/tuicr/config.toml")
      tuicrThemeLink = homeDirectory.appending(
        path: ".config/tuicr/themes/\(TuicrAdapter.themeName).toml")
      tuicrThemeDestination = stateRoot.appending(path: "current/\(TuicrAdapter.outputPath)")
      tuicrSyntaxLink = homeDirectory.appending(
        path: ".config/tuicr/themes/\(TuicrAdapter.themeName).tmTheme")
      tuicrSyntaxDestination = stateRoot.appending(
        path: "current/\(TextMateThemeArtifact.outputPath)"
      )
      codexConfiguration = homeDirectory.appending(path: ".codex/config.toml")
      codexThemeLink = homeDirectory.appending(
        path: ".codex/themes/\(CodexAdapter.themeName).tmTheme")
      codexThemeDestination = stateRoot.appending(
        path: "current/\(TextMateThemeArtifact.outputPath)"
      )
      let spicetifyDirectory = homeDirectory.appending(
        path: ".config/spicetify", directoryHint: .isDirectory)
      spicetifyConfiguration = spicetifyDirectory.appending(path: "config-xpui.ini")
      spicetifyColorLink = spicetifyDirectory.appending(
        path: "Themes/\(SpicetifyAdapter.themeName)/color.ini")
      spicetifyColorDestination = stateRoot.appending(
        path: "current/\(SpicetifyAdapter.outputPath)")
      manifestURL = stateRoot.appending(path: "state/setup/ownership.json")
    }

    var backupURL: URL { setupBackup("kitty.conf") }
    var batSelectorBackup: URL { setupBackup("bat-config") }
    var ezaEnvironmentBackup: URL { setupBackup("zshrc") }
    var yaziSelectorBackup: URL { setupBackup("yazi-theme.toml") }
    var atuinSelectorBackup: URL { setupBackup("atuin-config.toml") }
    var tuicrSelectorBackup: URL { setupBackup("tuicr-config.toml") }
    var codexSelectorBackup: URL { setupBackup("codex-config.toml") }
    var spicetifySelectorsBackup: URL { setupBackup("spicetify-config-xpui.ini") }

    private func setupBackup(_ name: String) -> URL {
      stateRoot.appending(path: "state/setup/backups/\(name)")
    }

    let replacementName = ".macarchy-kitty-transaction"
    let batSelectorReplacementName = ".macarchy-bat-config-transaction"
    let ezaEnvironmentReplacementName = ".macarchy-zshrc-transaction"
    let yaziSelectorReplacementName = ".macarchy-yazi-theme-transaction"
    let atuinSelectorReplacementName = ".macarchy-atuin-config-transaction"
    let piSelectorReplacementName = ".macarchy-pi-settings-transaction"
    let tuicrSelectorReplacementName = ".macarchy-tuicr-config-transaction"
    let codexSelectorReplacementName = ".macarchy-codex-config-transaction"
    let spicetifySelectorsReplacementName =
      ".macarchy-spicetify-config-transaction"
  }
}
