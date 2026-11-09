import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct GhosttyPresetLifecycleTests {
  @Test(
    arguments: [
      nil, "", "font-size = 13\n", "font-size = 13", "font-size = 13\r\n", "font-size = 13\r",
      "config-file = user.conf\nbackground = #112233\n",
    ] as [String?])
  func reviewedAdoptionAndTeardownRestoreExactBytes(original: String?) async throws {
    let fixture = try Fixture(original: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let plan = try fixture.harness.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await fixture.apply(adopt: digest, realReconciliation: true)
    #expect(applied.succeeded, "\(applied.output)")
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ownership.ghostty != nil)
    #expect(ownership.enabledThemeAdapterIDs == [GhosttyAdapter.id])
    let installed = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(installed.hasSuffix(GhosttyConfiguration.includeDirective(root: fixture.state) + "\n"))
    let bridge = fixture.state.appending(path: GhosttyAdapter.bridgePath)
    #expect(
      try PinnedFilesystem.readRegularFile(at: bridge).data
        == GhosttyAdapter.activeConfiguration(root: fixture.state))
    let noOp = try await fixture.apply(realReconciliation: true)
    #expect(noOp.succeeded, "\(noOp.output)")
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == installed)
    let tornDown = try await fixture.harness.teardown(consumerPaths: fixture.paths)
    #expect(tornDown.succeeded, "\(tornDown.output)")
    if let original {
      #expect(try Data(contentsOf: fixture.configuration) == Data(original.utf8))
    } else {
      #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    }
    #expect(!FileManager.default.fileExists(atPath: bridge.path))
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test(arguments: ["edited", "moved", "removed"])
  func driftBlocksTeardownWithoutOverwritingTheFile(change: String) async throws {
    let fixture = try Fixture(original: "font-size = 13\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let line = GhosttyConfiguration.includeDirective(root: fixture.state)
    let drifted: String
    switch change {
    case "edited": drifted = "font-size = 13\n\(line) # edited\n"
    case "moved": drifted = "\(line)\nfont-size = 13\n"
    default: drifted = "font-size = 13\n"
    }
    try Data(drifted.utf8).write(to: fixture.configuration)
    let result = try await fixture.harness.teardown(consumerPaths: fixture.paths)
    #expect(!result.succeeded)
    #expect(try Data(contentsOf: fixture.configuration) == Data(drifted.utf8))
    #expect(try !fixture.harness.plan().succeeded)
  }

  @Test(arguments: ["leaf", "ancestor"])
  func symlinkReplacementBlocksPlanAndTeardown(kind: String) async throws {
    let fixture = try Fixture(original: "font-size = 13\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let original =
      kind == "leaf" ? fixture.configuration : fixture.configuration.deletingLastPathComponent()
    let target = fixture.home.appending(path: "redirected")
    try FileManager.default.moveItem(at: original, to: target)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
    let before = try Data(contentsOf: fixture.configuration)
    #expect(try !fixture.harness.plan().succeeded)
    #expect(try await !fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
    #expect(try Data(contentsOf: fixture.configuration) == before)
  }

  @Test func lastExistingFileIsAdoptedAndLaterUserIncludesArePreserved() async throws {
    let fixture = try Fixture(original: "font-size = 13\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let last = fixture.home.appending(
      path: "Library/Application Support/com.mitchellh.ghostty/config.ghostty")
    try FileManager.default.createDirectory(
      at: last.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("font-family = Menlo\n".utf8).write(to: last)
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.ghostty)
    #expect(ownership.path == last.path)
    var text = try String(contentsOf: last, encoding: .utf8)
    text += "config-file = user.conf\n"
    try Data(text.utf8).write(to: last)
    #expect(try fixture.harness.plan().succeeded)
    let result = try await fixture.harness.teardown(consumerPaths: fixture.paths)
    #expect(result.succeeded, "\(result.output)")
    #expect(
      try String(contentsOf: last, encoding: .utf8)
        == "font-family = Menlo\nconfig-file = user.conf\n")
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "font-size = 13\n")
  }

  @Test(arguments: [[1, 2, 3], [1, 3, 0]], [false, true])
  func adoptionUsesOnlyFilesReadByTheInstalledVersion(version: [Int], extensionsOnly: Bool)
    async throws
  {
    let fixture = try Fixture(original: extensionsOnly ? nil : "font-size = 13\n", version: version)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: fixture.home, environment: [:])
    for file in [files[1], files[3]] + (extensionsOnly ? [] : [files[2]]) {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("font-size = 14\n".utf8).write(to: file)
    }
    let original = files.map { try? Data(contentsOf: $0) }
    let legacy = version[1] == 2
    let expected = legacy ? (extensionsOnly ? files[0] : files[2]) : files[3]
    let plan = try fixture.harness.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let entries = try #require(try jsonObject(plan.output)["entries"] as? [[String: Any]])
    let entry = try #require(entries.first { $0["id"] as? String == "ghostty_configuration" })
    #expect(entry["path"] as? String == expected.path)
    #expect((entry["message"] as? String)?.contains("before 1.3.0 ignore:") == legacy)
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await fixture.apply(adopt: digest)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.ghostty?.path
        == expected.path)
    #expect(try await fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
    for (index, file) in files.enumerated() {
      #expect((try? Data(contentsOf: file)) == original[index])
    }
  }

  @Test func downgradeRefusesIgnoredOwnedFileButAllowsRestorationWithoutTheApp() async throws {
    let fixture = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let files = ThemeConsumerPaths.ghosttyConfigurationFiles(home: fixture.home, environment: [:])
    try FileManager.default.createDirectory(
      at: files[3].deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("font-size = 13\n".utf8).write(to: files[3])
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let owner = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.ghostty)
    let old = EnvironmentProviderInspector(ghosttyVersion: { [1, 2, 3] })
    #expect(throws: EnvironmentLifecycleError.self) {
      try old.inspectGhostty(
        enabled: true, ownership: owner, home: fixture.home, root: fixture.state)
    }
    let missing = EnvironmentProviderInspector(ghosttyVersion: { throw Injected.failure })
    #expect(
      try missing.inspectGhostty(
        enabled: false, ownership: owner, home: fixture.home, root: fixture.state
      ).entry?.status == .restorationRequired)
    #expect(try await fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
    #expect(try Data(contentsOf: files[3]) == Data("font-size = 13\n".utf8))
  }

  @Test func disableRestoresAndMissingPrerequisiteDoesNotAdopt() async throws {
    let fixture = try Fixture(original: "font-size = 13")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missing = EnvironmentPrerequisiteInspector { _, _ in
      [
        EnvironmentPrerequisiteStatus(
          id: "ghostty", status: "missing", requirement: "Ghostty.app",
          remediation: "Install Ghostty")
      ]
    }
    let result = try await fixture.apply(prerequisites: missing)
    #expect(!result.succeeded)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "font-size = 13")
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try presetTestProfile(presets: ["ghostty": false]).write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded, "\(disabled.output)")
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "font-size = 13")
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test func failureAfterAuthorityPublicationRollsBackTheOwnedLine() async throws {
    let fixture = try Fixture(original: "font-size = 13")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest =
      try jsonObject(fixture.harness.plan().output)["adoption_evidence_digest"] as? String
    let result = try await fixture.apply(
      adopt: digest,
      faultInjector: { checkpoint in
        if checkpoint == .authorityPublished { throw Injected.failure }
      })
    #expect(!result.succeeded)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "font-size = 13")
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() == nil)
  }

  @Test func deferredCommitAndFinalStatusReuseTheInjectedVersion() async throws {
    let fixture = try Fixture(original: "font-size = 13\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let probes = Mutex(0)
    let runner = EnvironmentApplyCommandRunner(
      prerequisites: .assumed,
      theme: stubThemeController(
        reconciled: ("applied", "Reloaded"), inspected: ("ready", "Ready")),
      verifier: .assumed,
      ghosttyVersion: {
        probes.withLock { $0 += 1 }
        return [1, 2, 3]
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
        stateRoot: fixture.state, homeDirectory: fixture.home, commit: true))
    #expect(probes.withLock { $0 } == 2)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readTransaction() == nil)
    #expect(try await fixture.harness.teardown(consumerPaths: fixture.paths).succeeded)
  }

  @Test func appendedBytesStayReadableAndSeparatorShapeIsValidated() throws {
    let url = URL(filePath: "/home/test/.config/ghostty/config")
    let root = URL(filePath: "/home/test/.config/macarchy")
    let original = Data(repeating: 32, count: BoundedRegularFile.maximumSize)
    let owner = try EnvironmentGhosttyOwnership.adopting(original, at: url, root: root)
    #expect(throws: EnvironmentLifecycleError.self) { try owner.managed(from: original, at: url) }
    let invalid = EnvironmentGhosttyOwnership(
      path: url.path, originalFileExisted: true,
      lineIndex: 0, insertedSeparatorBefore: true, directive: owner.directive)
    #expect(!invalid.hasValidShape)
  }

  @Test func preGhosttyGenerationSupportsAdoptionAndReconciliationWithoutMutation() async throws {
    let f = try Fixture(original: "font-size = 13")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let current = try ThemeGenerationReader(root: f.state).activeManifest()
    let generation = f.state.appending(path: "generations/\(current.generationID)")
    let manifestURL = generation.appending(path: "manifest.json")
    let artifact = generation.appending(path: GhosttyAdapter.outputPath)
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: manifestURL)) as? [String: Any])
    var versions = try #require(object["renderer_versions"] as? [String: Int])
    var artifacts = try #require(object["artifacts"] as? [String: String])
    versions.removeValue(forKey: GhosttyAdapter.id)
    artifacts.removeValue(forKey: GhosttyAdapter.outputPath)
    object["renderer_versions"] = versions
    object["artifacts"] = artifacts
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: artifact.deletingLastPathComponent().path)
    try FileManager.default.removeItem(at: artifact)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: artifact.deletingLastPathComponent().path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try legacyData.write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: manifestURL.path)
    #expect(
      try ThemeGenerationReader(root: f.state).activeManifest().rendererVersions["ghostty"] == nil)
    let plan = try f.harness.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await f.apply(adopt: digest, realReconciliation: true)
    #expect(applied.succeeded, "\(applied.output)")
    let bridge = f.state.appending(path: GhosttyAdapter.bridgePath)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
    #expect(try Data(contentsOf: bridge) == Data(GhosttyAdapter.render(package: package).utf8))
    #expect(try Data(contentsOf: manifestURL) == legacyData)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(
      try ThemeGenerationReader(root: f.state).activeManifest().generationID == current.generationID
    )
    _ = try ThemeActivator(root: f.state, faultInjector: { _ in }).activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))
    let switched = try await f.apply(realReconciliation: true)
    #expect(switched.succeeded, "\(switched.output)")
    #expect(try Data(contentsOf: bridge) == GhosttyAdapter.activeConfiguration(root: f.state))
    #expect(try Data(contentsOf: bridge) != Data(GhosttyAdapter.render(package: package).utf8))
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(try Data(contentsOf: f.configuration) == Data("font-size = 13".utf8))
    #expect(!FileManager.default.fileExists(atPath: bridge.path))
  }

  @Test(arguments: [false, true])
  func outdatedOwnedLineRefusesApplyButRestoresBeforeReenable(disable: Bool) async throws {
    let f = try Fixture(original: "font-size = 13")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    let store = EnvironmentStateStore(stateRoot: f.state)
    let original = try #require(try store.readOwnership())
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var owner = try #require(object["ghostty"] as? [String: Any])
    let legacy =
      "config-file = ?\"\(StateLayout(root: f.state).currentThemeArtifact(GhosttyAdapter.outputPath).path)\""
    owner["directive"] = legacy
    object["ghostty"] = owner
    // Model unreleased old ownership, which never recorded a bridge snapshot.
    object["original_theme_bridges"] = []
    try store.writeOwnership(
      JSONDecoder().decode(
        EnvironmentOwnership.self,
        from: JSONSerialization.data(withJSONObject: object)))
    let before = Data("font-size = 13\n\(legacy)\n".utf8)
    try before.write(to: f.configuration)
    let plan = try f.harness.plan()
    #expect(!plan.succeeded)
    #expect(plan.output.contains("outdated"))
    #expect(plan.output.contains("re-enable"))
    #expect(try await !f.apply().succeeded)
    #expect(try Data(contentsOf: f.configuration) == before)
    if disable {
      try presetTestProfile(presets: ["ghostty": false]).write(
        to: f.profile, atomically: true, encoding: .utf8)
      #expect(try await f.apply().succeeded)
    } else {
      #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    }
    #expect(try Data(contentsOf: f.configuration) == Data("font-size = 13".utf8))
    try presetTestProfile(presets: ["ghostty": true]).write(
      to: f.profile, atomically: true, encoding: .utf8)
    let renewed = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: renewed, realReconciliation: true).succeeded)
    #expect(
      try String(contentsOf: f.configuration, encoding: .utf8).contains(GhosttyAdapter.bridgePath))
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.state.appending(path: GhosttyAdapter.bridgePath).path))
  }

  @Test func unownedBridgeBlocksAdoptionWithoutMutation() async throws {
    let f = try Fixture(original: "font-size = 13")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let bridge = f.state.appending(path: GhosttyAdapter.bridgePath)
    try FileManager.default.createDirectory(
      at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unowned".utf8).write(to: bridge)
    #expect(try !f.harness.plan().succeeded)
    #expect(try await !f.apply().succeeded)
    #expect(try Data(contentsOf: bridge) == Data("unowned".utf8))
    #expect(try Data(contentsOf: f.configuration) == Data("font-size = 13".utf8))
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
      return .init(profile: profile, state: state, home: home, ghosttyVersion: { version })
    }
    var paths: ThemeConsumerPaths {
      var paths = testConsumerPaths()
      paths.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      return paths
    }
    init(original: String?, version: [Int] = [1, 4, 0]) throws {
      self.version = version
      root = FileManager.default.temporaryDirectory.appending(
        path: "ghostty-preset-\(UUID().uuidString)")
      home = root.appending(path: "home")
      state = home.appending(path: ".config/macarchy")
      profile = root.appending(path: "profile.toml")
      configuration = home.appending(path: ".config/ghostty/config")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      if let original {
        try FileManager.default.createDirectory(
          at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: configuration)
      }
      try presetTestProfile(presets: ["ghostty": true]).write(
        to: profile, atomically: true, encoding: .utf8)
      try activateCatppuccinMocha(stateRoot: state)
    }
    func apply(
      adopt: String? = nil, prerequisites: EnvironmentPrerequisiteInspector = .assumed,
      realReconciliation: Bool = false,
      faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in
      }
    )
      async throws -> (output: String, succeeded: Bool)
    {
      let version = version
      let state = state
      let home = home
      let controller =
        realReconciliation
        ? DesktopThemeController(
          reconcile: { _, _, _ in
            let owner = try #require(
              EnvironmentStateStore(stateRoot: state).readOwnership()?.ghostty)
            let adapter = GhosttyAdapter(
              root: state, home: home,
              configurationFiles: ThemeConsumerPaths.ghosttyConfigurationFiles(
                home: home, environment: [:]),
              ownedConfigurationURL: URL(filePath: owner.path), ownedLineIndex: owner.lineIndex,
              executableURL: GhosttyAdapter.liveExecutableURL, controlIsAvailable: { true },
              processRunner: ProcessRunner { _ in
                ProcessResult(terminationStatus: 0, output: "Ghostty 1.4.0")
              },
              processes: GhosttyProcesses(list: { [] }, observe: { _ in nil }, signal: { _ in }))
            let result = try await adapter.reconciliation().run()
            return DesktopThemeReconciliation(
              generationID: try ThemeGenerationReader(root: state).activeManifest().generationID,
              results: [
                DesktopThemeAdapterStatus(
                  adapterID: GhosttyAdapter.id, requirement: "required",
                  status: result.status.rawValue, message: result.message)
              ],
              succeeded: result.status == .applied)
          },
          inspect: { _, _, _ in [] })
        : stubThemeController(
          reconciled: ("applied", "Ghostty reloaded"), inspected: ("ready", "Ghostty ready"))
      return try await harness.apply(
        runner: EnvironmentApplyCommandRunner(
          prerequisites: prerequisites,
          theme: controller,
          verifier: .assumed, ghosttyVersion: { version }, transactionFaultInjector: faultInjector),
        consumerPaths: paths, adopt: adopt)
    }
  }
}
