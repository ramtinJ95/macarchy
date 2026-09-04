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
    try fixture.writeMachineProfile("schema_version = 1\n[kitty]\nfont_size = 15\n")
    let calls = Mutex([String]())
    let runner = fixture.runner(
      available: { _ in true },
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
      desktop: { _, profile, _ in
        #expect(profile.environment.kitty.fontSize == 15)
        calls.withLock { $0.append("desktop") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"applied","mutated":true,"message":"desktop changed"}"#
        )
      },
      environment: { _, profile, _ in
        #expect(profile.environment.kitty.fontSize == 15)
        calls.withLock { $0.append("environment") }
        return try applyComponent(
          #"{"operation":"environment_apply","outcome":"applied","mutated":true,"message":"environment changed"}"#
        )
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      installDependencies: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "applied")
    #expect(report["mutated"] as? Bool == true)
    #expect(calls.withLock { $0 } == ["plan", "theme", "desktop", "environment"])
  }

  @Test
  func missingHomebrewDependencyBlocksBeforeMutationWithoutApprovalFlag() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    let runner = fixture.runner(
      available: { $0.id != "bat" },
      process: ProcessRunner { _ in
        calls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      writePlan: { _ in calls.withLock { $0 += 1 } },
      theme: { _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      desktop: { _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      },
      environment: { _, _, _ in
        calls.withLock { $0 += 1 }
        return try applyComponent("{}")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      installDependencies: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect((report["message"] as? String)?.contains("--install-dependencies") == true)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test
  func approvedHomebrewInstallIsScopedAndVerifiedBeforeProviderMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let batAvailable = Mutex(false)
    let calls = Mutex([String]())
    let available: @Sendable (DependencyCapability) -> Bool = { capability in
      capability.id != "bat" || batAvailable.withLock { $0 }
    }
    let runner = fixture.runner(
      available: available,
      process: ProcessRunner { request in
        #expect(request.arguments == ["install", "--formula", "--no-ask", "bat"])
        #expect(request.environmentOverrides == HomebrewInstallPlan.environment)
        batAvailable.withLock { $0 = true }
        calls.withLock { $0.append("packages") }
        return ProcessResult(terminationStatus: 0, output: "installed bat")
      },
      writePlan: { _ in calls.withLock { $0.append("plan") } },
      theme: { _, _ in
        calls.withLock { $0.append("theme") }
        return try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _ in
        calls.withLock { $0.append("desktop") }
        return try applyComponent(
          #"{"operation":"desktop_apply","outcome":"no_change","mutated":false,"message":"desktop ready"}"#
        )
      },
      environment: { _, _, _ in
        calls.withLock { $0.append("environment") }
        return try applyComponent(
          #"{"operation":"environment_apply","outcome":"no_change","mutated":false,"message":"environment ready"}"#
        )
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      installDependencies: true,
      json: true
    )
    let report = try jsonObject(execution.output)
    let packages = try #require(report["packages"] as? [String: Any])

    #expect(execution.succeeded)
    #expect(packages["outcome"] as? String == "installed")
    #expect(calls.withLock { $0 } == ["plan", "packages", "theme", "desktop", "environment"])
  }

  @Test
  func failedDesktopStopsEnvironmentAndReportsEarlierMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let environmentCalls = Mutex(0)
    let runner = fixture.runner(
      available: { _ in true },
      theme: { _, _ in
        try applyComponent(
          #"{"operation":"theme_set","outcome":"success","committed":true}"#
        )
      },
      desktop: { _, _, _ in
        try applyComponent(
          #"{"operation":"desktop_apply","outcome":"failed","mutated":true,"message":"desktop failed"}"#,
          succeeded: false
        )
      },
      environment: { _, _, _ in
        environmentCalls.withLock { $0 += 1 }
        return try applyComponent("{}")
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      installDependencies: false,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "failed")
    #expect(report["mutated"] as? Bool == true)
    #expect(report["environment"] == nil)
    #expect(environmentCalls.withLock { $0 } == 0)
  }

  @Test
  func repeatedApplyPreservesTheSetupThemeAndReportsNoChange() async throws {
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
    let runner = fixture.runner(
      available: { _ in true },
      theme: { _, _ in
        Issue.record("A repeated apply must preserve the active canonical theme")
        return try applyComponent("{}")
      },
      desktop: { _, _, _ in
        try applyComponent(
          #"{"operation":"desktop_apply","outcome":"no_change","mutated":false,"message":"desktop ready"}"#
        )
      },
      environment: { _, _, _ in
        try applyComponent(
          #"{"operation":"environment_apply","outcome":"no_change","mutated":false,"message":"environment ready"}"#
        )
      }
    )

    let execution = try await runner.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(),
      installDependencies: false,
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

  func runner(
    available: @escaping @Sendable (DependencyCapability) -> Bool,
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
    process: ProcessRunner = ProcessRunner { _ in
      Issue.record("Homebrew must not run")
      return ProcessResult(terminationStatus: 1, output: "unexpected")
    },
    writePlan: @escaping @Sendable (String) throws -> Void = { _ in },
    theme: @escaping UnifiedSetupApplyCommandRunner.ThemeApply,
    desktop: @escaping UnifiedSetupApplyCommandRunner.ComponentApply,
    environment: @escaping UnifiedSetupApplyCommandRunner.ComponentApply
  ) -> UnifiedSetupApplyCommandRunner {
    UnifiedSetupApplyCommandRunner(
      planner: planner(available: available),
      themeInspection: themeInspection,
      processRunner: process,
      capabilityIsAvailable: available,
      writePreMutationPlan: writePlan,
      themeApply: theme,
      desktopApply: desktop,
      environmentApply: environment
    )
  }

  func planner(
    available: @escaping @Sendable (DependencyCapability) -> Bool = { _ in true }
  ) -> UnifiedSetupPlanCommandRunner {
    UnifiedSetupPlanCommandRunner(
      capabilityIsAvailable: available,
      desktopPlanner: { context, _ in
        try planComponent(
          """
          {
            "outcome":"ready",
            "keybindings":{
              "outcome":"ready",
              "provider_status":"install_required",
              "ownership":"absent",
              "adoption_evidence_digest":null
            },
            "provider":{
              "entry_point":"\(context.homeDirectory.path)/.config/yabai/yabairc",
              "status":"install_required",
              "ownership":"absent",
              "adoption_evidence_digest":null
            },
            "sketchybar":{
              "provider":{
                "entry_point":"\(context.homeDirectory.path)/.config/sketchybar/sketchybarrc",
                "status":"install_required",
                "ownership":"absent",
                "adoption_evidence_digest":null
              }
            },
            "actions":[]
          }
          """
        )
      },
      environmentPlanner: { _, _ in
        try planComponent(
          #"{"outcome":"ready","adoption_evidence_digest":null,"entries":[],"actions":[]}"#
        )
      }
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
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
