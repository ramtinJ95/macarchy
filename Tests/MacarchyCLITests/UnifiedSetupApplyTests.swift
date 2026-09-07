import ArgumentParser
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct UnifiedSetupApplyTests {
  @Test
  func cleanApplyUsesOneLayeredModelAndRunsStagesInOrder() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try fixture.writeMachineProfile(
      """
      schema_version = 1
      [kitty]
      font_size = 15
      [top_bar]
      provider = "disabled"
      [history]
      provider = "disabled"
      """
    )
    let calls = Mutex([String]())
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(plannedStages: [.desktop, .environment]),
      environmentTeardown: { _, _, _ in
        Issue.record("Commit must not invoke environment teardown")
        return try applyComponent("{}")
      },
      desktopTeardown: { _, _, _ in
        Issue.record("Commit must not invoke desktop teardown")
        return try applyComponent("{}")
      },
      themeTeardown: { _, _, _, _ in
        Issue.record("Commit must not invoke theme teardown")
        return .noChange("unexpected")
      },
      environmentApplyFinalization: { _, commit in
        #expect(commit)
        calls.withLock { $0.append("environment:commit") }
        return .noChange("environment")
      },
      desktopApplyFinalization: { _, commit in
        #expect(commit)
        calls.withLock { $0.append("desktop:commit") }
        return .noChange("desktop")
      }
    )
    let runner = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop, .environment],
      writePlan: { output in
        #expect(output.contains(#""operation" : "setup_plan""#))
        calls.withLock { $0.append("plan") }
      },
      theme: { package, _ in
        #expect(package.id == "catppuccin-mocha")
        calls.withLock { $0.append("theme") }
        return try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, profile, _, _, enabledThemeAdapterIDs in
        #expect(profile.environment.kitty.fontSize == 15)
        #expect(profile.topBar == .disabled)
        #expect(enabledThemeAdapterIDs.contains("wallpaper"))
        #expect(!enabledThemeAdapterIDs.contains("sketchybar"))
        calls.withLock { $0.append("desktop") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"applied","mutated":true,"message":"desktop changed"}"#
        )
      },
      environment: { _, profile, _, _, enabledThemeAdapterIDs in
        #expect(profile.environment.kitty.fontSize == 15)
        #expect(profile.environment.history == .disabled)
        #expect(
          enabledThemeAdapterIDs
            == [
              "bat", "borders", "btop", "eza", "kitty", "macos-appearance", "neovim", "starship",
              "wallpaper", "yazi",
            ]
        )
        calls.withLock { $0.append("environment") }
        return try applyComponent(
          #"{"operation":"environment_apply","outcome":"applied","mutated":true,"message":"environment changed"}"#
        )
      },
      transactionTeardown: teardown
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "applied")
    #expect(report["mutated"] as? Bool == true)
    #expect(
      calls.withLock { $0 }
        == ["plan", "theme", "desktop", "environment", "environment:commit", "desktop:commit"]
    )
  }

  @Test
  func exactAdoptionApprovalsReachTheExistingComponentOwners() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let approvals = UnifiedSetupAdoptionApprovals(
      yabai: "yabai-digest",
      keybindings: "keybindings-digest",
      sketchybar: "sketchybar-digest",
      environment: "environment-digest"
    )
    let calls = Mutex([String]())
    let runner = fixture.runner(
      available: { _ in true },
      requiredAdoptions: approvals,
      plannedStages: [.desktop, .environment],
      writePlan: { _ in calls.withLock { $0.append("plan") } },
      theme: { _, _ in
        calls.withLock { $0.append("theme") }
        return try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _, received, _ in
        #expect(received == approvals)
        calls.withLock { $0.append("desktop") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"no_change","mutated":false,"message":"desktop ready"}"#
        )
      },
      environment: { _, _, _, received, _ in
        #expect(received == approvals)
        calls.withLock { $0.append("environment") }
        return try applyComponent(
          #"{"operation":"environment_apply","outcome":"no_change","mutated":false,"message":"environment ready"}"#
        )
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      adoptions: approvals,
      json: true
    )

    #expect(execution.succeeded)
    #expect(calls.withLock { $0 } == ["plan", "theme", "desktop", "environment"])
  }

  @Test
  func incompleteStaleOrExtraneousAdoptionBlocksBeforeMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let required = UnifiedSetupAdoptionApprovals(yabai: "current-digest")
    let calls = Mutex(0)
    let runner = fixture.runner(
      available: { _ in true },
      requiredAdoptions: required,
      writePlan: { _ in calls.withLock { $0 += 1 } },
      theme: { _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      }
    )
    let invalid = [
      UnifiedSetupAdoptionApprovals.none,
      UnifiedSetupAdoptionApprovals(yabai: "stale-digest"),
      UnifiedSetupAdoptionApprovals(
        yabai: "current-digest",
        environment: "not-required"
      ),
    ]

    for adoptions in invalid {
      let execution = try await runner.execute(
        context: fixture.context,
        consumerPaths: testConsumerPaths(),
        adoptions: adoptions,
        json: true
      )
      let report = try jsonObject(execution.output)

      #expect(!execution.succeeded)
      #expect(report["outcome"] as? String == "blocked")
      #expect(report["mutated"] as? Bool == false)
    }
    #expect(calls.withLock { $0 } == 0)
  }

  @Test
  func adoptionFileIsStrictAndCannotBeCombinedWithNamedOptions() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let file = fixture.root.appending(path: "adoption.json")
    try #"{"schema_version":1,"yabai":"y","keybindings":"k","sketchybar":"s","environment":"e"}"#
      .write(to: file, atomically: true, encoding: .utf8)
    let expected = UnifiedSetupAdoptionApprovals(
      yabai: "y",
      keybindings: "k",
      sketchybar: "s",
      environment: "e"
    )
    let options = try Macarchy.Setup.AdoptionOptions.parse([
      "--adoption-file", file.path,
    ])

    #expect(try options.resolve() == expected)
    let named = try Macarchy.Setup.AdoptionOptions.parse([
      "--yabai-adopt", "y",
      "--keybindings-adopt", "k",
      "--sketchybar-adopt", "s",
      "--environment-adopt", "e",
    ])
    #expect(try named.resolve() == expected)
    let mixed = try Macarchy.Setup.AdoptionOptions.parse([
      "--adoption-file", file.path,
      "--yabai-adopt", "y",
    ])
    #expect(throws: ValidationError.self) { try mixed.resolve() }

    try #"{"schema_version":1,"unexpected":"value"}"#
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: UnifiedSetupAdoptionError.self) {
      try UnifiedSetupAdoptionFile.load(at: file)
    }

    try #"{"schema_version":1,"yabai":"reviewed","yabai":"different"}"#
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: UnifiedSetupAdoptionError.self) {
      try UnifiedSetupAdoptionFile.load(at: file)
    }
  }

  @Test
  func missingHomebrewPackagesRequireExactApproval() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let runner = fixture.runner(
      available: { $0.id != "bat" },
      installer: .init(apply: { _, _ in
        calls.withLock { $0 += 1 }
        return .init(status: 0, diagnostic: "")
      }),
      writePlan: { _ in calls.withLock { $0 += 1 } },
      theme: { _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect((report["message"] as? String)?.contains("--approve-packages") == true)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test(arguments: [Int32(0), Int32(1)])
  func fullPackageApplyUsesReviewedMissingScopeAndDoesNotAdopt(status: Int32) async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let inventory = try InventoryFixture()
    defer { inventory.cleanup() }
    try inventory.formula("orphan", tap: "homebrew/core")
    try fixture.writeMachineProfile("schema_version = 1\n[packages]\nexclude_formulae = ['jq']\n")
    let profile = try Data(contentsOf: fixture.context.machineProfileURL)
    let installed = Mutex(false)
    let calls = Mutex([String]())
    let packages = try SetupBrewfile.parse(
      "brew 'bat'\nbrew 'orphan'\nbrew 'jq'\ncask 'vendor/apps/slack'\ntap 'unrelated/tap'\n")
    let runner = fixture.runner(
      available: { $0.id != "bat" || installed.withLock { $0 } },
      plannedStages: [.desktop, .environment],
      packages: packages,
      inventory: {
        inventory.reader(
          formulae: installed.withLock { $0 } ? "bat\norphan" : "orphan",
          casks: installed.withLock { $0 } ? "slack" : ""
        ).read()
      },
      installer: .init(apply: { url, _ in
        #expect(
          try String(contentsOf: url, encoding: .utf8)
            == "tap \"vendor/apps\"\ncask \"vendor/apps/slack\"\nbrew \"bat\"\n")
        try inventory.formula("bat", tap: "homebrew/core")
        try inventory.cask("slack", tap: "vendor/apps")
        installed.withLock { $0 = true }
        calls.withLock { $0.append("packages") }
        return .init(status: status, diagnostic: "native result")
      }),
      writePlan: { _ in calls.withLock { $0.append("plan") } },
      theme: { _, _ in
        calls.withLock { $0.append("theme") }
        return try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#)
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0.append("desktop") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"no_change","mutated":false,"message":"ready"}"#)
      },
      environment: { _, _, _, _, _ in
        calls.withLock { $0.append("environment") }
        return try applyComponent(
          #"{"operation":"environment_apply","outcome":"no_change","mutated":false,"message":"ready"}"#
        )
      })
    let preview = try runner.planner.prepare(context: fixture.context).report
    let approval = try #require(preview.packageInstallation?.approvalDigest)
    let rejected = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), packageApproval: "wrong",
      json: true)
    #expect(!rejected.succeeded && calls.withLock { $0.isEmpty })
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), packageApproval: approval,
      json: true)
    #expect(result.succeeded == (status == 0))
    #expect(
      calls.withLock { $0 }
        == (status == 0
          ? ["plan", "packages", "theme", "desktop", "environment"] : ["plan", "packages"]))
    #expect(try Data(contentsOf: fixture.context.machineProfileURL) == profile)
    #expect(
      try SetupPackageAdoptionStore(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).read() == nil)
    #expect(try SetupPackageInstallationStore(context: fixture.context).read() == nil)
    // Even a failed native command may leave installed receipts. A fresh run
    // uses that observed state, without ownership publication or native replay.
    let retry = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(), json: true)
    #expect(retry.succeeded)
    let report = try jsonObject(retry.output)
    #expect((report["packages"] as? [String: Any])?["outcome"] as? String == "no_change")
    #expect(calls.withLock { $0.filter { $0 == "packages" }.count } == 1)
  }

  @Test
  func failedDesktopRollsBackStartedStagesAndStopsEnvironment() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let environmentCalls = Mutex(0)
    let calls = Mutex([String]())
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(plannedStages: [.desktop]),
      environmentTeardown: { _, _, _ in
        Issue.record("Environment teardown must not run when apply stopped at desktop")
        return try teardownComponent(dryRun: true, mutated: false)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "rollback")") }
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
      },
      themeTeardown: { _, _, _, dryRun in
        calls.withLock { $0.append("theme:\(dryRun ? "preview" : "rollback")") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: !dryRun,
          outcome: dryRun ? "planned" : "restored",
          message: "theme",
          details: nil
        )
      },
      environmentApplyFinalization: { _, _ in
        Issue.record("Environment was not part of the failed apply")
        return .noChange("unexpected")
      },
      desktopApplyFinalization: { _, commit in
        #expect(!commit)
        calls.withLock { $0.append("desktop:rollback") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: true,
          outcome: "restored",
          message: "desktop",
          details: nil
        )
      }
    )
    let runner = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop],
      theme: { _, _ in
        try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _, _, _ in
        try applyComponent(
          #"{"operation":"desktop_apply","outcome":"failed","mutated":true,"message":"desktop failed"}"#,
          succeeded: false
        )
      },
      environment: { _, _, _, _, _ in
        environmentCalls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      transactionTeardown: teardown
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "rolled_back")
    #expect(report["mutated"] as? Bool == true)
    #expect(report["environment"] == nil)
    #expect(environmentCalls.withLock { $0 } == 0)
    #expect(
      calls.withLock { $0 } == ["desktop:rollback", "theme:rollback"]
    )
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func failedEnvironmentRollsBackEveryStartedStageInReverseOrder() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex([String]())
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(plannedStages: [.desktop, .environment]),
      environmentTeardown: { _, _, dryRun in
        calls.withLock { $0.append("environment:\(dryRun ? "preview" : "rollback")") }
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "rollback")") }
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
      },
      themeTeardown: { _, _, _, dryRun in
        calls.withLock { $0.append("theme:\(dryRun ? "preview" : "rollback")") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: !dryRun,
          outcome: dryRun ? "planned" : "restored",
          message: "theme",
          details: nil
        )
      },
      environmentApplyFinalization: { _, commit in
        #expect(!commit)
        calls.withLock { $0.append("environment:rollback") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: true,
          outcome: "restored",
          message: "environment",
          details: nil
        )
      },
      desktopApplyFinalization: { _, commit in
        #expect(!commit)
        calls.withLock { $0.append("desktop:rollback") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: true,
          outcome: "restored",
          message: "desktop",
          details: nil
        )
      }
    )
    let runner = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop, .environment],
      theme: { _, _ in
        try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _, _, _ in
        try applyComponent(
          #"{"operation":"desktop_apply","outcome":"applied","mutated":true}"#
        )
      },
      environment: { _, _, _, _, _ in
        try applyComponent(
          #"{"operation":"environment_apply","outcome":"failed","mutated":true,"message":"environment failed"}"#,
          succeeded: false
        )
      },
      transactionTeardown: teardown
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "rolled_back")
    #expect(
      calls.withLock { $0 }
        == [
          "environment:rollback", "desktop:rollback", "theme:rollback",
        ]
    )
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func interruptedApplyRollsBackBeforeAReplacementApplyCanStart() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let paths = testConsumerPaths()
    let calls = Mutex([String]())
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(plannedStages: [.desktop]),
      environmentTeardown: { _, _, _ in
        Issue.record("Environment was not part of the interrupted transaction")
        return try teardownComponent(dryRun: true, mutated: false)
      },
      desktopTeardown: { _, _, dryRun in
        calls.withLock { $0.append("desktop:\(dryRun ? "preview" : "rollback")") }
        return try teardownComponent(dryRun: dryRun, mutated: !dryRun)
      },
      themeTeardown: { _, _, _, dryRun in
        calls.withLock { $0.append("theme:\(dryRun ? "preview" : "rollback")") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: !dryRun,
          outcome: dryRun ? "planned" : "restored",
          message: "theme",
          details: nil
        )
      },
      environmentApplyFinalization: { _, _ in
        Issue.record("Environment was not part of the interrupted apply")
        return .noChange("unexpected")
      },
      desktopApplyFinalization: { _, commit in
        #expect(!commit)
        calls.withLock { $0.append("desktop:rollback") }
        return UnifiedSetupTeardownStage(
          succeeded: true,
          mutated: true,
          outcome: "restored",
          message: "desktop",
          details: nil
        )
      }
    )
    let interrupted = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop],
      theme: { _, _ in
        calls.withLock { $0.append("theme:apply") }
        return try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0.append("desktop:apply") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"applied","mutated":true}"#
        )
      },
      environment: { _, _, _, _, _ in
        Issue.record("Environment must not run before the injected interruption")
        return try applyComponent("{}")
      },
      transactionTeardown: teardown,
      faultInjector: { checkpoint in
        if case .desktopApplied = checkpoint { throw UnifiedSetupInterruptionError.injected }
      }
    )

    await #expect(throws: UnifiedSetupInterruptionError.self) {
      try await interrupted.execute(
        context: fixture.context,
        consumerPaths: paths,
        json: true
      )
    }
    #expect(
      try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.stages
        == [.theme, .desktop]
    )

    let replacement = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop],
      theme: { _, _ in
        Issue.record("Recovery must finish before a replacement apply starts")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        Issue.record("Recovery must finish before a replacement apply starts")
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        Issue.record("Recovery must finish before a replacement apply starts")
        return try applyComponent("{}")
      },
      transactionTeardown: teardown
    )
    let execution = try await replacement.execute(
      context: fixture.context,
      consumerPaths: paths,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "rolled_back")
    #expect(
      calls.withLock { $0 }
        == [
          "theme:apply", "desktop:apply", "desktop:rollback", "theme:rollback",
        ]
    )
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func planChangesWhileWaitingForTheSetupLockBlockBeforeMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let runner = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop, .environment],
      writePlan: { _ in
        try fixture.writeMachineProfile(
          "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n"
        )
      },
      theme: { _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(calls.withLock { $0 } == 0)
    #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func repeatedApplyPreservesTheSetupThemeAndReportsNoChange() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let runner = fixture.runner(
      available: { _ in true },
      theme: { _, _ in
        Issue.record("A repeated apply must preserve the active canonical theme")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        Issue.record("A no-change plan must not invoke desktop mutation")
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        Issue.record("A no-change plan must not invoke environment mutation")
        return try applyComponent("{}")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "no_change")
    #expect(report["mutated"] as? Bool == false)
    #expect(
      try ReconciliationStatusStore(root: fixture.state).activeManifest().generationID
        == manifest.generationID
    )
  }
}

final class ApplyFixture: @unchecked Sendable {
  let root: URL
  let home: URL
  let state: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-unified-setup-apply-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  }

  var context: UnifiedSetupPlanContext {
    UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory),
      keybindingsResourcesRoot: root.appending(path: "Keybindings"),
      desktopResourcesRoot: root.appending(path: "Desktop"),
      environmentResourcesRoot: root.appending(path: "Environment"),
      profileURL: state.appending(path: "profile.toml"),
      profileRequired: false,
      machineProfileURL: state.appending(path: "machine.toml"),
      machineProfileRequired: false,
      stateRoot: state,
      homeDirectory: home
    )
  }

  func writeMachineProfile(_ text: String) throws {
    try text.write(
      to: state.appending(path: "machine.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func activateSetupOwnedTheme() throws -> GenerationManifest {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    let manifest = try ThemeActivator(root: state).activate(package: package)
    try SetupCoreOwnershipStore(stateRoot: state).write(
      SetupCoreOwnership(themeGenerationID: manifest.generationID, originalAppearance: .light)
    )
    return manifest
  }

  func runner(
    available: @escaping @Sendable (DependencyCapability) -> Bool,
    requiredAdoptions: UnifiedSetupAdoptionApprovals = .none,
    plannedStages: Set<UnifiedSetupTransactionStage> = [],
    themeInspection: @escaping UnifiedSetupThemeInspection = {
      model, ownership, _ in
      let active = model.theme.currentGenerationID
      let succeeded = ownership.map { $0.themeGenerationID == active } ?? true
      return UnifiedSetupThemeLifecycleStatus(
        succeeded: succeeded,
        status: active == nil ? "absent" : ownership == nil ? "external" : "managed",
        generationID: active,
        message: succeeded ? "current" : "drifted"
      )
    },
    packages: SetupBrewfile = SetupBrewfile(packages: []),
    inventory: @escaping @Sendable () -> HomebrewPackageObservation = {
      .init(packages: [], issues: [])
    },
    installer: HomebrewBundleInstaller = .init(apply: { _, _ in
      Issue.record("Homebrew must not run")
      return .init(status: 1, diagnostic: "unexpected")
    }),
    writePlan: @escaping @Sendable (String) throws -> Void = { _ in },
    theme: @escaping UnifiedSetupApplyCommandRunner.ThemeApply,
    desktop: @escaping UnifiedSetupApplyCommandRunner.ComponentApply,
    environment: @escaping UnifiedSetupApplyCommandRunner.ComponentApply,
    transactionTeardown: UnifiedSetupTeardownCommandRunner? = nil,
    faultInjector: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) -> UnifiedSetupApplyCommandRunner {
    var planner = planner(
      available: available,
      requiredAdoptions: requiredAdoptions,
      plannedStages: plannedStages
    )
    planner.standardBrewfile = { _ in packages }
    planner.packageInventoryReader = inventory
    return UnifiedSetupApplyCommandRunner(
      planner: planner,
      themeInspection: themeInspection,
      packageInstaller: installer,
      capabilityIsAvailable: available,
      writePreMutationPlan: writePlan,
      themeApply: theme,
      desktopApply: desktop,
      environmentApply: environment,
      transactionTeardown: transactionTeardown
        ?? UnifiedSetupTeardownCommandRunner(
          planner: planner,
          environmentTeardown: { _, _, _ in
            try applyComponent(
              #"{"outcome":"no_change","mutated":false,"message":"environment"}"#
            )
          },
          desktopTeardown: { _, _, _ in
            try applyComponent(
              #"{"outcome":"no_change","mutated":false,"message":"desktop"}"#
            )
          },
          themeTeardown: { _, _, _, _ in .noChange("theme") }
        ),
      faultInjector: faultInjector
    )
  }

  func planner(
    available: @escaping @Sendable (DependencyCapability) -> Bool = { _ in true },
    requiredAdoptions: UnifiedSetupAdoptionApprovals = .none,
    plannedStages: Set<UnifiedSetupTransactionStage> = []
  ) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: available,
      desktopPlanner: { context, _ in
        let keybindingsStatus =
          requiredAdoptions.keybindings == nil ? "install_required" : "adoption_required"
        let yabaiStatus =
          requiredAdoptions.yabai == nil ? "install_required" : "adoption_required"
        let sketchybarStatus =
          requiredAdoptions.sketchybar == nil ? "install_required" : "adoption_required"
        return try planComponent(
          """
          {
            "outcome":"ready",
            "keybindings":{
              "outcome":"ready",
              "provider_status":"\(keybindingsStatus)",
              "ownership":"absent",
              "adoption_evidence_digest":\(jsonString(requiredAdoptions.keybindings))
            },
            "provider":{
              "entry_point":"\(context.homeDirectory.path)/.config/yabai/yabairc",
              "status":"\(yabaiStatus)",
              "ownership":"absent",
              "adoption_evidence_digest":\(jsonString(requiredAdoptions.yabai))
            },
            "sketchybar":{
              "provider":{
                "entry_point":"\(context.homeDirectory.path)/.config/sketchybar/sketchybarrc",
                "status":"\(sketchybarStatus)",
                "ownership":"absent",
                "adoption_evidence_digest":\(jsonString(requiredAdoptions.sketchybar))
              }
            },
            "actions":\(actionsJSON(plannedStages.contains(.desktop), id: "desktop"))
          }
          """
        )
      },
      environmentPlanner: { _, _ in
        try planComponent(
          """
          {"outcome":"ready","adoption_evidence_digest":\(jsonString(requiredAdoptions.environment)),"entries":[],"actions":\(actionsJSON(plannedStages.contains(.environment), id: "environment"))}
          """
        )
      },
      packageInventoryReader: { HomebrewPackageObservation(packages: [], issues: []) },
      standardBrewfile: { _ in
        try SetupBrewfile.read(at: repositoryRoot.appending(path: "Environment/Brewfile"))
      }
    )
  }

  func cleanup(expectedThemeGenerationID: String? = nil) {
    if let expectedThemeGenerationID {
      _ = try? ThemeActivator(root: state).deactivate(
        expectedGenerationID: expectedThemeGenerationID,
        dryRun: false
      )
    }
    try? FileManager.default.removeItem(at: root)
  }
}

private func jsonString(_ value: String?) -> String {
  value.map { "\"\($0)\"" } ?? "null"
}

private func actionsJSON(_ planned: Bool, id: String) -> String {
  planned ? #"[{"id":"\#(id)","message":"planned"}]"# : "[]"
}

func planComponent(_ json: String) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: true))
}

func applyComponent(
  _ json: String,
  succeeded: Bool = true
) throws -> SetupComponentExecution {
  try SetupComponentExecution((output: json, succeeded: succeeded))
}
