import Foundation
import ThemeCore

/// Integrated consumer configurations under a test root, each linking its managed files into
/// `<stateRoot>/current`. Kitty and SketchyBar are not covered: their fixtures differ by suite.
package enum ConsumerConfigurationFixture {
  /// How much of the Neovim integration the fixture writes.
  package enum NeovimIntegration: Sendable {
    /// Only the plugin integration directive and the background-aware watcher.
    case integrationOnly
    /// Also the aether repository, branch and commit directives and the imported colorscheme.
    case aether
  }

  /// The adapters `write` covers.
  package static let adapterIDs: Set<String> = [
    "eza", "bat", "btop", "yazi", "atuin", "neovim", "starship", "pi", "herdr", "tuicr",
    "codex", "spicetify",
  ]

  /// Writes `adapterID`'s integrated configuration under `root`; false when `adapterID` is not
  /// in `adapterIDs`.
  @discardableResult
  package static func write(
    _ adapterID: String,
    root: URL,
    stateRoot: URL,
    neovim: NeovimIntegration
  ) throws -> Bool {
    let current = { (path: String) in stateRoot.appending(path: "current/\(path)") }
    switch adapterID {
    case "eza":
      let ezaDirectory = root.appending(path: "eza", directoryHint: .isDirectory)
      try createDirectory(ezaDirectory)
      try link(ezaDirectory.appending(path: "theme.yml"), to: current(EzaAdapter.outputPath))
      try writeText(
        "export EZA_CONFIG_DIR=\"\(ezaDirectory.path)\"\n", to: root.appending(path: ".zshrc"))
    case "bat":
      let batDirectory = root.appending(path: "bat", directoryHint: .isDirectory)
      let batThemes = batDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(batThemes)
      try link(
        batThemes.appending(path: "\(BatAdapter.themeName).tmTheme"),
        to: current(TextMateThemeArtifact.outputPath))
      try writeText(
        "--theme=\"\(BatAdapter.themeName)\"\n", to: batDirectory.appending(path: "config"))
    case "btop":
      let btopDirectory = root.appending(path: "btop", directoryHint: .isDirectory)
      let btopThemes = btopDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(btopThemes)
      try link(
        btopThemes.appending(path: "\(BtopAdapter.themeName).theme"),
        to: current(BtopAdapter.outputPath))
      try writeText(
        "color_theme = \"\(BtopAdapter.themeName)\"\n",
        to: btopDirectory.appending(path: "btop.conf"))
    case "yazi":
      let yaziDirectory = root.appending(path: "yazi", directoryHint: .isDirectory)
      let yaziFlavor = yaziDirectory.appending(
        path: "flavors/\(YaziAdapter.flavorName).yazi", directoryHint: .isDirectory)
      try createDirectory(yaziFlavor)
      try link(
        yaziFlavor.appending(path: "flavor.toml"), to: current(YaziAdapter.flavorOutputPath))
      try link(
        yaziFlavor.appending(path: "tmtheme.xml"),
        to: current(TextMateThemeArtifact.yaziOutputPath))
      try writeText(
        "[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n",
        to: yaziDirectory.appending(path: "theme.toml"))
    case "atuin":
      let atuinDirectory = root.appending(path: "atuin", directoryHint: .isDirectory)
      let atuinThemes = atuinDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(atuinThemes)
      try link(
        atuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
        to: current(AtuinAdapter.outputPath))
      try writeText(
        "[theme]\nname = \"\(AtuinAdapter.themeName)\"\n",
        to: atuinDirectory.appending(path: "config.toml"))
    case "neovim":
      try writeNeovim(root: root, current: current, integration: neovim)
    case "starship":
      let starshipDirectory = root.appending(path: "starship", directoryHint: .isDirectory)
      try createDirectory(starshipDirectory)
      try link(
        root.appending(path: "starship.toml"),
        to: stateRoot.appending(path: StarshipAdapter.bridgePath))
      try writeText(
        "format = \"$character\"\n", to: starshipDirectory.appending(path: "behavior.toml"))
    case "pi":
      let piDirectory = root.appending(path: "pi", directoryHint: .isDirectory)
      let piThemes = piDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(piThemes)
      try link(
        piThemes.appending(path: "\(PiAdapter.themeName).json"),
        to: current(PiAdapter.outputPath))
      try writeText(
        "{\"theme\":\"\(PiAdapter.themeName)\"}\n",
        to: piDirectory.appending(path: "settings.json"))
    case "herdr":
      let herdrConfiguration = root.appending(path: "herdr/config.toml")
      try createDirectory(herdrConfiguration.deletingLastPathComponent())
      try writeText("[theme]\nname = \"catppuccin\"\n", to: herdrConfiguration)
    case "tuicr":
      let tuicrDirectory = root.appending(path: "tuicr", directoryHint: .isDirectory)
      let tuicrThemes = tuicrDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(tuicrThemes)
      try link(
        tuicrThemes.appending(path: "\(TuicrAdapter.themeName).toml"),
        to: current(TuicrAdapter.outputPath))
      try link(
        tuicrThemes.appending(path: "\(TuicrAdapter.themeName).tmTheme"),
        to: current(TextMateThemeArtifact.outputPath))
      try writeText(
        "theme = \"\(TuicrAdapter.themeName)\"\n",
        to: tuicrDirectory.appending(path: "config.toml"))
    case "codex":
      let codexDirectory = root.appending(path: "codex", directoryHint: .isDirectory)
      let codexThemes = codexDirectory.appending(path: "themes", directoryHint: .isDirectory)
      try createDirectory(codexThemes)
      try link(
        codexThemes.appending(path: "\(CodexAdapter.themeName).tmTheme"),
        to: current(TextMateThemeArtifact.outputPath))
      try writeText(
        "[tui]\ntheme = \"\(CodexAdapter.themeName)\"\n",
        to: codexDirectory.appending(path: "config.toml"))
    case "spicetify":
      let spicetifyDirectory = root.appending(path: "spicetify", directoryHint: .isDirectory)
      let spicetifyTheme = spicetifyDirectory.appending(
        path: "Themes/\(SpicetifyAdapter.themeName)", directoryHint: .isDirectory)
      try createDirectory(spicetifyTheme)
      try link(
        spicetifyTheme.appending(path: "color.ini"), to: current(SpicetifyAdapter.outputPath))
      try writeText(
        "[Setting]\ncurrent_theme = \(SpicetifyAdapter.themeName)\ncolor_scheme = \(SpicetifyAdapter.colorSchemeName)\n",
        to: spicetifyDirectory.appending(path: "config-xpui.ini"))
    default:
      return false
    }
    return true
  }

  /// Consumer paths for the layout `write` creates under `root`.
  package static func paths(
    root: URL,
    kittyConfigurationURL: URL,
    sketchyBarConfigurationURL: URL
  ) -> ThemeConsumerPaths {
    ThemeConsumerPaths(
      kittyConfigurationURL: kittyConfigurationURL,
      sketchyBarConfigurationURL: sketchyBarConfigurationURL,
      shellConfigurationURL: root.appending(path: ".zshrc"),
      ezaConfigurationDirectoryURL: root.appending(path: "eza", directoryHint: .isDirectory),
      batConfigurationDirectoryURL: root.appending(path: "bat", directoryHint: .isDirectory),
      batCacheDirectoryURL: root.appending(path: "bat-cache", directoryHint: .isDirectory),
      btopConfigurationDirectoryURL: root.appending(path: "btop", directoryHint: .isDirectory),
      yaziConfigurationDirectoryURL: root.appending(path: "yazi", directoryHint: .isDirectory),
      atuinConfigurationDirectoryURL: root.appending(path: "atuin", directoryHint: .isDirectory),
      neovimConfigurationDirectoryURL: root.appending(path: "nvim", directoryHint: .isDirectory),
      starshipConfigurationURL: root.appending(path: "starship.toml"),
      starshipBehaviorURL: root.appending(path: "starship/behavior.toml"),
      piConfigurationDirectoryURL: root.appending(path: "pi", directoryHint: .isDirectory),
      herdrConfigurationURL: root.appending(path: "herdr/config.toml"),
      tuicrConfigurationDirectoryURL: root.appending(path: "tuicr", directoryHint: .isDirectory),
      codexConfigurationDirectoryURL: root.appending(path: "codex", directoryHint: .isDirectory),
      spicetifyConfigurationDirectoryURL: root.appending(
        path: "spicetify", directoryHint: .isDirectory)
    )
  }

  private static func writeNeovim(
    root: URL,
    current: (String) -> URL,
    integration: NeovimIntegration
  ) throws {
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let neovimPlugins = neovimDirectory.appending(path: "lua/plugins", directoryHint: .isDirectory)
    let neovimMacarchy = neovimDirectory.appending(
      path: "lua/macarchy", directoryHint: .isDirectory)
    let neovimConfig = neovimDirectory.appending(path: "lua/config", directoryHint: .isDirectory)
    try createDirectory(neovimPlugins)
    try createDirectory(neovimMacarchy)
    try createDirectory(neovimConfig)
    try link(neovimMacarchy.appending(path: "current.lua"), to: current(NeovimAdapter.outputPath))
    switch integration {
    case .integrationOnly:
      try writeText(
        "\(NeovimAdapter.integrationDirective)\n",
        to: neovimPlugins.appending(path: "colorscheme.lua"))
    case .aether:
      let neovimColors = neovimDirectory.appending(path: "colors", directoryHint: .isDirectory)
      try createDirectory(neovimColors)
      try writeText(
        """
        \(NeovimAdapter.integrationDirective)
        \(NeovimAdapter.aetherRepositoryDirective)
        \(NeovimAdapter.aetherBranchDirective)
        \(NeovimAdapter.aetherCommitDirective)

        """,
        to: neovimPlugins.appending(path: "colorscheme.lua"))
      try writeText(
        "\(NeovimAdapter.importedColorschemeDirective)\n",
        to: neovimColors.appending(path: "\(NeovimAdapter.importedColorscheme).lua"))
    }
    try writeText(
      "\(NeovimAdapter.backgroundAwareWatcherDirective)\n",
      to: neovimConfig.appending(path: "macarchy-theme.lua"))
  }

  private static func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private static func link(_ url: URL, to destination: URL) throws {
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
  }

  private static func writeText(_ contents: String, to url: URL) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
}
