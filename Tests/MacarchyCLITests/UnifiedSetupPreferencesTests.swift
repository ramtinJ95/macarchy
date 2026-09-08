import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupPreferencesTests {
  @Test(arguments: [false, true])
  func nativeApprovalIsRequiredBeforePackageOrCoreMutation(stale: Bool) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try selectDock(true, fixture: fixture)
    let os = PreferencesTests.MemoryPreferences()
    let runner = fixture.runner(
      available: { _ in true }, preferences: .init(native: os.native),
      packages: .init(packages: [.init(kind: .formula, name: "jq")]),
      theme: { _, _ in
        Issue.record("Unapproved preferences must block before theme apply")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        Issue.record("Unapproved preferences must block before desktop apply")
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        Issue.record("Unapproved preferences must block before environment apply")
        return try applyComponent("{}")
      })
    let plan = try runner.planner.prepare(context: fixture.context).report
    #expect(try plan.preferencesApprovalDigest != nil)
    #expect(plan.packageInstallation?.approvalDigest != nil)
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      packageApproval: plan.packageInstallation?.approvalDigest,
      preferencesApproval: stale ? "sha256:stale" : nil, json: true)
    #expect(!result.succeeded)
    #expect(result.output.contains("--approve-preferences"))
    #expect(os.state.withLock { $0.writes.isEmpty })
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "state/preferences").path))
  }

  @Test
  func preferencesRunLastCommitWithSetupAndRemainNoOpAndInspectable() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try selectDock(true, fixture: fixture)
    let os = PreferencesTests.MemoryPreferences()
    let calls = Mutex([String]())
    let lifecycle = PreferencesLifecycle(
      native: .init(
        read: os.native.read,
        write: { key, value in
          calls.withLock { $0.append("preferences") }
          try os.native.write(key, value)
        }))
    let store = try PreferencesStore(context: fixture.context.preferencesContext)
    let runner = fixture.runner(
      available: { _ in true }, plannedStages: [.desktop, .environment], preferences: lifecycle,
      theme: { _, _ in
        Issue.record("Existing theme must be preserved")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0.append("desktop") }
        return try applyComponent(#"{"outcome":"applied","mutated":true}"#)
      },
      environment: { _, _, _, _, _ in
        calls.withLock { $0.append("environment") }
        return try applyComponent(#"{"outcome":"applied","mutated":true}"#)
      },
      faultInjector: { checkpoint in
        if case .preferencesApplied = checkpoint {
          let staged = try store.read()
          #expect(staged.pending?.phase == .ready)
          #expect(staged.owned.isEmpty)
        }
      })
    let plan = try runner.planner.prepare(context: fixture.context).report
    let approval = try plan.preferencesApprovalDigest
    #expect(try plan.render(json: false).contains("not native preferences"))
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), preferencesApproval: approval,
      json: true)
    #expect(result.succeeded)
    #expect(!result.output.contains("pending_commit"))
    #expect(calls.withLock { $0 } == ["desktop", "environment", "preferences"])
    #expect(try store.read().owned == [.init(key: .dockAutohide, original: false, applied: true)])
    #expect(try store.read().pending == nil)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
    let receipt = try Data(contentsOf: store.url)
    let noOpRunner = preferencesOnlyRunner(fixture: fixture, lifecycle: lifecycle)
    let noOp = try await noOpRunner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(noOp.succeeded)
    #expect(try jsonObject(noOp.output)["outcome"] as? String == "no_change")
    #expect(try Data(contentsOf: store.url) == receipt)
    #expect(os.state.withLock { $0.writes.count == 1 && !$0.reads.contains(.finderShowExtensions) })

    let inspection = inspector(planner: noOpRunner.planner)
    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let inspected = try inspection.execute(
        operation: operation, context: fixture.context, consumerPaths: testConsumerPaths(),
        json: true)
      #expect(inspected.succeeded)
      let preferences = try #require(jsonObject(inspected.output)["preferences"] as? [String: Any])
      #expect(preferences["outcome"] as? String == "no_change")
    }
  }

  @Test
  func interruptedUnifiedApplyRestoresPreviousManagedValuesWithoutReplayingIntent() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let os = PreferencesTests.MemoryPreferences()
    let lifecycle = PreferencesLifecycle(native: os.native)
    let context = try fixture.context.preferencesContext
    let previous = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    _ = try lifecycle.apply(
      context: context, desired: previous,
      approval: lifecycle.plan(context: context, desired: previous).report.approvalDigest)
    let store = PreferencesStore(context: context)
    let receipt = try store.read()
    try selectDock(false, fixture: fixture)
    let runner = preferencesOnlyRunner(
      fixture: fixture, lifecycle: lifecycle,
      checkpoint: { checkpoint in
        if case .preferencesApplied = checkpoint { throw UnifiedSetupInterruptionError.injected }
      })
    let approval = try runner.planner.prepare(context: fixture.context).report
      .preferencesApprovalDigest
    await #expect(throws: UnifiedSetupInterruptionError.self) {
      try await runner.execute(
        context: fixture.context, consumerPaths: testConsumerPaths(), preferencesApproval: approval,
        json: true)
    }
    #expect(os.state.withLock { $0.values[.dockAutohide] == false })
    #expect(try store.read().pending?.phase == .ready)
    try fixture.writeMachineProfile("invalid profile")
    let recovered = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(try jsonObject(recovered.output)["outcome"] as? String == "rolled_back")
    #expect(try store.read() == receipt)
    #expect(os.state.withLock { $0.values[.dockAutohide] == true })
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func unifiedCommitRecoveryVerifiesThenFinalizesForwardWithoutASetter() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let os = PreferencesTests.MemoryPreferences()
    let lifecycle = PreferencesLifecycle(native: os.native)
    let context = try fixture.context.preferencesContext
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    _ = try lifecycle.apply(
      context: context, desired: desired,
      approval: lifecycle.plan(context: context, desired: desired).report.approvalDigest,
      deferFinalization: true)
    let store = UnifiedSetupTransactionStore(stateRoot: fixture.state)
    try store.write(
      .init(
        operation: .apply, phase: .committing, stages: [.preferences], desiredAppearance: .dark,
        contextDigest: unifiedSetupContextDigest(
          context: fixture.context, consumerPaths: testConsumerPaths())))
    os.state.withLock { $0.values[.dockAutohide] = false }
    let runner = preferencesOnlyRunner(fixture: fixture, lifecycle: lifecycle)
    let blocked = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(try jsonObject(blocked.output)["outcome"] as? String == "recovery_required")
    #expect(try store.read()?.phase == .committing)
    #expect(try PreferencesStore(context: context).read().pending != nil)
    os.state.withLock { $0.values[.dockAutohide] = true }
    let recovered = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(recovered.succeeded)
    #expect(try store.read() == nil)
    #expect(try PreferencesStore(context: context).read().pending == nil)
    #expect(try PreferencesStore(context: context).read().owned.first?.applied == true)
    #expect(os.state.withLock { $0.writes.count == 1 })
  }

  @Test
  func teardownRestoresPreferencesFirstAndResumesAfterInterruption() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let os = PreferencesTests.MemoryPreferences()
    let calls = Mutex([String]())
    let lifecycle = PreferencesLifecycle(
      native: .init(
        read: os.native.read,
        write: { key, value in
          calls.withLock { $0.append("preferences") }
          try os.native.write(key, value)
        }))
    let context = try fixture.context.preferencesContext
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    _ = try lifecycle.apply(
      context: context, desired: desired,
      approval: lifecycle.plan(context: context, desired: desired).report.approvalDigest)
    try selectDock(true, fixture: fixture)
    calls.withLock { $0 = [] }
    let interrupt = Mutex(true)
    let runner = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(preferences: lifecycle),
      environmentTeardown: { _, _, preview in
        if !preview { calls.withLock { $0.append("environment") } }
        return try applyComponent(
          preview
            ? #"{"outcome":"planned","mutated":false}"# : #"{"outcome":"restored","mutated":true}"#)
      },
      desktopTeardown: { _, _, preview in
        if !preview { calls.withLock { $0.append("desktop") } }
        return try applyComponent(
          preview
            ? #"{"outcome":"planned","mutated":false}"# : #"{"outcome":"restored","mutated":true}"#)
      },
      themeTeardown: { _, _, _, preview in
        if !preview { calls.withLock { $0.append("theme") } }
        return .init(
          succeeded: true, mutated: !preview, outcome: preview ? "planned" : "restored",
          message: "theme", details: nil)
      },
      faultInjector: { checkpoint in
        if case .preferencesTornDown = checkpoint, interrupt.withLock({ $0 }) {
          throw UnifiedSetupInterruptionError.injected
        }
      })
    let store = PreferencesStore(context: context)
    let before = try Data(contentsOf: store.url)
    let preview = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: true, json: false)
    #expect(preview.succeeded)
    #expect(preview.output.contains("dock_autohide: true → false [restore]"))
    #expect(try Data(contentsOf: store.url) == before)
    #expect(calls.withLock { $0.isEmpty })
    await #expect(throws: UnifiedSetupInterruptionError.self) {
      try await runner.execute(
        context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    }
    #expect(try store.read().owned.isEmpty)
    #expect(calls.withLock { $0 } == ["preferences"])
    interrupt.withLock { $0 = false }
    let recovered = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(recovered.succeeded)
    #expect(calls.withLock { $0 } == ["preferences", "environment", "desktop", "theme"])
    #expect(
      os.state.withLock { $0.values == [.dockAutohide: false, .finderShowExtensions: false] })
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test(arguments: [false, true])
  func unsupportedCapabilityAndDriftBlockTheUnifiedPlanAndInspection(unsupported: Bool) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try selectDock(true, fixture: fixture)
    let os = PreferencesTests.MemoryPreferences()
    var lifecycle = PreferencesLifecycle(native: os.native)
    if unsupported {
      lifecycle = .init(
        native: .init(
          read: { _ in
            throw PreferencesError.unavailable(
              "Unsupported macOS version or unavailable Automation access.")
          }, write: { _, _ in Issue.record("Unsupported preferences must never be written") }))
    } else {
      let context = try fixture.context.preferencesContext
      let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
      _ = try lifecycle.apply(
        context: context, desired: desired,
        approval: lifecycle.plan(context: context, desired: desired).report.approvalDigest)
      os.state.withLock { $0.values[.dockAutohide] = false }
    }
    let planner = fixture.planner(preferences: lifecycle)
    let preparation = try planner.prepare(context: fixture.context)
    #expect(!preparation.succeeded)
    #expect(
      preparation.report.components?.preferences.outcome == (unsupported ? "blocked" : "drifted"))
    #expect(preparation.report.diagnostics.contains { $0.code == "preferences_plan_blocked" })
    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let result = try inspector(planner: planner).execute(
        operation: operation, context: fixture.context, consumerPaths: testConsumerPaths(),
        json: operation == .status)
      #expect(!result.succeeded)
      #expect(result.output.contains(unsupported ? "Unsupported macOS" : "last managed value"))
    }
    #expect(os.state.withLock { $0.writes.count == (unsupported ? 0 : 1) })
  }

  private func selectDock(_ value: Bool, fixture: ApplyFixture) throws {
    try fixture.writeMachineProfile(
      "schema_version = 1\n[macos_preferences]\nenabled = true\ndock_autohide = \(value)\n")
  }

  private func preferencesOnlyRunner(
    fixture: ApplyFixture, lifecycle: PreferencesLifecycle,
    checkpoint: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = { _ in }
  ) -> UnifiedSetupApplyCommandRunner {
    fixture.runner(
      available: { _ in true }, preferences: lifecycle,
      theme: { _, _ in
        Issue.record("No theme mutation expected")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        Issue.record("No desktop mutation expected")
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        Issue.record("No environment mutation expected")
        return try applyComponent("{}")
      },
      faultInjector: checkpoint)
  }

  private func inspector(planner: UnifiedSetupPlanCommandRunner)
    -> UnifiedSetupInspectionCommandRunner
  {
    .init(
      planner: planner,
      themeInspection: { model, ownership, _ in
        .init(
          succeeded: true, status: ownership == nil ? "absent" : "managed",
          generationID: model.theme.currentGenerationID, message: "fixture")
      },
      desktopInspection: { _, _, _, _ in try applyComponent(#"{"outcome":"current"}"#) },
      environmentInspection: { _, _, _, _ in try applyComponent(#"{"outcome":"current"}"#) })
  }
}
