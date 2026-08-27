import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeNextStatusCommandTests {
  @Test
  func nextUsesRepositoryOrderAndWraps() async throws {
    for (active, expected) in [
      ("catppuccin-mocha", "kanagawa-wave"),
      ("kanagawa-wave", "tokyo-night"),
      ("tokyo-night", "catppuccin-mocha"),
    ] {
      let selected = Mutex<String?>(nil)
      let activation = ThemeSetCommandRunner(
        preflight: { package, _, _ in selected.withLock { $0 = package.id } },
        activate: { _, _, _, _ in throw TestError.unexpectedActivation }
      )
      let runner = ThemeNextCommandRunner(
        activeManifest: { _ in testManifest(themeID: active) },
        activation: activation
      )

      let execution = try await runner.execute(
        repository: repository,
        stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
        consumerPaths: testConsumerPaths(),
        dryRun: true
      )

      #expect(execution.succeeded)
      #expect(selected.withLock { $0 } == expected)
      #expect(execution.output.contains("Theme '\(expected)' is valid."))
    }
  }

  @Test
  func nextRejectsAnActiveThemeOutsideTheValidatedRepository() async {
    let runner = ThemeNextCommandRunner(
      activeManifest: { _ in testManifest(themeID: "removed-theme") },
      activation: ThemeSetCommandRunner(
        preflight: { _, _, _ in },
        activate: { _, _, _, _ in throw TestError.unexpectedActivation }
      )
    )

    await #expect(throws: ThemeNextError.activeThemeUnavailable("removed-theme")) {
      _ = try await runner.execute(
        repository: repository,
        stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
        consumerPaths: testConsumerPaths(),
        dryRun: true
      )
    }

    let inactive = ThemeNextCommandRunner(
      activeManifest: { _ in throw ReconciliationStatusError.noActiveGeneration },
      activation: runner.activation
    )
    await #expect(throws: ThemeNextError.noActiveTheme) {
      _ = try await inactive.execute(
        repository: repository,
        stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
        consumerPaths: testConsumerPaths(),
        dryRun: true
      )
    }
  }

  @Test
  func nextRetriesWhenTheObservedGenerationIsSupersededDuringActivation() async throws {
    let canonical = Mutex(testManifest(generationID: "g-initial", themeID: "catppuccin-mocha"))
    let attempts = Mutex([String]())
    let activation = ThemeSetCommandRunner(
      preflight: { _, _, _ in },
      activate: { package, _, _, expectedGenerationID in
        let attempt = attempts.withLock { attempts in
          attempts.append(package.id)
          return attempts.count
        }
        if attempt == 1 {
          canonical.withLock {
            $0 = testManifest(generationID: "g-superseding", themeID: "kanagawa-wave")
          }
          throw ThemeActivationError.activeGenerationChanged(
            expected: expectedGenerationID ?? "none",
            active: "g-superseding"
          )
        }
        let manifest = testManifest(
          generationID: "g-\(package.id)-\(UUID().uuidString)",
          themeID: package.id
        )
        try canonical.withLock { current in
          guard current.generationID == expectedGenerationID else {
            throw ThemeActivationError.activeGenerationChanged(
              expected: expectedGenerationID ?? "none",
              active: current.generationID
            )
          }
          current = manifest
        }
        return ThemeActivationResult(
          manifest: manifest,
          reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
        )
      }
    )
    let runner = ThemeNextCommandRunner(
      activeManifest: { _ in canonical.withLock { $0 } },
      activation: activation
    )
    let stateRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-theme-next-command-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let consumerPaths = testConsumerPaths()

    let execution = try await runner.execute(
      repository: repository,
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: false
    )

    #expect(attempts.withLock { $0 } == ["kanagawa-wave", "tokyo-night"])
    #expect(canonical.withLock { $0.themeID } == "tokyo-night")
    #expect(execution.output.hasPrefix("Activated 'tokyo-night'"))
  }

  @Test
  func statusMatchesCurrentMissingAndStaleContracts() throws {
    let active = testManifest(themeID: "catppuccin-mocha")
    let current = try ReconciliationRecord(
      manifest: active,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)
      ]
    )
    let staleManifest = testManifest(
      generationID: "g-previous-generation",
      themeID: "tokyo-night"
    )
    let stale = try ReconciliationRecord(
      manifest: staleManifest,
      results: [
        AdapterResult(
          adapterID: "kitty",
          requirement: .required,
          status: .failed,
          message: "reload denied"
        )
      ]
    )
    let cases: [(String, ReconciliationState, Bool)] = [
      ("current", .current(current), true),
      ("missing", .missing(activeGenerationID: active.generationID), false),
      (
        "stale",
        .stale(activeGenerationID: active.generationID, record: stale),
        false
      ),
    ]

    for (basename, reconciliation, succeeded) in cases {
      let runner = ThemeStatusCommandRunner(read: { _ in
        .state(manifest: active, reconciliation: reconciliation)
      })
      try expectStatusGoldens(runner: runner, basename: basename, succeeded: succeeded)
    }

    let requiredFailure = try ReconciliationRecord(
      manifest: active,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .failed)
      ]
    )
    let optionalFailure = try ReconciliationRecord(
      manifest: active,
      results: [
        AdapterResult(adapterID: "spicetify", requirement: .optional, status: .failed)
      ]
    )
    for (record, succeeded) in [(requiredFailure, false), (optionalFailure, true)] {
      let execution = try ThemeStatusCommandRunner(read: { _ in
        .state(manifest: active, reconciliation: .current(record))
      }).execute(
        stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
        json: false
      )
      #expect(execution.succeeded == succeeded)
    }
  }

  @Test
  func statusReportsInactiveAndReadFailureInBothOutputFormats() throws {
    let inactive = ThemeStatusCommandRunner(read: { _ in
      throw ReconciliationStatusError.noActiveGeneration
    })
    try expectStatusGoldens(runner: inactive, basename: "inactive", succeeded: false)

    let failure = ThemeStatusCommandRunner(read: { _ in throw TestError.statusRead })
    try expectStatusGoldens(runner: failure, basename: "failure", succeeded: false)

    let activeFailure = ThemeStatusCommandRunner(read: { _ in
      .reconciliationFailure(
        manifest: testManifest(themeID: "catppuccin-mocha"),
        error: "Cannot decode reconciliation status"
      )
    })
    try expectStatusGoldens(
      runner: activeFailure,
      basename: "active-failure",
      succeeded: false
    )
  }

  private func expectStatusGoldens(
    runner: ThemeStatusCommandRunner,
    basename: String,
    succeeded: Bool
  ) throws {
    for json in [false, true] {
      let execution = try runner.execute(
        stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory),
        json: json
      )
      #expect(execution.succeeded == succeeded)
      let suffix = json ? "json" : "txt"
      let golden = try String(
        contentsOf: fixturesRoot.appending(path: "theme-status-\(basename).\(suffix)"),
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
}

private enum TestError: Error, CustomStringConvertible {
  case statusRead
  case unexpectedActivation

  var description: String {
    switch self {
    case .statusRead:
      "Cannot decode active generation manifest"
    case .unexpectedActivation:
      "Unexpected activation"
    }
  }
}

private func testManifest(
  generationID: String = "g-active-generation",
  themeID: String
) -> GenerationManifest {
  GenerationManifest(
    generationID: generationID,
    themeID: themeID,
    themeSchemaVersion: 1,
    inputDigest: "sha256:test",
    rendererVersions: ["kitty": 1, "normalized_theme": 1],
    artifacts: [
      "generated/kitty.conf": "sha256:kitty",
      "theme.json": "sha256:theme",
    ]
  )
}
