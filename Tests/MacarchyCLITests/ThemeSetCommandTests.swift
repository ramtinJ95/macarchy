import ArgumentParser
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
    let configuration = "include \(stateRoot.path)/current/generated/kitty.conf\n"
    try configuration.write(to: kittyConfigurationURL, atomically: true, encoding: .utf8)

    try await expectGoldens(
      runner: .live,
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
  func commandBoundaryLoadsUserThemesAndReturnsFailureForPreflightErrors() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-cli-boundary-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let builtInRoot = root.appending(path: "built-ins", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: builtInRoot, withIntermediateDirectories: true)
    let stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    let userThemes = stateRoot.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"),
      to: userThemes.appending(path: "catppuccin-mocha")
    )

    let kittyConfigurationURL = root.appending(path: "kitty.conf")
    try "include \(stateRoot.path)/current/generated/kitty.conf\n".write(
      to: kittyConfigurationURL,
      atomically: true,
      encoding: .utf8
    )
    var success = try #require(
      Macarchy.parseAsRoot([
        "theme", "set", "catppuccin-mocha",
        "--themes-root", builtInRoot.path,
        "--state-root", stateRoot.path,
        "--kitty-config", kittyConfigurationURL.path,
        "--dry-run",
      ]) as? Theme.Set
    )
    try await success.run()

    let missingStateRoot = root.appending(path: "missing-state", directoryHint: .isDirectory)
    let missingStateKittyConfigurationURL = root.appending(path: "missing-state-kitty.conf")
    try "include \(missingStateRoot.path)/current/generated/kitty.conf\n".write(
      to: missingStateKittyConfigurationURL,
      atomically: true,
      encoding: .utf8
    )
    var missingUserRoot = try #require(
      Macarchy.parseAsRoot([
        "theme", "set", "catppuccin-mocha",
        "--themes-root", repositoryRoot.appending(path: "Themes").path,
        "--state-root", missingStateRoot.path,
        "--kitty-config", missingStateKittyConfigurationURL.path,
        "--dry-run",
      ]) as? Theme.Set
    )
    try await missingUserRoot.run()

    var failure = try #require(
      Macarchy.parseAsRoot([
        "theme", "set", "catppuccin-mocha",
        "--themes-root", builtInRoot.path,
        "--state-root", stateRoot.path,
        "--kitty-config", root.appending(path: "missing-kitty.conf").path,
      ]) as? Theme.Set
    )
    await #expect(throws: ExitCode.failure) {
      try await failure.run()
    }
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
