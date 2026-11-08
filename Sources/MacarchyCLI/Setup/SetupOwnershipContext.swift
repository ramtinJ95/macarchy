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
      kittyConfiguration = homeDirectory.appending(path: ConsumerHomePath.kittyConfiguration)
      batConfiguration = homeDirectory.appending(path: ConsumerHomePath.batConfiguration)
      batThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.batDirectory)/themes/\(BatAdapter.themeFileName)")
      batThemeDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      shellConfiguration = homeDirectory.appending(path: ConsumerHomePath.shellConfiguration)
      ezaThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.ezaDirectory)/\(EzaAdapter.themeFileName)")
      ezaThemeDestination = layout.currentThemeArtifact(EzaAdapter.outputPath)
      btopConfiguration = homeDirectory.appending(path: ConsumerHomePath.btopConfiguration)
      btopThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.btopDirectory)/themes/\(BtopAdapter.themeFileName)")
      btopThemeDestination = layout.currentThemeArtifact(BtopAdapter.outputPath)
      yaziConfiguration = homeDirectory.appending(path: ConsumerHomePath.yaziTheme)
      yaziFlavorDirectory = homeDirectory.appending(
        path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi")
      yaziFlavorLink = yaziFlavorDirectory.appending(path: "flavor.toml")
      yaziFlavorDestination = layout.currentThemeArtifact(YaziAdapter.flavorOutputPath)
      yaziSyntaxLink = yaziFlavorDirectory.appending(path: "tmtheme.xml")
      yaziSyntaxDestination = layout.currentThemeArtifact(TextMateThemeArtifact.yaziOutputPath)
      atuinConfiguration = homeDirectory.appending(path: ConsumerHomePath.atuinConfiguration)
      atuinThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.atuinDirectory)/themes/\(AtuinAdapter.themeName).toml")
      atuinThemeDestination = layout.currentThemeArtifact(AtuinAdapter.outputPath)
      neovimWatcherConfiguration = homeDirectory.appending(
        path: ".config/nvim/lua/plugins/colorscheme.lua")
      neovimThemeLink = homeDirectory.appending(
        path: ".config/nvim/lua/macarchy/current.lua")
      neovimThemeDestination = layout.currentThemeArtifact(NeovimAdapter.outputPath)
      starshipBehavior = homeDirectory.appending(path: ConsumerHomePath.starshipBehavior)
      starshipConfigurationLink = homeDirectory.appending(
        path: ConsumerHomePath.starshipConfiguration)
      starshipBridgeDestination = stateRoot.appending(path: StarshipAdapter.bridgePath)
      piConfiguration = homeDirectory.appending(path: ConsumerHomePath.piSettings)
      piThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.piDirectory)/themes/\(PiAdapter.themeName).json")
      piThemeDestination = layout.currentThemeArtifact(PiAdapter.outputPath)
      herdrConfiguration = homeDirectory.appending(path: ConsumerHomePath.herdrConfiguration)
      tuicrConfiguration = homeDirectory.appending(path: ConsumerHomePath.tuicrConfiguration)
      tuicrThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.tuicrDirectory)/themes/\(TuicrAdapter.themeName).toml")
      tuicrThemeDestination = layout.currentThemeArtifact(TuicrAdapter.outputPath)
      tuicrSyntaxLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.tuicrDirectory)/themes/\(TuicrAdapter.themeName).tmTheme")
      tuicrSyntaxDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      codexConfiguration = homeDirectory.appending(path: ConsumerHomePath.codexConfiguration)
      codexThemeLink = homeDirectory.appending(
        path: "\(ConsumerHomePath.codexDirectory)/themes/\(CodexAdapter.themeName).tmTheme")
      codexThemeDestination = layout.currentThemeArtifact(TextMateThemeArtifact.outputPath)
      let spicetifyDirectory = homeDirectory.appending(
        path: ConsumerHomePath.spicetifyDirectory, directoryHint: .isDirectory)
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
