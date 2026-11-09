import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MacOSAccentLifecycleTests {
  @Test func profileOptionIsReviewedAndBecomesAppliedRuntimeAuthority() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (original + "\n[macos_look]\naccent = true\n").write(
      to: fixture.profile, atomically: false, encoding: .utf8)
    #expect(try fixture.plan().output.contains("configure_macos_accent"))
    #expect(try await fixture.apply(adopt: nil).succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ThemeRuntimeSelection.appliedAdapterIDs(for: ownership).contains(MacOSAccentAdapter.id))
    try original.write(to: fixture.profile, atomically: false, encoding: .utf8)
    // Editing the profile alone cannot disable the applied consumer.
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(MacOSAccentAdapter.id))
    #expect(try await fixture.apply(adopt: nil).succeeded)
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state, homeDirectory: fixture.home
      ).contains(MacOSAccentAdapter.id))
  }

  @Test(arguments: [MacOSAccent.blue, .graphite, .green])
  func disablingRestoresOrKeepsTheCurrentValue(current: MacOSAccent) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    #expect(try fixture.plan().output.contains("restore_macos_accent"))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: "{\"ok\":true,\"value\":\(current.rawValue)}"),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
    ])
    let result = try await runner(fake).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: fixture.profile,
      profileRequired: true, stateRoot: fixture.state, homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(), adopt: nil, json: true)
    #expect(result.succeeded, "\(result.output)")
    #expect(try store.load() == nil)
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count == (current == .blue ? 1 : 0))
    if current == .green {
      #expect(result.output.contains("Kept the green accent, which was changed after setup."))
    }
  }

  @Test func disableFailureRetainsTheOriginalAndBlocksApply() async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let fake = ProcessRunnerFake(output: #"{"ok":true,"value":{"build":"unknown","accent":true}}"#)
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
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: #"{"ok":true,"value":4}"#),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
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
    try (base + "[macos_look]\naccent = true\n").write(
      to: fixture.context.profileURL, atomically: false, encoding: .utf8)
    let current: MacOSAccent =
      mode.contains("kept") ? .green : mode == "pending" ? .red : .blue
    let build = mode == "failed" ? "unknown" : "25G83"
    let fake = ProcessRunnerFake(replies: [
      .init(
        arguments: ["check"],
        output: "{\"ok\":true,\"value\":{\"build\":\"\(build)\",\"accent\":true}}"),
      .init(arguments: ["get", "accent"], output: "{\"ok\":true,\"value\":\(current.rawValue)}"),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
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
        .enabledThemeAdapterIDs?.contains(MacOSAccentAdapter.id) == true)
    let store = MacOSAccentStore(root: fixture.state)
    let original = MacOSAccentRecord(
      original: .graphite, applied: .blue, pending: mode == "pending" ? .red : nil)
    try store.persist(original)
    try (base + "[macos_look]\naccent = false\n").write(
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
        ? "Kept the green accent, which was changed after setup."
        : "Restored the original graphite accent."
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

  private func runner(_ fake: ProcessRunnerFake) -> EnvironmentApplyCommandRunner {
    EnvironmentApplyCommandRunner(
      prerequisites: .assumed, theme: nil, verifier: .assumed,
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
  }
}
