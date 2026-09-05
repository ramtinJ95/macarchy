import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct DesktopAggregateCommandTests {
  @Test
  func aggregatePlanApplyAndTeardownOwnYabaiAndTheAuthoritativeSkhdPath() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let plan = try DesktopPlanCommandRunner(
      keybindings: fixture.keybindings,
      prerequisites: .assumed
    ).execute(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let planJSON = try fixture.json(plan.output)
    let keybindingPlan = try #require(planJSON["keybindings"] as? [String: Any])
    let actionIDs = try #require(planJSON["actions"] as? [[String: Any]])
      .compactMap { $0["id"] as? String }

    #expect(plan.succeeded)
    #expect(keybindingPlan["outcome"] as? String == "ready")
    #expect(actionIDs.last == "converge_skhd_provider")

    let first = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(first.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() != nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.state).status == .current
    )
    #expect(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.state)
      ).status == .managed
    )
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(fixture.theme.reconcileCount == 1)

    let repeated = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )
    let repeatedJSON = try fixture.json(repeated.output)

    #expect(repeated.succeeded)
    #expect(repeatedJSON["outcome"] as? String == "no_change")
    #expect(repeatedJSON["mutated"] as? Bool == false)
    #expect(fixture.theme.reconcileCount == 1)

    let status = try DesktopStatusCommandRunner(
      lifecycle: fixture.yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: fixture.sketchyBarCore,
      keybindings: fixture.keybindings,
      theme: fixture.theme.controller
    ).execute(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true,
      consumerPaths: testConsumerPaths()
    )
    #expect(status.succeeded)

    let teardown = try fixture.teardownRunner.executeAggregate(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )

    #expect(teardown.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.state).status == .current
    )
    #expect(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.state)
      ).status == .installRequired
    )
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func requiredThemeFailureRollsBackAllThreeProviderBoundaries() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: true, themeFailure: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let execution = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.state).status == .missing
    )
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(
      SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing
    )
    #expect(!fixture.sketchyBarLifecycle.isRunning)
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(try SketchyBarTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func laterProviderAdoptionBlocksBeforeYabaiOrSkhdMutation() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    let entry = configuration.appending(path: "sketchybarrc")
    try "external bar\n".write(to: entry, atomically: true, encoding: .utf8)

    let execution = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.state).status == .missing
    )
    #expect(try String(contentsOf: entry, encoding: .utf8) == "external bar\n")
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func missingCanonicalThemeBlocksBeforeProviderMutation() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.state.appending(path: "current"))

    let execution = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )
    let report = try fixture.json(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(KeybindingGenerationInspector().inspect(stateRoot: fixture.state).status == .missing)
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func failedManagedUpdateRestoresThePriorYabaiGenerationWithoutUnadopting() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )
    let previous = try #require(
      YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID
    )
    try """
    schema_version = 1
    [yabai]
    window_gap = 17
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    fixture.theme.shouldFail = true

    let update = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(!update.succeeded)
    #expect(
      YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID == previous
    )
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read()?.generationID == previous)
    #expect(
      YabaiProviderPlanInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        enabled: true
      ).status == .managed
    )
  }

  @Test
  func failedLaterUnifiedStageRestoresThePriorManagedDesktopBoundary() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: false)
    let setupFixture = try ApplyFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      setupFixture.cleanup()
    }
    _ = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )
    let previous = try #require(
      YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID
    )
    try """
    schema_version = 1
    [yabai]
    window_gap = 17
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let context = UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      keybindingsResourcesRoot: fixture.keybindingResources,
      desktopResourcesRoot: fixture.desktopResources,
      environmentResourcesRoot: repositoryRoot.appending(
        path: "Environment", directoryHint: .isDirectory
      ),
      profileURL: fixture.profile,
      profileRequired: true,
      machineProfileURL: fixture.state.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home
    )
    let planner = setupFixture.planner(plannedStages: [.desktop, .environment])
    let recovery = UnifiedSetupTeardownCommandRunner(
      planner: planner,
      environmentTeardown: { _, _, _ in
        Issue.record("Environment must not run")
        return try applyComponent("{}")
      },
      desktopTeardown: { _, _, dryRun in
        try SetupComponentExecution(
          fixture.teardownRunner.executeAggregate(
            stateRoot: fixture.state,
            homeDirectory: fixture.home,
            dryRun: dryRun,
            json: true
          )
        )
      },
      themeTeardown: { _, _, _, _ in .noChange("theme") },
      environmentApplyFinalization: { _, commit in
        #expect(!commit)
        return .noChange("environment")
      },
      desktopApplyFinalization: { _, commit in
        let changed = try fixture.applyRunner.finishDeferredAggregateApply(
          stateRoot: fixture.state,
          homeDirectory: fixture.home,
          commit: commit
        )
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: changed,
          outcome: changed ? "restored" : "no_change",
          message: "desktop",
          details: nil
        )
      }
    )
    let runner = setupFixture.runner(
      available: { _ in true },
      plannedStages: [.desktop, .environment],
      theme: { _, _ in
        Issue.record("The active theme must be preserved")
        return try applyComponent("{}")
      },
      desktop: { _, profile, paths, _ in
        try await SetupComponentExecution(
          fixture.applyRunner.executeAggregate(
            resourcesRoot: fixture.desktopResources,
            keybindingsResourcesRoot: fixture.keybindingResources,
            profileURL: fixture.profile,
            profileRequired: true,
            stateRoot: fixture.state,
            homeDirectory: fixture.home,
            consumerPaths: paths,
            adopt: nil,
            keybindingsAdopt: nil,
            json: true,
            deferFinalization: true,
            profile: profile
          )
        )
      },
      environment: { _, _, _, _, _ in
        try applyComponent(
          #"{"operation":"environment_apply","outcome":"failed","mutated":true,"message":"environment failed"}"#,
          succeeded: false
        )
      },
      transactionTeardown: recovery
    )

    let execution = try await runner.execute(
      context: context,
      consumerPaths: testConsumerPaths(),
      installDependencies: false,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(try jsonObject(execution.output)["outcome"] as? String == "rolled_back")
    #expect(YabaiGenerationInspector(stateRoot: fixture.state).inspect().generationID == previous)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read()?.generationID == previous)
    #expect(
      YabaiProviderPlanInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        enabled: true
      ).status == .managed
    )
  }

  @Test
  func deferredDesktopApplyCommitsOnlyWhenUnifiedSetupFinalizesIt() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let apply = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true,
      deferFinalization: true
    )

    #expect(apply.succeeded)
    #expect(
      try DesktopAggregateTransactionStore(stateRoot: fixture.state).read()?.phase == .mutating
    )
    #expect(
      try fixture.applyRunner.finishDeferredAggregateApply(
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        commit: true
      )
    )
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      YabaiProviderPlanInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        enabled: true
      ).status == .managed
    )
  }

  @Test
  func interruptedLaterProviderRecoversAllDeferredBoundariesBeforeRetry() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let interrupted = DesktopApplyCommandRunner(
      lifecycle: fixture.yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: fixture.sketchyBarCore,
      keybindings: fixture.keybindings,
      prerequisites: .assumed,
      theme: fixture.theme.controller,
      sketchyBarFaultInjector: { checkpoint in
        if checkpoint == .generationSelected {
          throw SketchyBarInterruptionError.injected
        }
      }
    )

    await #expect(throws: SketchyBarInterruptionError.self) {
      _ = try await interrupted.executeAggregate(
        resourcesRoot: fixture.desktopResources,
        keybindingsResourcesRoot: fixture.keybindingResources,
        profileURL: fixture.profile,
        profileRequired: true,
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        consumerPaths: testConsumerPaths(),
        adopt: nil,
        keybindingsAdopt: nil,
        json: true
      )
    }
    #expect(DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.state).read() != nil)
    #expect(try SketchyBarTransactionStore(stateRoot: fixture.state).read() != nil)

    let retry = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(retry.succeeded)
    #expect(!DesktopAggregateTransactionStore(stateRoot: fixture.state).exists)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.state).read() == nil)
    #expect(try SketchyBarTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func roleOptOutReleasesOnlyItsProviderBeforeTheRemainingDesktopRoles() async throws {
    let fixture = try DesktopAggregateFixture(topBarEnabled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let applied = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )
    #expect(applied.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() != nil)
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() != nil)
    #expect(fixture.yabaiLifecycle.isRunning)
    #expect(fixture.sketchyBarLifecycle.isRunning)
    let keybindingLifecycleChanges = fixture.keybindingLifecycle.calls.withLock {
      $0.filter { $0 == "restart" || $0 == "reload" }
    }
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let topBarDisabled = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(topBarDisabled.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() != nil)
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.state)
      ).status == .managed
    )
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
    #expect(fixture.yabaiLifecycle.isRunning)
    #expect(
      fixture.keybindingLifecycle.calls.withLock {
        $0.filter { $0 == "restart" || $0 == "reload" }
      } == keybindingLifecycleChanges
    )
    #expect(!fixture.sketchyBarLifecycle.isRunning)

    try """
    schema_version = 1
    [desktop]
    provider = "disabled"
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let allDisabled = try await fixture.applyRunner.executeAggregate(
      resourcesRoot: fixture.desktopResources,
      keybindingsResourcesRoot: fixture.keybindingResources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      adopt: nil,
      keybindingsAdopt: nil,
      json: true
    )

    #expect(allDisabled.succeeded)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(!fixture.yabaiLifecycle.isRunning)
    #expect(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.state,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.state)
      ).status == .installRequired
    )
    #expect(!fixture.sketchyBarLifecycle.isRunning)
  }

  @Test
  func doctorFailsSelectedMissingPrerequisitesButAllowsCleanRoleOptOut() throws {
    let selected = try DesktopAggregateFixture(topBarEnabled: false)
    defer { try? FileManager.default.removeItem(at: selected.root) }
    let missing = DesktopPrerequisiteInspector { _, _ in
      [
        DesktopPrerequisiteStatus(
          id: "yabai",
          status: .missing,
          requirement: "yabai must be executable",
          remediation: "Install yabai."
        )
      ]
    }
    let selectedDoctor = try DesktopDoctorCommandRunner(
      lifecycle: selected.yabaiLifecycle.controller,
      sketchyBarLifecycle: selected.sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: selected.sketchyBarCore,
      keybindings: selected.keybindings,
      prerequisites: missing,
      theme: nil
    ).execute(
      resourcesRoot: selected.desktopResources,
      keybindingsResourcesRoot: selected.keybindingResources,
      profileURL: selected.profile,
      profileRequired: true,
      stateRoot: selected.state,
      homeDirectory: selected.home,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let selectedJSON = try selected.json(selectedDoctor.output)
    let selectedFindings = try #require(selectedJSON["findings"] as? [[String: Any]])

    #expect(!selectedDoctor.succeeded)
    #expect(
      selectedFindings.contains {
        $0["id"] as? String == "desktop.prerequisite.yabai"
          && $0["status"] as? String == "failure"
      }
    )

    let disabled = try DesktopAggregateFixture(
      profileText: """
        schema_version = 1
        [desktop]
        provider = "disabled"
        [top_bar]
        provider = "disabled"
        """
    )
    defer { try? FileManager.default.removeItem(at: disabled.root) }
    let disabledDoctor = try DesktopDoctorCommandRunner(
      lifecycle: disabled.yabaiLifecycle.controller,
      sketchyBarLifecycle: disabled.sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: disabled.sketchyBarCore,
      keybindings: nil,
      prerequisites: .assumed,
      theme: nil
    ).execute(
      resourcesRoot: disabled.desktopResources,
      keybindingsResourcesRoot: disabled.keybindingResources,
      profileURL: disabled.profile,
      profileRequired: true,
      stateRoot: disabled.state,
      homeDirectory: disabled.home,
      consumerPaths: testConsumerPaths(),
      json: true
    )

    #expect(disabledDoctor.succeeded)
  }
}

private struct DesktopAggregateFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let desktopResources: URL
  let keybindingResources: URL
  let yabaiLifecycle = AggregateYabaiLifecycle()
  let sketchyBarLifecycle = AggregateSketchyBarLifecycle()
  let keybindingLifecycle = LifecycleFixture()
  let theme: AggregateThemeController
  let keybindings: DesktopKeybindingOrchestrator
  let sketchyBarCore: SketchyBarCoreRuntimeController

  init(
    topBarEnabled: Bool,
    themeFailure: Bool = false
  ) throws {
    try self.init(
      profileText:
        topBarEnabled
        ? "schema_version = 1\n"
        : "schema_version = 1\n[top_bar]\nprovider = \"disabled\"\n",
      themeFailure: themeFailure
    )
  }

  init(
    profileText: String,
    themeFailure: Bool = false
  ) throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-desktop-aggregate-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = state.appending(path: "profile.toml")
    desktopResources = repositoryRoot.appending(path: "Desktop", directoryHint: .isDirectory)
    keybindingResources = repositoryRoot.appending(
      path: "Keybindings",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config/skhd", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try profileText.write(to: profile, atomically: true, encoding: .utf8)
    let keybindingRunner = KeybindingsApplyCommandRunner(lifecycle: keybindingLifecycle.controller)
    keybindings = DesktopKeybindingOrchestrator(
      runner: keybindingRunner,
      planner: keybindingRunner.planner
    )
    theme = AggregateThemeController(shouldFail: themeFailure)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    let generation = try ThemeActivator(root: state).activate(package: package)
    let core = SketchyBarCoreRuntimeInspection(
      status: .converged,
      message: "converged",
      themeGenerationID: generation.generationID,
      barColor: "0xf01e1e2e",
      items: ["macarchy.clock", "macarchy.space.1", "macarchy.theme.ready"],
      spaceIndices: [1],
      clockLabelPresent: true
    )
    sketchyBarCore = SketchyBarCoreRuntimeController(
      inspect: { _ in core },
      settle: { _ in core },
      settleRestored: { $0.agreesWithProviderRuntime(core) }
    )
  }

  var applyRunner: DesktopApplyCommandRunner {
    DesktopApplyCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: sketchyBarCore,
      keybindings: keybindings,
      prerequisites: .assumed,
      theme: theme.controller
    )
  }

  var teardownRunner: DesktopTeardownCommandRunner {
    DesktopTeardownCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: sketchyBarLifecycle.controller,
      sketchyBarCoreRuntime: sketchyBarCore,
      keybindings: keybindings
    )
  }

  func json(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }
}

private final class AggregateYabaiLifecycle: Sendable {
  private let running = Mutex(false)

  var isRunning: Bool { running.withLock { $0 } }

  var controller: YabaiLifecycleController {
    YabaiLifecycleController(
      preflight: { self.running.withLock { $0 } },
      restart: { self.running.withLock { $0 = true } },
      stop: { self.running.withLock { $0 = false } },
      inspect: { composition in
        YabaiRuntimeInspection(
          status: .converged,
          message: "converged",
          verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: true,
          processID: 42,
          executablePath: "/opt/homebrew/bin/yabai"
        )
      },
      waitBetweenInspections: {}
    )
  }
}

private final class AggregateSketchyBarLifecycle: Sendable {
  private let running = Mutex(false)

  var isRunning: Bool { running.withLock { $0 } }

  var controller: SketchyBarLifecycleController {
    SketchyBarLifecycleController(
      inspect: { self.running.withLock { $0 } ? Self.runtime : .stopped },
      preflight: { self.running.withLock { $0 } },
      reload: { _ in Self.runtime },
      start: {
        self.running.withLock { $0 = true }
        return Self.runtime
      },
      stop: { self.running.withLock { $0 = false } }
    )
  }

  private static let runtime = SketchyBarRuntimeInspection(
    status: .running,
    message: "running",
    processID: 42,
    executablePath: "/opt/homebrew/Cellar/sketchybar/2.23.0/bin/sketchybar",
    serviceLabel: SketchyBarHomebrewService.serviceLabel
  )
}

private final class AggregateThemeController: Sendable {
  private let state: Mutex<(shouldFail: Bool, reconcileCount: Int)>

  init(shouldFail: Bool) {
    state = Mutex((shouldFail, 0))
  }

  var shouldFail: Bool {
    get { state.withLock { $0.shouldFail } }
    set { state.withLock { $0.shouldFail = newValue } }
  }

  var reconcileCount: Int { state.withLock { $0.reconcileCount } }

  var controller: DesktopThemeController {
    DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        let failed = self.state.withLock { state in
          state.reconcileCount += 1
          return state.shouldFail
        }
        return DesktopThemeReconciliation(
          generationID: "g-00000000-0000-0000-0000-000000000000",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: failed ? "failed" : "applied",
              message: failed ? "injected theme failure" : "applied"
            )
          },
          succeeded: !failed
        )
      },
      inspect: { adapterIDs, _, _ in
        adapterIDs.map {
          DesktopThemeAdapterStatus(
            adapterID: $0,
            requirement: "required",
            status: "ready",
            message: "ready"
          )
        }
      }
    )
  }
}
