import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct AlacrittyPresetLifecycleTests {
  @Test(
    arguments: [
      nil, "", "# keep\n[font]\nsize = 12\n",
      "[general]\nimport = [\n  'user.toml', # keep\n]\n[font]\nsize = 13\n",
    ] as [String?])
  func adoptionAndTeardownRestoreExactBytes(original: String?) async throws {
    let fixture = try Fixture(original: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let plan = try fixture.harness.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await fixture.apply(adopt: digest)
    #expect(applied.succeeded, "\(applied.output)")
    let owner = try #require(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(owner.alacritty != nil)
    #expect(owner.enabledThemeAdapterIDs == [AlacrittyAdapter.id])
    let managed = try Data(contentsOf: fixture.configuration)
    #expect(
      try AlacrittyImportEdit.imports(String(decoding: managed, as: UTF8.self)).last
        == fixture.state.appending(path: AlacrittyAdapter.bridgePath).path)
    let again = try await fixture.apply()
    #expect(again.succeeded, "\(again.output)")
    #expect(try Data(contentsOf: fixture.configuration) == managed)
    // Stub reconciliation is deliberate; write the bridge to exercise teardown's ownership.
    let bridge = fixture.state.appending(path: AlacrittyAdapter.bridgePath)
    try FileManager.default.createDirectory(
      at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# theme\n".utf8).write(to: bridge)
    let connection = fixture.state.appending(path: AlacrittyAdapter.connectionPath)
    try Data("{\"adopted_at_microseconds\":100}\n".utf8).write(to: connection)
    let torn = try await fixture.harness.teardown(consumerPaths: fixture.paths)
    #expect(torn.succeeded, "\(torn.output)")
    #expect((try? Data(contentsOf: fixture.configuration)) == original.map { Data($0.utf8) })
    #expect(!FileManager.default.fileExists(atPath: bridge.path))
    #expect(!FileManager.default.fileExists(atPath: connection.path))
  }
  @Test func aggregateSnapshotsRestoreBothAlacrittyFiles() throws {
    let fixture = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let empty = try EnvironmentThemeBridgeState.capture(
      ids: [], stateRoot: fixture.state, alacritty: true)
    #expect(
      empty.entries.map(\.path)
        == AlacrittyAdapter.statePaths.map { fixture.state.appending(path: $0).path })
    #expect(EnvironmentThemeBridgeState.pathsAreValid(empty.entries, stateRoot: fixture.state))
    for path in AlacrittyAdapter.statePaths {
      try AlacrittyAdapter.restoreBridge(
        at: fixture.state.appending(path: path), data: Data("original".utf8), mode: 0o600)
    }
    let saved = try EnvironmentThemeBridgeState.capture(
      ids: [], stateRoot: fixture.state, alacritty: true)
    for path in AlacrittyAdapter.statePaths {
      try Data("changed".utf8).write(to: fixture.state.appending(path: path))
    }
    try saved.restore()
    for path in AlacrittyAdapter.statePaths {
      #expect(try Data(contentsOf: fixture.state.appending(path: path)) == Data("original".utf8))
    }
    try empty.restore()
    for path in AlacrittyAdapter.statePaths {
      #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: path).path))
    }
  }
  @Test func missingAndOldApplicationDoNotAdopt() async throws {
    let fixture = try Fixture(original: "# keep\n", version: [0, 13, 2])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try !fixture.harness.plan().succeeded)
    #expect(try await !fixture.apply().succeeded)
    let missing = EnvironmentPrerequisiteInspector { _, _ in
      [
        EnvironmentPrerequisiteStatus(
          id: "alacritty", status: "missing",
          requirement: "Alacritty.app", remediation: "Install Alacritty")
      ]
    }
    #expect(try await !fixture.apply(prerequisites: missing).succeeded)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "# keep\n")
  }
  @Test func driftBlocksTeardown() async throws {
    let fixture = try Fixture(original: "[general]\nimport = []\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let before = try Data(contentsOf: fixture.configuration)
    let drift = Data("\n".utf8) + before
    try drift.write(to: fixture.configuration)
    #expect(try await !fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
    #expect(try Data(contentsOf: fixture.configuration) == drift)
  }
  @Test func disableRestoresAndMissingPrerequisiteDoesNotAdopt() async throws {
    let fixture = try Fixture(original: "# keep")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missing = EnvironmentPrerequisiteInspector { _, _ in
      [
        EnvironmentPrerequisiteStatus(
          id: "alacritty", status: "missing", requirement: "Alacritty.app",
          remediation: "Install Alacritty")
      ]
    }
    let result = try await fixture.apply(prerequisites: missing)
    #expect(!result.succeeded)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "# keep")
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try presetTestProfile(presets: ["alacritty": false]).write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded, "\(disabled.output)")
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "# keep")
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test func failureAfterAuthorityPublicationRollsBackTheOwnedLine() async throws {
    let fixture = try Fixture(original: "# keep")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    let result = try await fixture.apply(
      adopt: digest,
      faultInjector: { checkpoint in
        if checkpoint == .authorityPublished { throw Injected.failure }
      })
    #expect(!result.succeeded)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "# keep")
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() == nil)
  }

  @Test func deferredCommitAndFinalStatusReuseTheInjectedVersion() async throws {
    let fixture = try Fixture(original: "# keep\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let probes = Mutex(0)
    let runner = EnvironmentApplyCommandRunner(
      prerequisites: .assumed,
      theme: stubThemeController(
        reconciled: ("applied", "Reloaded"), inspected: ("ready", "Ready")),
      verifier: .assumed,
      alacrittyVersion: {
        probes.withLock { $0 += 1 }
        return [0, 17, 0]
      })
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    let applied = try await fixture.harness.apply(
      runner: runner, consumerPaths: fixture.paths, adopt: digest, deferFinalization: true)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(probes.withLock { $0 } == 1)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() != nil)
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: true)
    #expect(
      try runner.finishDeferredApply(
        resourcesRoot: repositoryRoot.appending(path: "Environment"), profile: profile,
        stateRoot: fixture.state, homeDirectory: fixture.home, commit: true
      ).changed)
    #expect(probes.withLock { $0 } == 2)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() == nil)
    #expect(try await fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
  }

  private enum Injected: Error { case failure }

  private struct Fixture {
    let root: URL
    let home: URL
    let state: URL
    let profile: URL
    let configuration: URL
    let version: [Int]
    var harness: PresetLifecycleTestHarness {
      let version = version
      return .init(profile: profile, state: state, home: home, alacrittyVersion: { version })
    }
    var paths: ThemeConsumerPaths {
      var paths = testConsumerPaths()
      paths.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      return paths
    }
    init(original: String?, version: [Int] = [0, 17, 0]) throws {
      self.version = version
      root = FileManager.default.temporaryDirectory.appending(
        path: "alacritty-preset-\(UUID().uuidString)")
      home = root.appending(path: "home")
      state = home.appending(path: ".config/macarchy")
      profile = root.appending(path: "profile.toml")
      configuration = home.appending(path: ".config/alacritty/alacritty.toml")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      if let original {
        try FileManager.default.createDirectory(
          at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: configuration)
      }
      try presetTestProfile(presets: ["alacritty": true]).write(
        to: profile, atomically: true, encoding: .utf8)
      try activateCatppuccinMocha(stateRoot: state)
    }
    func apply(
      adopt: String? = nil, prerequisites: EnvironmentPrerequisiteInspector = .assumed,
      faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in
      }
    )
      async throws -> (output: String, succeeded: Bool)
    {
      let version = version
      return try await harness.apply(
        runner: EnvironmentApplyCommandRunner(
          prerequisites: prerequisites,
          theme: stubThemeController(
            reconciled: ("applied", "Alacritty reloaded"), inspected: ("ready", "Alacritty ready")),
          verifier: .assumed, alacrittyVersion: { version }, transactionFaultInjector: faultInjector
        ),
        consumerPaths: paths, adopt: adopt)
    }
  }
}
