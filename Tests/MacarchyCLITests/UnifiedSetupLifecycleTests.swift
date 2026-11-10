import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupLifecycleTests {
  @Test
  func inspectionRecognizesAnEmptySupportedBaselineWithoutDelegating() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let runner = UnifiedSetupInspectionCommandRunner(
      planner: fixture.planner(),
      themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      desktopInspection: { _, _, _, _ in
        calls.withLock { $0 += 1 }
        throw UnexpectedComponentCall()
      },
      environmentInspection: { _, _, _, _ in
        calls.withLock { $0 += 1 }
        throw UnexpectedComponentCall()
      }
    )

    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let execution = try runner.execute(
        operation: operation,
        context: fixture.context,
        consumerPaths: testConsumerPaths(),
        json: true
      )
      let report = try jsonObject(execution.output)

      #expect(execution.succeeded)
      #expect(report["outcome"] as? String == "absent")
      #expect((report["theme"] as? [String: Any])?["status"] as? String == "absent")
    }
    #expect(calls.withLock { $0 } == 0)
  }

  @Test(arguments: [false, true])
  func statusRequiresThemeAndPackageEvidenceForConvergence(missingPackage: Bool) throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try "schema_version = 1\n[packages]\nbaseline = 'standard'\n".write(
      to: fixture.context.profileURL, atomically: true, encoding: .utf8)
    guard case .ready(let model, _) = try fixture.planner().prepare(context: fixture.context) else {
      Issue.record("Expected a ready unified model")
      return
    }
    let incomplete = UnifiedSetupThemeLifecycleStatus.inspect(
      model: model,
      ownership: try SetupCoreOwnershipStore(stateRoot: fixture.state).read(),
      stateRoot: fixture.state
    )
    #expect(!incomplete.succeeded)
    #expect(incomplete.status == "drifted")

    var planner = fixture.planner()
    planner.standardBrewfile = { _ in
      SetupBrewfile(packages: missingPackage ? [.init(kind: .formula, name: "jq")] : [])
    }
    let runner = UnifiedSetupInspectionCommandRunner(
      planner: planner,
      themeInspection: { model, ownership, _ in
        UnifiedSetupThemeLifecycleStatus(
          succeeded: ownership?.themeGenerationID == model.theme.currentGenerationID,
          status: "managed",
          generationID: model.theme.currentGenerationID,
          message: "current"
        )
      },
      desktopInspection: { _, _, _, _ in desktopInspectionStub() },
      environmentInspection: { _, _, _, _ in environmentInspectionStub() }
    )

    let execution = try runner.execute(
      operation: .status,
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded == !missingPackage)
    #expect(report["outcome"] as? String == (missingPackage ? "drifted" : "converged"))
    if missingPackage {
      #expect(
        (report["message"] as? String)?.contains("Missing setup packages: formula:jq") == true)
    }
    #expect((report["theme"] as? [String: Any])?["status"] as? String == "managed")
  }

  @Test
  func teardownPreflightsThenRestoresComponentsInReverseApplyOrder() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let generationID = "g-\(UUID().uuidString.lowercased())"
    try SetupCoreOwnershipStore(stateRoot: fixture.state).write(
      SetupCoreOwnership(themeGenerationID: generationID, originalAppearance: .light)
    )
    let calls = Mutex([String]())
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, dryRun in
        calls.withLock { $0.append("environment:\(dryRun ? "preview" : "apply")") }
        return environmentTeardownStub(dryRun: dryRun, mutated: !dryRun)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "apply")") }
        return desktopTeardownStub(dryRun: dryRun, mutated: !dryRun)
      },
      themeTeardown: { _, ownership, _, dryRun in
        #expect(ownership?.themeGenerationID == generationID)
        calls.withLock { $0.append("theme:\(dryRun ? "preview" : "apply")") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: !dryRun,
          outcome: dryRun ? "planned" : "restored",
          message: "theme",
          details: nil
        )
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "restored")
    #expect(report["packages"] as? String == "retained_external")
    #expect(
      calls.withLock { $0 }
        == [
          "environment:preview", "desktop:preview", "theme:preview",
          "environment:apply", "desktop:apply", "theme:apply",
        ]
    )
  }

  @Test
  func interruptedTeardownResumesForwardFromItsRecordedStage() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let paths = testConsumerPaths()
    let generationID = "g-\(UUID().uuidString.lowercased())"
    try SetupCoreOwnershipStore(stateRoot: fixture.state).write(
      SetupCoreOwnership(themeGenerationID: generationID, originalAppearance: .light)
    )
    let calls = Mutex([String]())
    let didInterrupt = Mutex(false)
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, dryRun in
        calls.withLock { $0.append("environment:\(dryRun ? "preview" : "apply")") }
        if dryRun, didInterrupt.withLock({ $0 }) {
          Issue.record("Recovery must resume the component transaction instead of previewing it")
        }
        return environmentTeardownStub(dryRun: dryRun, mutated: !dryRun)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "apply")") }
        return desktopTeardownStub(dryRun: dryRun, mutated: !dryRun)
      },
      themeTeardown: { _, _, _, dryRun in
        calls.withLock { $0.append("theme:\(dryRun ? "preview" : "apply")") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: !dryRun,
          outcome: dryRun ? "planned" : "restored",
          message: "theme",
          details: nil
        )
      },
      faultInjector: { checkpoint in
        guard case .environmentTornDown = checkpoint else { return }
        let shouldInterrupt = didInterrupt.withLock { interrupted in
          guard !interrupted else { return false }
          interrupted = true
          return true
        }
        if shouldInterrupt { throw UnifiedSetupInterruptionError.injected }
      }
    )

    await #expect(throws: UnifiedSetupInterruptionError.self) {
      try await runner.execute(
        context: fixture.context,
        consumerPaths: paths,
        dryRun: false,
        json: true
      )
    }
    #expect(
      try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.stages
        == [.environment, .desktop, .theme]
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: paths,
      dryRun: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "restored")
    #expect(
      calls.withLock { $0 }
        == [
          "environment:preview", "desktop:preview", "theme:preview",
          "environment:apply",
          "environment:apply", "desktop:apply", "theme:apply",
        ]
    )
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func pendingRecoveryBlocksInspectionAndDryRunWithoutMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let paths = testConsumerPaths()
    let store = UnifiedSetupTransactionStore(stateRoot: fixture.state)
    let transaction = UnifiedSetupTransaction(
      operation: .apply,
      stages: [.theme],
      desiredAppearance: .dark,
      contextDigest: unifiedSetupContextDigest(context: fixture.context, consumerPaths: paths)
    )
    try store.write(transaction)
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, _ in
        Issue.record("Blocked recovery must not invoke component recovery")
        throw UnexpectedComponentCall()
      },
      desktopTeardown: { _, _, _ in
        Issue.record("Blocked recovery must not invoke component recovery")
        throw UnexpectedComponentCall()
      },
      themeTeardown: { _, _, _, _ in
        Issue.record("Blocked recovery must not invoke theme recovery")
        return .noChange("unexpected")
      }
    )
    let inspection = UnifiedSetupInspectionCommandRunner(
      planner: fixture.planner(),
      themeInspection: { _, _, _ in
        Issue.record("Pending recovery must block theme inspection")
        return UnifiedSetupThemeLifecycleStatus(
          succeeded: false,
          status: "unexpected",
          generationID: nil,
          message: "unexpected"
        )
      },
      desktopInspection: { _, _, _, _ in
        Issue.record("Pending recovery must block delegated inspection")
        throw UnexpectedComponentCall()
      },
      environmentInspection: { _, _, _, _ in
        Issue.record("Pending recovery must block delegated inspection")
        throw UnexpectedComponentCall()
      }
    )

    let plan = try fixture.planner().execute(context: fixture.context, json: true)
    let planReport = try jsonObject(plan.output)
    let preview = try await teardown.execute(
      context: fixture.context,
      consumerPaths: paths,
      dryRun: true,
      json: true
    )
    let previewReport = try jsonObject(preview.output)

    #expect(!plan.succeeded)
    #expect(planReport["outcome"] as? String == "recovery_required")
    #expect(
      (planReport["diagnostics"] as? [[String: Any]])?.first?["code"] as? String
        == "setup_recovery_required"
    )
    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let result = try inspection.execute(
        operation: operation,
        context: fixture.context,
        consumerPaths: paths,
        json: true
      )
      #expect(!result.succeeded)
      #expect(try jsonObject(result.output)["outcome"] as? String == "recovery_required")
    }
    #expect(!preview.succeeded)
    #expect(previewReport["outcome"] as? String == "recovery_required")
    #expect(try store.read() == transaction)

    let original = fixture.context
    let mismatched = UnifiedSetupPlanContext(
      themesRoot: original.themesRoot,
      keybindingsResourcesRoot: original.keybindingsResourcesRoot,
      desktopResourcesRoot: original.desktopResourcesRoot,
      environmentResourcesRoot: original.environmentResourcesRoot,
      profileURL: original.profileURL,
      profileRequired: original.profileRequired,
      machineProfileURL: original.machineProfileURL,
      machineProfileRequired: original.machineProfileRequired,
      stateRoot: original.stateRoot,
      homeDirectory: fixture.root.appending(path: "different-home")
    )
    await #expect(throws: UnifiedSetupTransactionError.self) {
      try await teardown.recover(
        transaction: transaction,
        context: mismatched,
        consumerPaths: paths
      )
    }
    #expect(try store.read() == transaction)
  }

  @Test
  func blockedTeardownPreflightMakesNoChanges() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex([String]())
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, dryRun in
        calls.withLock { $0.append("environment:\(dryRun)") }
        return environmentTeardownStub(dryRun: dryRun, mutated: false)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun)") }
        return desktopTeardownStub("blocked", message: "unsafe")
      },
      themeTeardown: { _, _, _, _ in
        Issue.record("Theme preflight must not run after a blocked desktop preflight")
        return .noChange("unexpected")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(calls.withLock { $0 } == ["environment:true", "desktop:true"])
  }

  @Test func themeRetirementReceiptIsOptionalStrictAndSurvivesStageUpdates() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let store = UnifiedSetupTransactionStore(stateRoot: fixture.state)
    let old = UnifiedSetupTransaction(
      operation: .teardown, stages: [.theme], desiredAppearance: .dark,
      contextDigest: "sha256:" + String(repeating: "a", count: 64))
    try store.write(old)
    #expect(try store.read() == old)
    #expect(
      !String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains("theme_retirement")
    )
    let generation = "g-00000000-0000-0000-0000-000000000000"
    let pending = old.replacing(themeRetirement: .init(generationID: generation, committed: false))
    try store.write(pending)
    #expect(try store.read() == pending)
    let committed = pending.replacing(
      themeRetirement: .init(generationID: generation, committed: true))
    try store.write(committed.replacing(phase: .committing, stages: []))
    #expect(try store.read()?.themeRetirement == committed.themeRetirement)
    #expect(throws: UnifiedSetupTransactionError.self) {
      try store.write(
        old.replacing(themeRetirement: .init(generationID: "../bad", committed: true)))
    }
    #expect(throws: UnifiedSetupTransactionError.self) {
      try store.write(
        UnifiedSetupTransaction(
          operation: .apply, stages: [.theme], desiredAppearance: .dark,
          contextDigest: old.contextDigest, themeRetirement: committed.themeRetirement))
    }
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
    object["theme_retirement"] = [
      "generation_id": generation, "committed": true, "unexpected": true,
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: store.url)
    #expect(throws: UnifiedSetupTransactionError.self) { try store.read() }
  }

  @Test
  func setupCoreOwnershipIsStrictAndRemovable() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let store = SetupCoreOwnershipStore(stateRoot: fixture.state)
    let ownership = SetupCoreOwnership(
      themeGenerationID: "g-\(UUID().uuidString.lowercased())",
      originalAppearance: .dark
    )

    try store.write(ownership)
    #expect(try store.read() == ownership)
    try store.remove()
    #expect(try store.read() == nil)

    try FileManager.default.createDirectory(
      at: store.url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try
      #"{"schema_version":1,"theme_generation_id":"g-00000000-0000-0000-0000-000000000000","original_appearance":"dark","unexpected":true}"#
      .write(
        to: store.url,
        atomically: true,
        encoding: .utf8
      )
    #expect(throws: SetupCoreOwnershipError.self) { try store.read() }
  }
}
