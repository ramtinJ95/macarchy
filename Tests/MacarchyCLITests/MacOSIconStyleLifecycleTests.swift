import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MacOSIconStyleLifecycleTests {
  @Test func profileOptionIsReviewedAndBecomesAppliedRuntimeAuthority() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (original + "\n[macos_look]\nicon_style = true\n").write(
      to: fixture.profile, atomically: false, encoding: .utf8)
    #expect(try fixture.plan().output.contains("configure_macos_icon_style"))
    #expect(try await fixture.apply(adopt: nil).succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(
      ThemeRuntimeSelection.appliedAdapterIDs(for: ownership).contains(MacOSIconStyleAdapter.id))
    try original.write(to: fixture.profile, atomically: false, encoding: .utf8)
    // Editing the profile alone cannot disable the applied consumer.
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(MacOSIconStyleAdapter.id))
    #expect(try await fixture.apply(adopt: nil).succeeded)
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(MacOSIconStyleAdapter.id))
  }

  @Test(arguments: [
    IconStyleFixtureValues.applied, IconStyleFixtureValues.original,
    IconStyleFixtureValues.external,
  ])
  func disablingRestoresOrKeepsTheCurrentValue(current: MacOSIconStyle) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    #expect(try fixture.plan().output.contains("restore_macos_icon_style"))
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"build":"25G83","accent":true,"iconStyle":true}}"#),
      .init(arguments: ["get", "icon-style"], output: current.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularLight", "None"],
        output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let result = try await runner(fake).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: fixture.profile,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: nil, json: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(try store.load() == nil)
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count
        == (current == IconStyleFixtureValues.applied ? 1 : 0))
    if current == IconStyleFixtureValues.external {
      #expect(
        result.output.contains(
          "Kept the ClearLight / Green / no custom tint icon style, which was changed after setup.")
      )
    }
  }

  @Test func disableFailureRetainsTheOriginalAndBlocksApply() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let fake = ProcessRunnerFake(
      output: #"{"ok":true,"value":{"build":"unknown","accent":true,"iconStyle":true}}"#)
    let result = try await runner(fake).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: fixture.profile,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: nil, json: true)
    #expect(!result.succeeded)
    #expect(result.output.contains("not one Macarchy has tested"))
    #expect(try store.load() != nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(fake.requests.map(\.arguments) == [["check"]])
  }

  @Test func deferredDisableKeepsTheOriginalUntilItsCommit() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"build":"25G83","accent":true,"iconStyle":true}}"#),
      .init(arguments: ["get", "icon-style"], output: IconStyleFixtureValues.applied.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularLight", "None"],
        output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let runner = runner(fake)
    let result = try await runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: fixture.profile,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: nil, json: true, deferFinalization: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(try store.load() != nil)
    #expect(!fake.requests.contains { $0.arguments.first == "set" })
    let committed = try runner.finishDeferredApply(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: PortableProfileLoader().load(at: fixture.profile, required: true),
      stateRoot: fixture.state, homeDirectory: fixture.home, commit: true
    ).changed
    #expect(committed)
    #expect(try store.load() == nil)
    #expect(fake.requests.filter { $0.arguments.first == "set" }.count == 1)
  }

  @Test(arguments: ["restored", "kept", "pending", "failed", "recover-kept"], [false, true])
  func setupApplyReportsDeferredDisableThroughTheAggregate(mode: String, json: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Environment"),
      to: fixture.context.environmentResourcesRoot)
    let base = """
      schema_version = 1
      [focus_ring]
      provider = "disabled"
      [editor]
      provider = "disabled"
      [desktop]
      provider = "disabled"
      [top_bar]
      provider = "disabled"

      """
    try (base + "[macos_look]\nicon_style = true\n").write(
      to: fixture.context.profileURL, atomically: false, encoding: .utf8)
    let current: MacOSIconStyle =
      mode.contains("kept")
      ? IconStyleFixtureValues.external
      : mode == "pending" ? IconStyleFixtureValues.pending : IconStyleFixtureValues.applied
    let build = mode == "failed" ? "unknown" : "25G83"
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output:
          "{\"ok\":true,\"value\":{\"build\":\"\(build)\",\"accent\":true,\"iconStyle\":true}}"),
      .init(arguments: ["get", "icon-style"], output: current.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularLight", "None"],
        output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let environmentRunner = runner(fake)
    let paths = testConsumerPaths(homeDirectory: fixture.home)
    let initial = try await environmentRunner.execute(
      resourcesRoot: fixture.context.environmentResourcesRoot,
      profileURL: fixture.context.profileURL,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: paths, adopt: nil, json: true)
    #expect(initial.succeeded, "\(initial.output)")
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?
        .enabledThemeAdapterIDs?.contains(MacOSIconStyleAdapter.id) == true)
    let store = MacOSIconStyleStore(root: fixture.state)
    let original = MacOSIconStyleRecord(
      original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied,
      pending: mode == "pending" ? IconStyleFixtureValues.pending : nil)
    try store.persist(original)
    try (base + "[macos_look]\nicon_style = false\n").write(
      to: fixture.context.profileURL, atomically: false, encoding: .utf8)
    let shouldInterrupt = Mutex(mode == "recover-kept")
    let finalize = UnifiedSetupTeardownCommandRunner.finalizeEnvironment(using: environmentRunner)
    let teardown = UnifiedSetupTeardownCommandRunner(
      planner: fixture.planner(plannedStages: [.environment]),
      environmentTeardown: { _, _, _ in
        throw UnexpectedComponentCall()
      },
      desktopTeardown: { _, _, _ in throw UnexpectedComponentCall() },
      themeTeardown: { _, _, _, _ in throw UnexpectedComponentCall() },
      environmentApplyFinalization: { context, commit in
        #expect(commit)
        if shouldInterrupt.withLock({ value in
          let old = value
          value = false
          return old
        }) {
          throw UnifiedSetupInterruptionError.injected
        }
        return try await finalize(context, commit)
      })
    let aggregate = fixture.runner(
      available: { _ in true }, plannedStages: [.environment],
      theme: { _, _ in throw UnexpectedComponentCall() },
      desktop: { _, _, _, _, _ in throw UnexpectedComponentCall() },
      environment: { context, profile, paths, adoptions, enabled in
        let report = try await environmentRunner.report(
          resourcesRoot: context.environmentResourcesRoot, profileURL: context.profileURL,
          profileRequired: true, stateRoot: context.stateRoot, homeDirectory: context.homeDirectory,
          consumerPaths: paths, adopt: adoptions.environment, deferFinalization: true,
          withinUnifiedSetup: true, enabledThemeAdapterIDs: enabled, profile: profile)
        #expect(report.succeeded, "\(report.message)")
        #expect(try store.load() == original)
        #expect(fake.requests.isEmpty)
        return report
      },
      transactionTeardown: teardown)
    if mode == "recover-kept" {
      await #expect(throws: UnifiedSetupInterruptionError.self) {
        try await aggregate.execute(context: fixture.context, consumerPaths: paths, json: json)
      }
      #expect(
        try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.phase == .committing)
      #expect(try store.load() == original)
    }
    let result = try await aggregate.execute(
      context: fixture.context, consumerPaths: paths, json: json)
    #expect(result.succeeded == (mode != "failed"), "\(result.output)")
    let expected =
      mode == "failed"
      ? "not one Macarchy has tested"
      : mode.contains("kept")
        ? "Kept the ClearLight / Green / no custom tint icon style, which was changed after setup."
        : "Restored the original RegularLight icon style."
    #expect(result.output.contains(expected))
    if mode == "failed" {
      #expect(try store.load() == original)
      #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() != nil)
      #expect(
        try UnifiedSetupTransactionStore(stateRoot: fixture.state).read()?.phase == .committing)
      if json {
        #expect(try jsonObject(result.output)["outcome"] as? String == "recovery_required")
      }
    } else {
      #expect(try store.load() == nil)
      #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() == nil)
      #expect(try UnifiedSetupTransactionStore(stateRoot: fixture.state).read() == nil)
      if json {
        let environment = try #require(
          try jsonObject(result.output)["environment"] as? [String: Any])
        let finalization = try #require(environment["finalization"] as? [String: Any])
        #expect(finalization["outcome"] as? String == "committed")
        #expect((finalization["message"] as? String)?.contains(expected) == true)
      }
    }
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count
        == (mode == "restored" || mode == "pending" ? 1 : 0))
  }

  @Test(arguments: [false, true])
  func entirelyDisabledProfileRestoresWithOrWithoutManagedEnvironment(managed: Bool) async throws {
    let fixture = try EnvironmentLifecycleFixture(disabled: !managed, externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    if managed {
      #expect(try await fixture.apply(adopt: nil).succeeded)
      let disabled = try EnvironmentLifecycleFixture(disabled: true)
      defer { try? FileManager.default.removeItem(at: disabled.root) }
      try String(contentsOf: disabled.profile, encoding: .utf8).write(
        to: fixture.profile, atomically: false, encoding: .utf8)
    }
    let store = MacOSIconStyleStore(root: fixture.state)
    try store.persist(
      .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: #"{"ok":true,"value":{"build":"25G83","accent":true,"iconStyle":true}}"#),
      .init(arguments: ["get", "icon-style"], output: IconStyleFixtureValues.applied.fixtureReply),
      .init(
        arguments: ["set", "icon-style", "RegularLight", "None"],
        output: IconStyleFixtureValues.original.fixtureReply),
    ])
    let result = try await runner(fake).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: fixture.profile,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: nil, json: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(result.output.contains("Restored the original RegularLight icon style."))
    #expect(try store.load() == nil)
  }

  private func runner(_ fake: ProcessRunnerFake) -> EnvironmentApplyCommandRunner {
    EnvironmentApplyCommandRunner(
      prerequisites: .assumed, theme: nil, verifier: .assumed,
      iconStyle: { root in
        MacOSIconStyleAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
  }
}
