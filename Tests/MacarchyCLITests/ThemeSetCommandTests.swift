import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeSetCommandTests {
  @Test
  func dryRunIsSideEffectFreeAndMatchesOutputContracts() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-cli-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    let kittyConfigurationURL = root.appending(path: "kitty.conf")
    let sketchyBarConfigurationURL = try sketchyBarConfiguration(root: root, stateRoot: stateRoot)
    let configuration = "include \(stateRoot.path)/state/adapters/kitty.conf\n"
    try configuration.write(to: kittyConfigurationURL, atomically: true, encoding: .utf8)
    let signal = try wallpaperSignalFixture(filesRoot: root)
    let consumerPaths = try consumerPaths(
      root: root,
      stateRoot: stateRoot,
      kittyConfigurationURL: kittyConfigurationURL,
      sketchyBarConfigurationURL: sketchyBarConfigurationURL
    )

    try await expectGoldens(
      runner: integratedRunner(wallpaperSignal: signal),
      basename: "dry-run",
      dryRun: true,
      succeeded: true,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths
    )
    #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
    #expect(try String(contentsOf: kittyConfigurationURL, encoding: .utf8) == configuration)
  }

  @Test
  func precommitFailureReportsThatCanonicalStateIsUnchanged() async throws {
    let runner = runner {
      throw TestFailure.precommit
    }

    try await expectGoldens(
      runner: runner,
      basename: "precommit-failure",
      succeeded: false
    )
  }

  @Test
  func successfulCommitAcceptsRestartRequiredAndOptionalFailure() async throws {
    let runner = runner {
      try activation(
        results: [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
          AdapterResult(
            adapterID: "btop",
            requirement: .required,
            status: .restartRequired
          ),
          AdapterResult(
            adapterID: "spicetify",
            requirement: .optional,
            status: .failed,
            message: "apply failed"
          ),
        ]
      )
    }

    try await expectGoldens(
      runner: runner,
      basename: "success",
      succeeded: true
    )
  }

  @Test
  func successfulCommitPrintsAndEncodesTheSlackImportPayload() async throws {
    let runner = runner {
      try activation(results: [])
    }
    let stateRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-slack-output-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let text = try await runner.execute(
      repository: repository,
      themeID: "catppuccin-mocha",
      stateRoot: stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: false
    )
    #expect(text.output.contains("Slack theme requires manual import"))
    #expect(
      text.output.contains(
        "#1e1e2e,#313244,#cba6f7,#1e1e2e,#45475a,#cdd6f4,#a6e3a1,#f38ba8,#313244,#cdd6f4"
      )
    )

    let json = try await runner.execute(
      repository: repository,
      themeID: "catppuccin-mocha",
      stateRoot: stateRoot,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
    )
    #expect(
      object["slack_theme"] as? String
        == "#1e1e2e,#313244,#cba6f7,#1e1e2e,#45475a,#cdd6f4,#a6e3a1,#f38ba8,#313244,#cdd6f4"
    )
  }

  @Test
  func requiredFailureReturnsFailureWithoutUndoingTheCommit() async throws {
    let runner = runner {
      try activation(
        results: [
          AdapterResult(
            adapterID: "kitty",
            requirement: .required,
            status: .failed,
            message: "reload denied"
          )
        ]
      )
    }

    try await expectGoldens(
      runner: runner,
      basename: "required-failure",
      succeeded: false
    )
  }

  @Test
  func postcommitInfrastructureFailureStillReportsTheCommittedGeneration() async throws {
    let manifest = manifest()
    let runner = runner {
      throw ThemeCommittedWithReconciliationError(
        manifest: manifest,
        cause: "active generation changed before status persistence"
      )
    }

    try await expectGoldens(
      runner: runner,
      basename: "committed-error",
      succeeded: false
    )
  }

  @Test
  func postcommitActivationFailureDoesNotClaimTheCommitWasRolledBack() async throws {
    let manifest = manifest()
    let runner = runner {
      throw ThemeCommittedActivationError(
        manifest: manifest,
        cause: "generation cleanup was denied"
      )
    }

    try await expectGoldens(
      runner: runner,
      basename: "committed-activation-error",
      succeeded: false
    )
  }

  private func expectGoldens(
    runner: ThemeSetCommandRunner,
    basename: String,
    dryRun: Bool = false,
    succeeded: Bool,
    stateRoot: URL = URL(filePath: "/test/state", directoryHint: .isDirectory),
    consumerPaths: ThemeConsumerPaths = testConsumerPaths()
  ) async throws {
    let defaultStateRoot = URL(filePath: "/test/state", directoryHint: .isDirectory)
    let effectiveStateRoot: URL
    if stateRoot == defaultStateRoot {
      effectiveStateRoot = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-theme-set-command-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    } else {
      effectiveStateRoot = stateRoot
    }
    defer {
      if effectiveStateRoot != stateRoot {
        try? FileManager.default.removeItem(at: effectiveStateRoot)
      }
    }
    for json in [false, true] {
      let execution = try await runner.execute(
        repository: repository,
        themeID: "catppuccin-mocha",
        stateRoot: effectiveStateRoot,
        consumerPaths: consumerPaths,
        dryRun: dryRun,
        json: json
      )
      #expect(execution.succeeded == succeeded)
      let suffix = json ? "json" : "txt"
      let golden = try String(
        contentsOf: fixturesRoot.appending(path: "theme-set-\(basename).\(suffix)"),
        encoding: .utf8
      )
      #expect(execution.output + "\n" == golden)
    }
  }

  private var repository: ThemeRepository {
    ThemeRepository(
      builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    )
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var fixturesRoot: URL {
    repositoryRoot.appending(path: "Tests/Fixtures/CLI", directoryHint: .isDirectory)
  }

  private func wallpaperSignalFixture(filesRoot: URL) throws -> YabaiWallpaperSignal {
    let executable = filesRoot.appending(path: "macarchy")
    try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let configuration = filesRoot.appending(path: "yabairc")
    let signal = YabaiWallpaperSignal(
      configurationURL: configuration,
      macarchyExecutableURL: executable,
      yabaiExecutableURL: executable
    )
    try "\(signal.directive)\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    return signal
  }

  private func integratedRunner(wallpaperSignal: YabaiWallpaperSignal) -> ThemeSetCommandRunner {
    let control = WallpaperControl(
      inspect: {
        [
          WallpaperDisplay(
            id: 1,
            name: "Test Display",
            wallpaperURL: URL(filePath: "/tmp/test-wallpaper.png")
          )
        ]
      },
      set: { _, _ in }
    )
    let runner = ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    return ThemeSetCommandRunner(
      preflight: { package, stateRoot, consumerPaths in
        try ThemeActivationCoordinator(
          root: stateRoot,
          consumerPaths: consumerPaths,
          processRunner: runner,
          wallpaperControl: control,
          wallpaperSignal: wallpaperSignal
        ).preflight(package: package)
      },
      activate: { package, stateRoot, consumerPaths, expectedGenerationID in
        try await ThemeActivationCoordinator(
          root: stateRoot,
          consumerPaths: consumerPaths,
          processRunner: runner,
          wallpaperControl: control,
          wallpaperSignal: wallpaperSignal
        ).activate(
          package: package,
          expectedActiveGenerationID: expectedGenerationID
        )
      }
    )
  }

  private func runner(
    activate: @escaping @Sendable () async throws -> ThemeActivationResult
  ) -> ThemeSetCommandRunner {
    ThemeSetCommandRunner(
      preflight: { _, _, _ in },
      activate: { _, _, _, _ in try await activate() }
    )
  }

  private func sketchyBarConfiguration(root: URL, stateRoot: URL) throws -> URL {
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
    try "\(SketchyBarAdapter.paletteImport(root: stateRoot))\nreturn colors\n".write(
      to: colors,
      atomically: true,
      encoding: .utf8
    )
    return configuration
  }

  private func consumerPaths(
    root: URL,
    stateRoot: URL,
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
    let starshipDirectory = root.appending(path: "starship", directoryHint: .isDirectory)
    let piDirectory = root.appending(path: "pi", directoryHint: .isDirectory)
    let herdrConfiguration = root.appending(path: "herdr/config.toml")
    let tuicrDirectory = root.appending(path: "tuicr", directoryHint: .isDirectory)
    let codexDirectory = root.appending(path: "codex", directoryHint: .isDirectory)
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
    try FileManager.default.createDirectory(
      at: starshipDirectory, withIntermediateDirectories: true)
    for directory in [
      piDirectory.appending(path: "themes", directoryHint: .isDirectory),
      herdrConfiguration.deletingLastPathComponent(),
      tuicrDirectory.appending(path: "themes", directoryHint: .isDirectory),
      codexDirectory.appending(path: "themes", directoryHint: .isDirectory),
      spicetifyTheme,
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    try FileManager.default.createSymbolicLink(
      at: ezaDirectory.appending(path: "theme.yml"),
      withDestinationURL: stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: batThemes.appending(path: "\(BatAdapter.themeName).tmTheme"),
      withDestinationURL: stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: btopThemes.appending(path: "\(BtopAdapter.themeName).theme"),
      withDestinationURL: stateRoot.appending(path: "current/\(BtopAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "flavor.toml"),
      withDestinationURL: stateRoot.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "tmtheme.xml"),
      withDestinationURL: stateRoot.appending(path: "current/\(YaziAdapter.syntaxOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: atuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
      withDestinationURL: stateRoot.appending(path: "current/\(AtuinAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: neovimMacarchy.appending(path: "current.lua"),
      withDestinationURL: stateRoot.appending(path: "current/\(NeovimAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "starship.toml"),
      withDestinationURL: stateRoot.appending(path: StarshipAdapter.bridgePath)
    )
    try FileManager.default.createSymbolicLink(
      at: piDirectory.appending(path: "themes/\(PiAdapter.themeName).json"),
      withDestinationURL: stateRoot.appending(path: "current/\(PiAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrDirectory.appending(path: "themes/\(TuicrAdapter.themeName).toml"),
      withDestinationURL: stateRoot.appending(path: "current/\(TuicrAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: tuicrDirectory.appending(path: "themes/\(TuicrAdapter.themeName).tmTheme"),
      withDestinationURL: stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: codexDirectory.appending(path: "themes/\(CodexAdapter.themeName).tmTheme"),
      withDestinationURL: stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: spicetifyTheme.appending(path: "color.ini"),
      withDestinationURL: stateRoot.appending(path: "current/\(SpicetifyAdapter.outputPath)")
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
    try "\(NeovimAdapter.integrationDirective)\n".write(
      to: neovimPlugins.appending(path: "colorscheme.lua"), atomically: true, encoding: .utf8)
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
}

private enum TestFailure: Error, CustomStringConvertible {
  case precommit

  var description: String {
    switch self {
    case .precommit:
      "Kitty configuration is missing the stable include"
    }
  }
}

private func manifest() -> GenerationManifest {
  GenerationManifest(
    generationID: "g-test-generation",
    themeID: "catppuccin-mocha",
    themeSchemaVersion: 1,
    inputDigest: "sha256:test",
    rendererVersions: ["kitty": 1, "normalized_theme": 1],
    artifacts: [
      "generated/kitty.conf": "sha256:kitty",
      "theme.json": "sha256:theme",
    ]
  )
}

private func activation(results: [AdapterResult]) throws -> ThemeActivationResult {
  let manifest = manifest()
  return ThemeActivationResult(
    manifest: manifest,
    reconciliation: try ReconciliationRecord(manifest: manifest, results: results)
  )
}
