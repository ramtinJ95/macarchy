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

    /// Setup ownership links the user's home into the canonical per-user state root only.
    /// Commands that accept `--state-root` refuse any other root before reaching it.
    init(homeDirectory: URL) {
      let homeDirectory = homeDirectory.standardizedFileURL
      let stateRoot = StateLayout.defaultRoot(in: homeDirectory, directoryHint: .isDirectory)
      self.homeDirectory = homeDirectory
      self.stateRoot = stateRoot
      let layout = StateLayout(root: stateRoot)
      kittyConfiguration = homeDirectory.appending(path: ".config/kitty/kitty.conf")
      batConfiguration = homeDirectory.appending(path: ".config/bat/config")
      batThemeLink = homeDirectory.appending(
        path: ".config/bat/themes/\(BatAdapter.themeFileName)")
      batThemeDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      shellConfiguration = homeDirectory.appending(path: ".zshrc")
      ezaThemeLink = homeDirectory.appending(
        path: ".config/eza/\(EzaAdapter.themeFileName)")
      ezaThemeDestination = layout.currentThemeArtifact(EzaAdapter.outputPath)
      btopConfiguration = homeDirectory.appending(path: ".config/btop/btop.conf")
      btopThemeLink = homeDirectory.appending(
        path: ".config/btop/themes/\(BtopAdapter.themeFileName)")
      btopThemeDestination = layout.currentThemeArtifact(BtopAdapter.outputPath)
      yaziConfiguration = homeDirectory.appending(path: ".config/yazi/theme.toml")
      yaziFlavorDirectory = homeDirectory.appending(
        path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi")
      yaziFlavorLink = yaziFlavorDirectory.appending(path: "flavor.toml")
      yaziFlavorDestination = layout.currentThemeArtifact(YaziAdapter.flavorOutputPath)
      yaziSyntaxLink = yaziFlavorDirectory.appending(path: "tmtheme.xml")
      yaziSyntaxDestination = layout.currentThemeArtifact(TextMateThemeArtifact.yaziOutputPath)
      atuinConfiguration = homeDirectory.appending(path: ".config/atuin/config.toml")
      atuinThemeLink = homeDirectory.appending(
        path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml")
      atuinThemeDestination = layout.currentThemeArtifact(AtuinAdapter.outputPath)
      neovimWatcherConfiguration = homeDirectory.appending(
        path: ".config/nvim/lua/plugins/colorscheme.lua")
      neovimThemeLink = homeDirectory.appending(
        path: ".config/nvim/lua/macarchy/current.lua")
      neovimThemeDestination = layout.currentThemeArtifact(NeovimAdapter.outputPath)
      starshipBehavior = homeDirectory.appending(path: ".config/starship/behavior.toml")
      starshipConfigurationLink = homeDirectory.appending(path: ".config/starship.toml")
      starshipBridgeDestination = stateRoot.appending(path: StarshipAdapter.bridgePath)
      piConfiguration = homeDirectory.appending(path: ".pi/agent/settings.json")
      piThemeLink = homeDirectory.appending(
        path: ".pi/agent/themes/\(PiAdapter.themeName).json")
      piThemeDestination = layout.currentThemeArtifact(PiAdapter.outputPath)
      herdrConfiguration = homeDirectory.appending(path: ".config/herdr/config.toml")
      tuicrConfiguration = homeDirectory.appending(path: ".config/tuicr/config.toml")
      tuicrThemeLink = homeDirectory.appending(
        path: ".config/tuicr/themes/\(TuicrAdapter.themeName).toml")
      tuicrThemeDestination = layout.currentThemeArtifact(TuicrAdapter.outputPath)
      tuicrSyntaxLink = homeDirectory.appending(
        path: ".config/tuicr/themes/\(TuicrAdapter.themeName).tmTheme")
      tuicrSyntaxDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      codexConfiguration = homeDirectory.appending(path: ".codex/config.toml")
      codexThemeLink = homeDirectory.appending(
        path: ".codex/themes/\(CodexAdapter.themeName).tmTheme")
      codexThemeDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      let spicetifyDirectory = homeDirectory.appending(
        path: ".config/spicetify", directoryHint: .isDirectory)
      spicetifyConfiguration = spicetifyDirectory.appending(path: "config-xpui.ini")
      spicetifyColorLink = spicetifyDirectory.appending(
        path: "Themes/\(SpicetifyAdapter.themeName)/color.ini")
      spicetifyColorDestination = layout.currentThemeArtifact(SpicetifyAdapter.outputPath)
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
