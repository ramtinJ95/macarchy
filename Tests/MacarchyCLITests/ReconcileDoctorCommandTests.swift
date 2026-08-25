import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ReconcileDoctorCommandTests {
  @Test
  func reconcileDryRunAndRequiredFailureMatchOutputContracts() async throws {
    let manifest = testManifest()
    let dryRun = ReconcileCommandRunner(
      preview: { _, _, _ in
        (
          manifest,
          [AdapterInspection(adapterID: "kitty", requirement: .required)]
        )
      },
      reconcile: { _, _, _ in throw TestFailure.unexpectedOperation }
    )
    try await expectReconcileGoldens(
      runner: dryRun,
      basename: "dry-run",
      dryRun: true,
      succeeded: true
    )

    let failedRecord = try ReconciliationRecord(
      manifest: manifest,
      results: [
        AdapterResult(
          adapterID: "kitty",
          requirement: .required,
          status: .failed,
          message: "reload denied"
        )
      ]
    )
    let requiredFailure = ReconcileCommandRunner(
      preview: { _, _, _ in throw TestFailure.unexpectedOperation },
      reconcile: { _, _, _ in (manifest, failedRecord) }
    )
    try await expectReconcileGoldens(
      runner: requiredFailure,
      basename: "required-failure",
      dryRun: false,
      succeeded: false
    )
  }

  @Test
  func reconcileInspectionFailureIsNonzeroWithoutRunningReconciliation() async throws {
    let runner = ReconcileCommandRunner(
      preview: { _, _, _ in
        (
          testManifest(),
          [
            AdapterInspection(
              adapterID: "kitty",
              requirement: .required,
              status: .drifted,
              message: "Kitty configuration is missing the stable include"
            )
          ]
        )
      },
      reconcile: { _, _, _ in throw TestFailure.unexpectedOperation }
    )

    let execution = try await runner.execute(
      adapterIDs: [],
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: true,
      json: false
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("kitty [required]: drifted"))
    #expect(execution.output.contains("No files written; no processes run."))
  }

  @Test
  func optionalInspectionProblemsRemainVisibleWithoutFailingCommands() async throws {
    let manifest = testManifest()
    let inspection = AdapterInspection(
      adapterID: "spicetify",
      requirement: .optional,
      status: .failed,
      message: "executable is unavailable"
    )
    let reconcile = ReconcileCommandRunner(
      preview: { _, _, _ in (manifest, [inspection]) },
      reconcile: { _, _, _ in throw TestFailure.unexpectedOperation }
    )
    let reconciliation = try await reconcile.execute(
      adapterIDs: [],
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: true,
      json: false
    )
    #expect(reconciliation.succeeded)
    #expect(reconciliation.output.contains("spicetify [optional]: failed"))

    let record = try ReconciliationRecord(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "atuin", requirement: .required, status: .applied),
        AdapterResult(adapterID: "bat", requirement: .required, status: .applied),
        AdapterResult(adapterID: "btop", requirement: .required, status: .applied),
        AdapterResult(adapterID: "codex", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "eza", requirement: .required, status: .applied),
        AdapterResult(adapterID: "herdr", requirement: .required, status: .applied),
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "macos-appearance",
          requirement: .required,
          status: .applied
        ),
        AdapterResult(adapterID: "neovim", requirement: .required, status: .applied),
        AdapterResult(adapterID: "pi", requirement: .required, status: .applied),
        AdapterResult(adapterID: "sketchybar", requirement: .required, status: .applied),
        AdapterResult(adapterID: "starship", requirement: .required, status: .applied),
        AdapterResult(adapterID: "tuicr", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "wallpaper", requirement: .required, status: .applied),
        AdapterResult(adapterID: "yazi", requirement: .required, status: .applied),
      ]
    )
    let doctor = DoctorCommandRunner(
      read: { _ in .state(manifest: manifest, reconciliation: .current(record)) },
      inspect: { _, _ in [inspection] }
    )
    let diagnosis = try doctor.execute(
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      json: false
    )
    #expect(diagnosis.succeeded)
    #expect(diagnosis.output.contains("spicetify.integration [warning]"))
  }

  @Test
  func reconcileReportsAdapterOutcomesWhenStatusPersistenceFails() async throws {
    let manifest = testManifest()
    let results = [
      AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)
    ]
    let runner = ReconcileCommandRunner(
      preview: { _, _, _ in throw TestFailure.unexpectedOperation },
      reconcile: { _, _, _ in
        throw ReconciliationPersistenceError(
          manifest: manifest,
          results: results,
          cause: "active generation changed"
        )
      }
    )

    let human = try await runner.execute(
      adapterIDs: [],
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: false,
      json: false
    )
    #expect(!human.succeeded)
    #expect(human.output.contains("Observed reconciliation:\n- kitty [required]: applied"))
    #expect(human.output.contains("Reconciliation status was not updated."))

    let json = try await runner.execute(
      adapterIDs: [],
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      dryRun: false,
      json: true
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
    )
    #expect(object["outcome"] as? String == "persistence_failure")
    #expect((object["reconciliation"] as? [[String: Any]])?.count == 1)
  }

  @Test
  func doctorMatchesHealthyAndBrokenIntegrationContracts() throws {
    let manifest = testManifest()
    let healthyRecord = try ReconciliationRecord(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "atuin", requirement: .required, status: .applied),
        AdapterResult(adapterID: "bat", requirement: .required, status: .applied),
        AdapterResult(adapterID: "btop", requirement: .required, status: .applied),
        AdapterResult(adapterID: "codex", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "eza", requirement: .required, status: .applied),
        AdapterResult(adapterID: "herdr", requirement: .required, status: .applied),
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "macos-appearance",
          requirement: .required,
          status: .applied
        ),
        AdapterResult(adapterID: "neovim", requirement: .required, status: .applied),
        AdapterResult(adapterID: "pi", requirement: .required, status: .applied),
        AdapterResult(adapterID: "sketchybar", requirement: .required, status: .applied),
        AdapterResult(adapterID: "starship", requirement: .required, status: .applied),
        AdapterResult(adapterID: "tuicr", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "wallpaper", requirement: .required, status: .applied),
        AdapterResult(adapterID: "yazi", requirement: .required, status: .applied),
      ]
    )
    let healthy = DoctorCommandRunner(
      read: { _ in .state(manifest: manifest, reconciliation: .current(healthyRecord)) },
      inspect: { _, _ in
        [
          AdapterInspection(
            adapterID: "macos-appearance",
            requirement: .required,
            message:
              "Appearance state is readable and /usr/bin/osascript is executable; Apple Events authorization is untested until a change is required"
          ),
          AdapterInspection(adapterID: "atuin", requirement: .required),
          AdapterInspection(adapterID: "bat", requirement: .required),
          AdapterInspection(adapterID: "btop", requirement: .required),
          AdapterInspection(adapterID: "codex", requirement: .required),
          AdapterInspection(adapterID: "eza", requirement: .required),
          AdapterInspection(adapterID: "herdr", requirement: .required),
          AdapterInspection(adapterID: "kitty", requirement: .required),
          AdapterInspection(adapterID: "neovim", requirement: .required),
          AdapterInspection(adapterID: "pi", requirement: .required),
          AdapterInspection(adapterID: "sketchybar", requirement: .required),
          AdapterInspection(adapterID: "starship", requirement: .required),
          AdapterInspection(adapterID: "tuicr", requirement: .required),
          AdapterInspection(
            adapterID: "wallpaper",
            requirement: .required,
            message:
              "Wallpaper and presentation options are readable for 1 current display(s); inactive Spaces require lazy reconciliation; yabai space_changed is configured to reconcile each Space lazily through /test/macarchy; the yabai signal is loaded"
          ),
          AdapterInspection(adapterID: "yazi", requirement: .required),
        ]
      }
    )
    try expectDoctorGoldens(runner: healthy, basename: "healthy", succeeded: true)

    let failedRecord = try ReconciliationRecord(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "atuin", requirement: .required, status: .applied),
        AdapterResult(adapterID: "bat", requirement: .required, status: .applied),
        AdapterResult(adapterID: "btop", requirement: .required, status: .applied),
        AdapterResult(adapterID: "codex", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "eza", requirement: .required, status: .applied),
        AdapterResult(adapterID: "herdr", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "kitty",
          requirement: .required,
          status: .failed,
          message: "reload denied"
        ),
        AdapterResult(
          adapterID: "macos-appearance",
          requirement: .required,
          status: .applied
        ),
        AdapterResult(adapterID: "neovim", requirement: .required, status: .applied),
        AdapterResult(adapterID: "pi", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "sketchybar",
          requirement: .required,
          status: .drifted,
          message: "SketchyBar colors module is missing the generated palette import"
        ),
        AdapterResult(adapterID: "starship", requirement: .required, status: .applied),
        AdapterResult(adapterID: "tuicr", requirement: .required, status: .restartRequired),
        AdapterResult(adapterID: "wallpaper", requirement: .required, status: .applied),
        AdapterResult(adapterID: "yazi", requirement: .required, status: .applied),
      ]
    )
    let unhealthy = DoctorCommandRunner(
      read: { _ in .state(manifest: manifest, reconciliation: .current(failedRecord)) },
      inspect: { _, _ in
        [
          AdapterInspection(
            adapterID: "macos-appearance",
            requirement: .required,
            message:
              "Appearance state is readable and /usr/bin/osascript is executable; Apple Events authorization is untested until a change is required"
          ),
          AdapterInspection(adapterID: "atuin", requirement: .required),
          AdapterInspection(adapterID: "bat", requirement: .required),
          AdapterInspection(adapterID: "btop", requirement: .required),
          AdapterInspection(adapterID: "codex", requirement: .required),
          AdapterInspection(adapterID: "eza", requirement: .required),
          AdapterInspection(adapterID: "herdr", requirement: .required),
          AdapterInspection(
            adapterID: "kitty",
            requirement: .required,
            status: .drifted,
            message: "Kitty configuration is missing the stable include"
          ),
          AdapterInspection(adapterID: "neovim", requirement: .required),
          AdapterInspection(
            adapterID: "pi",
            requirement: .required,
            status: .drifted,
            message: "Pi settings must select theme \"macarchy-current\""
          ),
          AdapterInspection(
            adapterID: "sketchybar",
            requirement: .required,
            status: .drifted,
            message: "SketchyBar colors module is missing the generated palette import"
          ),
          AdapterInspection(adapterID: "starship", requirement: .required),
          AdapterInspection(adapterID: "tuicr", requirement: .required),
          AdapterInspection(
            adapterID: "wallpaper",
            requirement: .required,
            message:
              "Wallpaper and presentation options are readable for 1 current display(s); inactive Spaces require lazy reconciliation; yabai space_changed is configured to reconcile each Space lazily through /test/macarchy; the yabai signal is loaded"
          ),
          AdapterInspection(adapterID: "yazi", requirement: .required),
        ]
      }
    )
    try expectDoctorGoldens(runner: unhealthy, basename: "unhealthy", succeeded: false)
  }

  @Test
  func doctorStillInspectsKittyWhenCanonicalStateIsInvalid() throws {
    let runner = DoctorCommandRunner(
      read: { _ in
        throw ReconciliationStatusError.invalidActiveGeneration("current is not a symlink")
      },
      inspect: { _, _ in
        [AdapterInspection(adapterID: "kitty", requirement: .required)]
      }
    )

    let execution = try runner.execute(
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      json: false
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("canonical [failure]"))
    #expect(execution.output.contains("kitty.integration [ok]"))
  }

  @Test
  func doctorRejectsPersistedRequirementDowngrades() throws {
    let manifest = testManifest()
    let record = try ReconciliationRecord(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .optional, status: .failed)
      ]
    )
    let runner = DoctorCommandRunner(
      read: { _ in .state(manifest: manifest, reconciliation: .current(record)) },
      inspect: { _, _ in
        [AdapterInspection(adapterID: "kitty", requirement: .required)]
      }
    )

    let execution = try runner.execute(
      stateRoot: stateRoot,
      consumerPaths: consumerPaths,
      json: false
    )
    #expect(!execution.succeeded)
    #expect(execution.output.contains("Requirement is optional, expected required."))
  }

  private func expectReconcileGoldens(
    runner: ReconcileCommandRunner,
    basename: String,
    dryRun: Bool,
    succeeded: Bool
  ) async throws {
    for json in [false, true] {
      let execution = try await runner.execute(
        adapterIDs: [],
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        dryRun: dryRun,
        json: json
      )
      #expect(execution.succeeded == succeeded)
      try expectGolden(execution.output, basename: "reconcile-\(basename)", json: json)
    }
  }

  private func expectDoctorGoldens(
    runner: DoctorCommandRunner,
    basename: String,
    succeeded: Bool
  ) throws {
    for json in [false, true] {
      let execution = try runner.execute(
        stateRoot: stateRoot,
        consumerPaths: consumerPaths,
        json: json
      )
      #expect(execution.succeeded == succeeded)
      try expectGolden(execution.output, basename: "doctor-\(basename)", json: json)
    }
  }

  private func expectGolden(_ output: String, basename: String, json: Bool) throws {
    let suffix = json ? "json" : "txt"
    let golden = try String(
      contentsOf: fixturesRoot.appending(path: "\(basename).\(suffix)"),
      encoding: .utf8
    )
    #expect(output + "\n" == golden)
  }

  private var stateRoot: URL {
    URL(filePath: "/test/state", directoryHint: .isDirectory)
  }

  private var consumerPaths: ThemeConsumerPaths {
    testConsumerPaths()
  }

  private var fixturesRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures/CLI", directoryHint: .isDirectory)
  }
}

private enum TestFailure: Error {
  case unexpectedOperation
}

private func testManifest() -> GenerationManifest {
  GenerationManifest(
    generationID: "g-active-generation",
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
