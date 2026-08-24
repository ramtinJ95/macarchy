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
    let configuration = "include \(stateRoot.path)/state/adapters/kitty.conf\n"
    try configuration.write(to: kittyConfigurationURL, atomically: true, encoding: .utf8)
    let signal = try wallpaperSignalFixture(filesRoot: root)

    try await expectGoldens(
      runner: integratedRunner(wallpaperSignal: signal),
      basename: "dry-run",
      dryRun: true,
      succeeded: true,
      stateRoot: stateRoot,
      kittyConfigurationURL: kittyConfigurationURL
    )
    #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
    #expect(try String(contentsOf: kittyConfigurationURL, encoding: .utf8) == configuration)
  }

  @Test
  func precommitFailureReportsThatCanonicalStateIsUnchanged() async throws {
    let runner = runner { _, _, _ in
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
    let runner = runner { _, _, _ in
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
  func requiredFailureReturnsFailureWithoutUndoingTheCommit() async throws {
    let runner = runner { _, _, _ in
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
    let runner = runner { _, _, _ in
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
    let runner = runner { _, _, _ in
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
    kittyConfigurationURL: URL = URL(filePath: "/test/kitty.conf")
  ) async throws {
    for json in [false, true] {
      let execution = try await runner.execute(
        repository: repository,
        themeID: "catppuccin-mocha",
        stateRoot: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL,
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
      preflight: { package, stateRoot, kittyConfigurationURL in
        try ThemeActivationCoordinator(
          root: stateRoot,
          kittyConfigurationURL: kittyConfigurationURL,
          processRunner: runner,
          wallpaperControl: control,
          wallpaperSignal: wallpaperSignal
        ).preflight(package: package)
      },
      activate: { package, stateRoot, kittyConfigurationURL, expectedGenerationID in
        try await ThemeActivationCoordinator(
          root: stateRoot,
          kittyConfigurationURL: kittyConfigurationURL,
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
    activate: @escaping @Sendable (ThemePackage, URL, URL) async throws -> ThemeActivationResult
  ) -> ThemeSetCommandRunner {
    ThemeSetCommandRunner(
      preflight: { _, _, _ in },
      activate: { package, stateRoot, kittyConfigurationURL, _ in
        try await activate(package, stateRoot, kittyConfigurationURL)
      }
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
