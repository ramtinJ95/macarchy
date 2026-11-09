import Foundation
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
      stateRoot: fixture.state, homeDirectory: fixture.home, commit: true)
    #expect(committed)
    #expect(try store.load() == nil)
    #expect(fake.requests.filter { $0.arguments.first == "set" }.count == 1)
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
