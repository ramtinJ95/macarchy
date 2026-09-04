import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupLifecycleTests {
  @Test
  func inspectionRecognizesAnEmptySupportedBaselineWithoutDelegating() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let unexpected: UnifiedSetupInspectionCommandRunner.ComponentInspection = { _, _, _, _ in
      calls.withLock { $0 += 1 }
      return try applyComponent("{}")
    }
    let runner = UnifiedSetupInspectionCommandRunner(
      planner: fixture.planner(),
      themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      desktopInspection: unexpected,
      environmentInspection: unexpected
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

  @Test
  func statusRequiresThemeEvidenceBeforeReportingTheManagedCoreAsConverged() throws {
    let fixture = try ApplyFixture()
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    let manifest = try ThemeActivator(root: fixture.state).activate(package: package)
    try SetupCoreOwnershipStore(stateRoot: fixture.state).write(
      SetupCoreOwnership(themeGenerationID: manifest.generationID, originalAppearance: .light)
    )
    defer {
      _ = try? ThemeActivator(root: fixture.state).deactivate(
        expectedGenerationID: manifest.generationID,
        dryRun: false
      )
      fixture.cleanup()
    }
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

    let component: UnifiedSetupInspectionCommandRunner.ComponentInspection = { _, _, _, _ in
      try applyComponent(#"{"outcome":"current"}"#)
    }
    let runner = UnifiedSetupInspectionCommandRunner(
      planner: fixture.planner(),
      themeInspection: { model, ownership, _ in
        UnifiedSetupThemeLifecycleStatus(
          succeeded: ownership?.themeGenerationID == model.theme.currentGenerationID,
          status: "managed",
          generationID: model.theme.currentGenerationID,
          message: "current"
        )
      },
      desktopInspection: component,
      environmentInspection: component
    )

    let execution = try runner.execute(
      operation: .status,
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "converged")
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
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "apply")") }
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
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
  func blockedTeardownPreflightMakesNoChanges() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex([String]())
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(),
      environmentTeardown: { _, _, dryRun in
        calls.withLock { $0.append("environment:\(dryRun)") }
        return try teardownComponent(dryRun: dryRun, mutated: false)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun)") }
        return try applyComponent(
          #"{"outcome":"blocked","message":"unsafe"}"#,
          succeeded: false
        )
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

private func teardownComponent(dryRun: Bool, mutated: Bool) throws -> SetupComponentExecution {
  try applyComponent(
    """
    {"outcome":"\(dryRun ? "planned" : mutated ? "restored" : "no_change")","mutated":\(mutated),"message":"component"}
    """
  )
}
