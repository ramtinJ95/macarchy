import Foundation
import TestSupport
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

  /// Every runner outcome renders its text and JSON goldens and reports the right exit status.
  @Test(arguments: GoldenOutcome.allCases)
  func outcomeMatchesItsGoldens(_ outcome: GoldenOutcome) async throws {
    try await expectGoldens(
      runner: runner { try outcome.activate() },
      basename: outcome.rawValue,
      succeeded: outcome == .success
    )
  }

  @Test
  func starshipBehaviorSourceFollowsEnvironmentAuthorityAcrossTeardown() throws {
    let stateRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-runtime-paths-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let externalPaths = testConsumerPaths()
    let managedBehavior = stateRoot.appending(
      path: "environment/current/starship/behavior.toml"
    )

    #expect(
      try ThemeRuntimeSelection.consumerPaths(
        stateRoot: stateRoot,
        consumerPaths: externalPaths
      ).starshipBehaviorURL == externalPaths.starshipBehaviorURL
    )

    try EnvironmentStateStore(stateRoot: stateRoot).writeOwnership(
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        enabledThemeAdapterIDs: []
      )
    )
    #expect(
      try ThemeRuntimeSelection.consumerPaths(
        stateRoot: stateRoot,
        consumerPaths: externalPaths
      ).starshipBehaviorURL == managedBehavior
    )

    try EnvironmentStateStore(stateRoot: stateRoot).writeOwnership(nil)
    #expect(!FileManager.default.fileExists(atPath: managedBehavior.path))
    #expect(
      try ThemeRuntimeSelection.consumerPaths(
        stateRoot: stateRoot,
        consumerPaths: externalPaths
      ).starshipBehaviorURL == externalPaths.starshipBehaviorURL
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
        "#1e1e2e,#cba6f7,#a6e3a1,#f38ba8"
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
    let object = try jsonObject(json.output)
    #expect(
      object["slack_theme"] as? String
        == "#1e1e2e,#cba6f7,#a6e3a1,#f38ba8"
    )
  }

  private func expectGoldens(
    runner: ThemeActivationService,
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
      let golden = try fixtureContents("CLI/theme-set-\(basename).\(suffix)")
      #expect(execution.output + "\n" == golden)
    }
  }

  private var repository: ThemeRepository {
    ThemeRepository(
      builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    )
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

  private func integratedRunner(wallpaperSignal: YabaiWallpaperSignal) -> ThemeActivationService {
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
    let runner = ProcessRunner { request in
      let output: String
      if request.executableURL == CodexAdapter.liveExecutableURL,
        request.arguments == ["--version"]
      {
        output = "codex-cli \(CodexAdapter.minimumVersion)"
      } else if request.executableURL == PiAdapter.liveExecutableURL,
        request.arguments == ["--version"]
      {
        output = PiAdapter.minimumVersion
      } else if request.executableURL == HerdrAdapter.liveExecutableURL,
        request.arguments == ["--version"]
      {
        output = "herdr \(HerdrAdapter.minimumVersion)"
      } else {
        output = ""
      }
      return ProcessResult(
        terminationStatus: 0,
        output: output
      )
    }
    return ThemeActivationService(
      review: { package, backgroundID, stateRoot, consumerPaths in
        try ThemeActivationCoordinator(
          root: stateRoot,
          consumerPaths: consumerPaths,
          processRunner: runner,
          wallpaperControl: control,
          wallpaperSignal: wallpaperSignal
        ).review(package: package, requestedBackgroundID: backgroundID)
      },
      activate: { package, backgroundID, stateRoot, consumerPaths, expectedGenerationID in
        try await ThemeActivationCoordinator(
          root: stateRoot,
          consumerPaths: consumerPaths,
          processRunner: runner,
          wallpaperControl: control,
          wallpaperSignal: wallpaperSignal
        ).activate(
          package: package,
          expectedActiveGenerationID: expectedGenerationID,
          requestedBackgroundID: backgroundID
        )
      }
    )
  }

  private func runner(
    activate: @escaping @Sendable () async throws -> ThemeActivationResult
  ) -> ThemeActivationService {
    ThemeActivationService(
      review: { package, _, _, _ in try passingReview(package) },
      activate: { _, _, _, _, _ in try await activate() }
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
    for adapterID in ConsumerConfigurationFixture.adapterIDs.sorted() {
      try ConsumerConfigurationFixture.write(
        adapterID, root: root, stateRoot: stateRoot, neovim: .integrationOnly)
    }
    return ConsumerConfigurationFixture.paths(
      root: root,
      kittyConfigurationURL: kittyConfigurationURL,
      sketchyBarConfigurationURL: sketchyBarConfigurationURL
    )
  }
}

extension ThemeSetCommandTests {
  enum GoldenOutcome: String, CaseIterable, Sendable {
    /// Fails before the commit, so canonical state is unchanged.
    case precommitFailure = "precommit-failure"
    /// Commits and accepts a required restart and an optional adapter failure.
    case success
    /// A required adapter failure fails the command without undoing the commit.
    case requiredFailure = "required-failure"
    /// A post-commit infrastructure failure still reports the committed generation.
    case committedError = "committed-error"
    /// A post-commit activation failure doesn't claim the commit was rolled back.
    case committedActivationError = "committed-activation-error"

    func activate() throws -> ThemeActivationResult {
      switch self {
      case .precommitFailure:
        throw TestFailure.precommit
      case .success:
        return try activation(
          results: [
            AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
            AdapterResult(adapterID: "btop", requirement: .required, status: .restartRequired),
            AdapterResult(
              adapterID: "spicetify", requirement: .optional, status: .failed,
              message: "apply failed"),
          ]
        )
      case .requiredFailure:
        return try activation(
          results: [
            AdapterResult(
              adapterID: "kitty", requirement: .required, status: .failed,
              message: "reload denied")
          ]
        )
      case .committedError:
        throw ThemeCommittedWithReconciliationError(
          manifest: manifest(), cause: "active generation changed before status persistence")
      case .committedActivationError:
        throw ThemeCommittedActivationError(
          manifest: manifest(), cause: "generation cleanup was denied")
      }
    }
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
    themeDigest: "sha256:theme",
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
