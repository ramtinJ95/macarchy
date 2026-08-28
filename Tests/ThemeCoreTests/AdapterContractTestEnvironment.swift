import Foundation
import Synchronization
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct AdapterContractTests {}

extension AdapterContractTests {
  var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func catppuccinPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
  }

  func tokyoNightPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/tokyo-night",
        directoryHint: .isDirectory
      )
    )
  }

  func packageWithoutNamedThemeMappings(_ base: ThemePackage) -> ThemePackage {
    ThemePackage(
      packageURL: base.packageURL,
      schemaVersion: base.schemaVersion,
      id: base.id,
      displayName: base.displayName,
      appearance: base.appearance,
      semantic: base.semantic,
      terminal: base.terminal,
      wallpaper: base.wallpaper,
      wallpaperData: base.wallpaperData,
      mappings: [:]
    )
  }

  func testActivator(root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-adapter-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func makeWritableForRemoval(_ root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  static func appearanceScript(dark: Bool) -> String {
    "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
  }

  static func appearanceRequest(dark: Bool) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/osascript"),
      arguments: ["-e", appearanceScript(dark: dark)],
      timeout: 2
    )
  }

  static func wallpaperControl(
    initialURL: URL = URL(filePath: "/tmp/existing-wallpaper.png")
  ) -> WallpaperControl {
    let displays = Mutex([
      WallpaperDisplay(id: 1, name: "Test Display", wallpaperURL: initialURL)
    ])
    return WallpaperControl(
      inspect: { displays.withLock { $0 } },
      set: { wallpaperURL, displayID in
        try displays.withLock { displays in
          guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            throw WallpaperAdapterError.unavailableDisplay(displayID)
          }
          displays[index] = WallpaperDisplay(
            id: displays[index].id,
            name: displays[index].name,
            wallpaperURL: wallpaperURL
          )
        }
      }
    )
  }

  static func wallpaperSignal(root: URL) throws -> YabaiWallpaperSignal {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "test-yabai")
    try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let signal = YabaiWallpaperSignal(
      configurationURL: root.appending(path: "test-yabairc"),
      macarchyExecutableURL: executable,
      yabaiExecutableURL: executable
    )
    try "\(signal.directive)\n".write(
      to: signal.configurationURL,
      atomically: true,
      encoding: .utf8
    )
    return signal
  }

  static func sketchyBarConfiguration(root: URL) throws -> URL {
    let configurationRoot = root.appending(path: "sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: configurationRoot,
      withIntermediateDirectories: true
    )
    let configuration = configurationRoot.appending(path: "sketchybarrc")
    try "\(SketchyBarAdapter.initImport)\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    try "\(SketchyBarAdapter.readyMarkerDeclaration)\n".write(
      to: configurationRoot.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    let colors = configurationRoot.appending(path: "colors.lua")
    try "\(SketchyBarAdapter.paletteImport(root: root))\nreturn colors\n".write(
      to: colors,
      atomically: true,
      encoding: .utf8
    )
    return configuration
  }

  static func consumerPaths(
    root: URL,
    kittyConfigurationURL: URL,
    sketchyBarConfigurationURL: URL
  ) throws -> ThemeConsumerPaths {
    let ezaDirectory = root.appending(path: "eza", directoryHint: .isDirectory)
    let batDirectory = root.appending(path: "bat", directoryHint: .isDirectory)
    let btopDirectory = root.appending(path: "btop", directoryHint: .isDirectory)
    let yaziDirectory = root.appending(path: "yazi", directoryHint: .isDirectory)
    let atuinDirectory = root.appending(path: "atuin", directoryHint: .isDirectory)
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let neovimPlugins = neovimDirectory.appending(
      path: "lua/plugins", directoryHint: .isDirectory)
    let neovimMacarchy = neovimDirectory.appending(
      path: "lua/macarchy", directoryHint: .isDirectory)
    let neovimColors = neovimDirectory.appending(path: "colors", directoryHint: .isDirectory)
    let starshipDirectory = root.appending(path: "starship", directoryHint: .isDirectory)
    let piDirectory = root.appending(path: "pi", directoryHint: .isDirectory)
    let piThemes = piDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let herdrConfiguration = root.appending(path: "herdr/config.toml")
    let tuicrDirectory = root.appending(path: "tuicr", directoryHint: .isDirectory)
    let tuicrThemes = tuicrDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let codexDirectory = root.appending(path: "codex", directoryHint: .isDirectory)
    let codexThemes = codexDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let spicetifyDirectory = root.appending(path: "spicetify", directoryHint: .isDirectory)
    let spicetifyTheme = spicetifyDirectory.appending(
      path: "Themes/\(SpicetifyAdapter.themeName)", directoryHint: .isDirectory)
    let batThemes = batDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let btopThemes = btopDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let yaziFlavor = yaziDirectory.appending(
      path: "flavors/\(YaziAdapter.flavorName).yazi", directoryHint: .isDirectory)
    let atuinThemes = atuinDirectory.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ezaDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: batThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: btopThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: yaziFlavor, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: atuinThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimPlugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimMacarchy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimColors, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: starshipDirectory, withIntermediateDirectories: true)
    for directory in [
      piThemes, herdrConfiguration.deletingLastPathComponent(), tuicrThemes, codexThemes,
      spicetifyTheme,
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let ezaTheme = ezaDirectory.appending(path: "theme.yml")
    try FileManager.default.createSymbolicLink(
      at: ezaTheme,
      withDestinationURL: root.appending(path: "current/\(EzaAdapter.outputPath)")
    )
    let batTheme = batThemes.appending(path: "\(BatAdapter.themeName).tmTheme")
    try FileManager.default.createSymbolicLink(
      at: batTheme,
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: btopThemes.appending(path: "\(BtopAdapter.themeName).theme"),
      withDestinationURL: root.appending(path: "current/\(BtopAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "flavor.toml"),
      withDestinationURL: root.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "tmtheme.xml"),
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.yaziOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: atuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
      withDestinationURL: root.appending(path: "current/\(AtuinAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: neovimMacarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "current/\(NeovimAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "starship.toml"),
      withDestinationURL: root.appending(path: StarshipAdapter.bridgePath)
    )
    try FileManager.default.createSymbolicLink(
      at: piThemes.appending(path: "\(PiAdapter.themeName).json"),
      withDestinationURL: root.appending(path: "current/\(PiAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrThemes.appending(path: "\(TuicrAdapter.themeName).toml"),
      withDestinationURL: root.appending(path: "current/\(TuicrAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrThemes.appending(path: "\(TuicrAdapter.themeName).tmTheme"),
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: codexThemes.appending(path: "\(CodexAdapter.themeName).tmTheme"),
      withDestinationURL: root.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: spicetifyTheme.appending(path: "color.ini"),
      withDestinationURL: root.appending(path: "current/\(SpicetifyAdapter.outputPath)")
    )

    let shellConfiguration = root.appending(path: ".zshrc")
    try "export EZA_CONFIG_DIR=\"\(ezaDirectory.path)\"\n".write(
      to: shellConfiguration,
      atomically: true,
      encoding: .utf8
    )
    try "--theme=\"\(BatAdapter.themeName)\"\n".write(
      to: batDirectory.appending(path: "config"),
      atomically: true,
      encoding: .utf8
    )
    try "color_theme = \"\(BtopAdapter.themeName)\"\n".write(
      to: btopDirectory.appending(path: "btop.conf"), atomically: true, encoding: .utf8)
    try "[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n".write(
      to: yaziDirectory.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    try "[theme]\nname = \"\(AtuinAdapter.themeName)\"\n".write(
      to: atuinDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try """
    \(NeovimAdapter.integrationDirective)
    \(NeovimAdapter.aetherRepositoryDirective)
    \(NeovimAdapter.aetherBranchDirective)
    \(NeovimAdapter.aetherCommitDirective)

    """.write(
      to: neovimPlugins.appending(path: "colorscheme.lua"), atomically: true, encoding: .utf8)
    try "\(NeovimAdapter.importedColorschemeDirective)\n".write(
      to: neovimColors.appending(path: "\(NeovimAdapter.importedColorscheme).lua"),
      atomically: true,
      encoding: .utf8
    )
    try "format = \"$character\"\n".write(
      to: starshipDirectory.appending(path: "behavior.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "{\"theme\":\"\(PiAdapter.themeName)\"}\n".write(
      to: piDirectory.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    try "[theme]\nname = \"catppuccin\"\n".write(
      to: herdrConfiguration, atomically: true, encoding: .utf8)
    try "theme = \"\(TuicrAdapter.themeName)\"\n".write(
      to: tuicrDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try "[tui]\ntheme = \"\(CodexAdapter.themeName)\"\n".write(
      to: codexDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try
      "[Setting]\ncurrent_theme = \(SpicetifyAdapter.themeName)\ncolor_scheme = \(SpicetifyAdapter.colorSchemeName)\n"
      .write(
        to: spicetifyDirectory.appending(path: "config-xpui.ini"),
        atomically: true,
        encoding: .utf8
      )

    return ThemeConsumerPaths(
      kittyConfigurationURL: kittyConfigurationURL,
      sketchyBarConfigurationURL: sketchyBarConfigurationURL,
      shellConfigurationURL: shellConfiguration,
      ezaConfigurationDirectoryURL: ezaDirectory,
      batConfigurationDirectoryURL: batDirectory,
      batCacheDirectoryURL: root.appending(path: "bat-cache", directoryHint: .isDirectory),
      btopConfigurationDirectoryURL: btopDirectory,
      yaziConfigurationDirectoryURL: yaziDirectory,
      atuinConfigurationDirectoryURL: atuinDirectory,
      neovimConfigurationDirectoryURL: neovimDirectory,
      starshipConfigurationURL: root.appending(path: "starship.toml"),
      starshipBehaviorURL: starshipDirectory.appending(path: "behavior.toml"),
      piConfigurationDirectoryURL: piDirectory,
      herdrConfigurationURL: herdrConfiguration,
      tuicrConfigurationDirectoryURL: tuicrDirectory,
      codexConfigurationDirectoryURL: codexDirectory,
      spicetifyConfigurationDirectoryURL: spicetifyDirectory
    )
  }

  func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReconciliationTestError.timedOut
  }

}

enum ReconciliationTestError: Error {
  case expectedCommittedError
  case expectedCurrentStatus
  case expectedFailure
  case expectedInterruption
  case timedOut
}
