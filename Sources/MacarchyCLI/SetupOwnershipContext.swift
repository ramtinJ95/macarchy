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
    let starshipStowConfigurationLink: URL
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
    let includeDirective: String
    let manifestURL: URL
    let backupRelativePath = "state/setup/backups/kitty.conf"
    let batSelectorBackupRelativePath = "state/setup/backups/bat-config"
    let ezaEnvironmentBackupRelativePath = "state/setup/backups/zshrc"
    let yaziSelectorBackupRelativePath = "state/setup/backups/yazi-theme.toml"
    let atuinSelectorBackupRelativePath = "state/setup/backups/atuin-config.toml"
    let tuicrSelectorBackupRelativePath = "state/setup/backups/tuicr-config.toml"
    let codexSelectorBackupRelativePath = "state/setup/backups/codex-config.toml"
    let spicetifySelectorsBackupRelativePath =
      "state/setup/backups/spicetify-config-xpui.ini"

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
      batThemeDestination = stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
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
      yaziSyntaxDestination = stateRoot.appending(path: "current/\(YaziAdapter.syntaxOutputPath)")
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
      starshipStowConfigurationLink = homeDirectory.appending(
        path: SetupOwnershipManager.starshipStowConfigurationRelativePath)
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
      tuicrSyntaxDestination = stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
      codexConfiguration = homeDirectory.appending(path: ".codex/config.toml")
      codexThemeLink = homeDirectory.appending(
        path: ".codex/themes/\(CodexAdapter.themeName).tmTheme")
      codexThemeDestination = stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
      let spicetifyDirectory = homeDirectory.appending(
        path: ".config/spicetify", directoryHint: .isDirectory)
      spicetifyConfiguration = spicetifyDirectory.appending(path: "config-xpui.ini")
      spicetifyColorLink = spicetifyDirectory.appending(
        path: "Themes/\(SpicetifyAdapter.themeName)/color.ini")
      spicetifyColorDestination = stateRoot.appending(
        path: "current/\(SpicetifyAdapter.outputPath)")
      includeDirective = ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
      manifestURL = stateRoot.appending(path: "state/setup/ownership.json")
    }

    var backupURL: URL {
      stateRoot.appending(path: backupRelativePath)
    }

    var batSelectorBackup: URL {
      stateRoot.appending(path: batSelectorBackupRelativePath)
    }

    var ezaEnvironmentBackup: URL {
      stateRoot.appending(path: ezaEnvironmentBackupRelativePath)
    }

    var yaziSelectorBackup: URL {
      stateRoot.appending(path: yaziSelectorBackupRelativePath)
    }

    var atuinSelectorBackup: URL {
      stateRoot.appending(path: atuinSelectorBackupRelativePath)
    }

    var tuicrSelectorBackup: URL {
      stateRoot.appending(path: tuicrSelectorBackupRelativePath)
    }

    var codexSelectorBackup: URL {
      stateRoot.appending(path: codexSelectorBackupRelativePath)
    }

    var spicetifySelectorsBackup: URL {
      stateRoot.appending(path: spicetifySelectorsBackupRelativePath)
    }

    var bridgeURL: URL {
      stateRoot.appending(path: "state/adapters/kitty.conf")
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

    var replacementURL: URL {
      kittyConfiguration.deletingLastPathComponent().appending(path: replacementName)
    }
  }
}
