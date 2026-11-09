import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ZedPresetLifecycleTests {
  @Test(
    arguments: [
      nil, "{}\n", "{\"theme\": \"One Dark\"}",
      "// settings\n{\n  // theme\n  \"theme\" /* key */ : {\"mode\": \"system\", \"light\": \"A\", \"dark\": \"B\",}, // keep\n  \"vim_mode\": true,\n}\n",
      "{\n  // keep\n  \"vim_mode\": true,\n}\n", "{ /* empty */ }",
    ] as [String?])
  func adoptionAndTeardownRestoreExactBytes(original: String?) async throws {
    let f = try Fixture(original: original)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let plan = try f.harness.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    let applied = try await f.apply(adopt: digest)
    #expect(applied.succeeded, "\(applied.output)")
    let ownership = try #require(try EnvironmentStateStore(stateRoot: f.state).readOwnership())
    #expect(ownership.enabledThemeAdapterIDs == ["zed"])
    #expect(ownership.zed != nil && ownership.zedFamily != nil)
    let data = try Data(contentsOf: f.settings)
    #expect(try EnvironmentZedOwnership.matchesManaged(data, at: f.settings))
    if original == nil {
      #expect(String(decoding: data, as: UTF8.self) == "{\n  \"theme\": \"Macarchy\"\n}\n")
    }
    #expect(
      try FileManager.default.attributesOfItem(atPath: f.family.path)[.type] as? FileAttributeType
        == .typeRegular)
    #expect(try await f.apply().succeeded)
    let result = try await f.harness.teardown(consumerPaths: f.paths)
    #expect(result.succeeded, "\(result.output)")
    #expect((try? Data(contentsOf: f.settings)) == original.map { Data($0.utf8) })
    #expect(!FileManager.default.fileExists(atPath: f.family.path))
    #expect(!FileManager.default.fileExists(atPath: f.family.deletingLastPathComponent().path))
  }

  @Test(arguments: ["member", "family", "settings-link", "directory-link"])
  func driftBlocksApplyAndTeardown(change: String) async throws {
    let f = try Fixture(original: "{\"theme\": \"One Dark\"}")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    switch change {
    case "member": try Data("{\"theme\": \"user\"}".utf8).write(to: f.settings)
    case "family":
      let text = try String(contentsOf: f.family, encoding: .utf8)
      try Data(text.replacingOccurrences(of: "#1e1e2e", with: "#123456").utf8).write(to: f.family)
    default:
      let url = change == "settings-link" ? f.settings : f.settings.deletingLastPathComponent()
      let target = f.home.appending(path: "redirected")
      try FileManager.default.moveItem(at: url, to: target)
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }
    let settings = try Data(contentsOf: f.settings)
    let family = try Data(contentsOf: f.family)
    #expect(try !f.harness.plan().succeeded)
    #expect(try await !f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(try Data(contentsOf: f.settings) == settings)
    #expect(try Data(contentsOf: f.family) == family)
  }

  @Test func existingFamilyIsNotAdoptedAndExistingDirectoryIsPreserved() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.createDirectory(
      at: f.family.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("user family".utf8).write(to: f.family)
    #expect(try !f.harness.plan().succeeded)
    try FileManager.default.removeItem(at: f.family)
    #expect(try await f.apply().succeeded)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(FileManager.default.fileExists(atPath: f.family.deletingLastPathComponent().path))
  }

  @Test func unrelatedSettingsAndThemeFilesSurviveTeardown() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    try Data("{\"theme\": \"Macarchy\", \"vim_mode\": true}".utf8).write(to: f.settings)
    let other = f.family.deletingLastPathComponent().appending(path: "user.json")
    try Data("user".utf8).write(to: other)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(try String(contentsOf: f.settings, encoding: .utf8) == "{\"vim_mode\": true}")
    #expect(try String(contentsOf: other, encoding: .utf8) == "user")
  }

  @Test func runtimeChecksJSONCMemberAndFamilyAfterThemeChange() async throws {
    let f = try Fixture(
      original: "// note\n{\"theme\": {\"mode\": \"system\", \"light\": \"A\", \"dark\": \"B\",},}")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    try paths.zedValidateOwnership(f.family)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let next = try ThemeActivator(root: f.state).activate(package: package)
    _ = next
    let adapter = ZedAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [1, 27, 0] }, validateOwnership: paths.zedValidateOwnership)
    let outcome = try await adapter.reconciliation().run()
    #expect(outcome.status == .applied)
    #expect(try Data(contentsOf: f.family) == Data(ZedAdapter.render(package: package).utf8))
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func publishedFamilySurvivesInterruptedActivationAndGenerationCollection() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)  // Adopt A.
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = ZedAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [1, 27, 0] }, validateOwnership: paths.zedValidateOwnership)
    let b = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let bManifest = try ThemeActivator(root: f.state).activate(package: b)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let bData = try Data(contentsOf: f.family)
    let receipt = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: ZedAdapter.publicationReceiptURL(root: f.state)))
        as? [String: String])
    #expect(receipt["path"] == f.family.path)
    #expect(receipt["digest"] == sha256Digest(bData))
    let c = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/kanagawa-wave"))
    let interrupted = ThemeActivator(
      root: f.state,
      faultInjector: {
        if case .currentReplaced = $0 { throw Injected.failure }
      })
    #expect(throws: ThemeCommittedActivationError.self) { try interrupted.activate(package: c) }
    #expect(try ThemeGenerationReader(root: f.state).activeManifest().themeID == c.id)
    #expect(try Data(contentsOf: f.family) == bData)  // C never reached Zed.
    try activateCatppuccinMocha(stateRoot: f.state)  // A active; GC collects B.
    #expect(
      !FileManager.default.fileExists(
        atPath:
          f.state.appending(path: "generations/\(bManifest.generationID)").path))
    #expect(try Data(contentsOf: f.family) == bData)
    #expect(try f.harness.plan().succeeded)
    try paths.zedValidateOwnership(f.family)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.family.path))
  }

  @Test func failedReceiptPublicationDoesNotReportSuccessAndCanRetry() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = ZedAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [1, 27, 0] }, validateOwnership: paths.zedValidateOwnership)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    _ = try ThemeActivator(root: f.state).activate(package: package)
    let receipt = ZedAdapter.publicationReceiptURL(root: f.state)
    try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await adapter.reconciliation().run() }
    #expect(try Data(contentsOf: f.family) == Data(ZedAdapter.render(package: package).utf8))
    try FileManager.default.removeItem(at: receipt)
    // No receipt was persisted. The validated active render authenticates retry.
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func preZedGenerationSupportsAdoptionAndReconciliationWithoutMutation() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let current = try ThemeGenerationReader(root: f.state).activeManifest()
    let generation = f.state.appending(path: "generations/\(current.generationID)")
    let manifestURL = generation.appending(path: "manifest.json")
    let artifact = generation.appending(path: ZedAdapter.outputPath)
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: manifestURL)) as? [String: Any])
    var versions = try #require(object["renderer_versions"] as? [String: Int])
    var artifacts = try #require(object["artifacts"] as? [String: String])
    versions.removeValue(forKey: ZedAdapter.id)
    artifacts.removeValue(forKey: ZedAdapter.outputPath)
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
      try ThemeGenerationReader(root: f.state).activeManifest().rendererVersions["zed"] == nil)
    #expect(try f.harness.plan().succeeded)
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = ZedAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [1, 27, 0] }, validateOwnership: paths.zedValidateOwnership)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
    #expect(try Data(contentsOf: f.family) == Data(ZedAdapter.render(package: package).utf8))
    #expect(try Data(contentsOf: manifestURL) == legacyData)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(
      try ThemeGenerationReader(root: f.state).activeManifest().generationID == current.generationID
    )
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func rollbackRestoresBothFilesAfterAuthorityPublicationFailure() async throws {
    let original =
      "// keep\n{\"theme\": {\"mode\": \"system\", \"light\": \"A\", \"dark\": \"B\"}}\n"
    let f = try Fixture(original: original)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    let result = try await f.apply(adopt: digest, fault: { _ in throw Injected.failure })
    #expect(!result.succeeded)
    #expect(try Data(contentsOf: f.settings) == Data(original.utf8))
    #expect(!FileManager.default.fileExists(atPath: f.family.path))
    #expect(try EnvironmentStateStore(stateRoot: f.state).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: f.state).readTransaction() == nil)
  }

  @Test func overriddenConsumerHomeCannotRedirectTheOwnedFamilyWrite() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let other = f.home.appending(path: "other/zed")
    let target = other.appending(path: "themes/macarchy.json")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("unowned".utf8)
    try original.write(to: target)
    let adapter = ZedAdapter(
      root: f.state, configurationDirectory: other, version: { [1, 27, 0] },
      validateOwnership: paths.zedValidateOwnership)
    let result = try await adapter.reconciliation().run()
    #expect(result.status == .drifted)
    #expect(try Data(contentsOf: target) == original)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func enablementRequiresSupportedAppButDisablementDoesNot() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let old = PresetLifecycleTestHarness(
      profile: f.profile, state: f.state, home: f.home, zedVersion: { [0, 122, 1] })
    #expect(try !old.plan().succeeded)
    let missing = PresetLifecycleTestHarness(
      profile: f.profile, state: f.state, home: f.home, zedVersion: { throw Injected.failure })
    #expect(try !missing.plan().succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    #expect(try await f.apply().succeeded)
    try presetTestProfile(presets: ["zed": false]).write(
      to: f.profile, atomically: true, encoding: .utf8)
    #expect(try await f.apply(version: { throw Injected.failure }).succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    #expect(!FileManager.default.fileExists(atPath: f.family.path))
  }

  private enum Injected: Error { case failure }

  @Test func oversizedEditsAreRefusedBeforePublication() throws {
    let url = URL(filePath: "/home/test/.config/zed/settings.json")
    let empty =
      Data("{".utf8) + Data(repeating: 32, count: BoundedRegularFile.maximumSize - 2)
      + Data("}".utf8)
    #expect(throws: EnvironmentLifecycleError.self) {
      try EnvironmentZedOwnership.managed(from: empty, at: url)
    }
    let member = Data(EnvironmentZedOwnership.managedMember)
    let full =
      Data("{".utf8) + member
      + Data(repeating: 32, count: BoundedRegularFile.maximumSize - member.count - 2)
      + Data("}".utf8)
    let original = Data(#""theme": {"mode": "system", "light": "A", "dark": "B"}"#.utf8)
    let owner = EnvironmentZedOwnership(
      path: url.path, originalFileExisted: true, originalMember: original)
    #expect(throws: EnvironmentLifecycleError.self) { try owner.restored(in: full, at: url) }
  }

  private struct Fixture {
    let root: URL
    let home: URL
    let state: URL
    let profile: URL
    var settings: URL { home.appending(path: ".config/zed/settings.json") }
    var family: URL { home.appending(path: ".config/zed/themes/macarchy.json") }
    var harness: PresetLifecycleTestHarness { .init(profile: profile, state: state, home: home) }
    var paths: ThemeConsumerPaths {
      var paths = testConsumerPaths()
      paths.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      paths.starshipConfigurationURL = home.appending(path: ".config/starship.toml")
      return paths
    }
    init(original: String?) throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "zed-preset-\(UUID().uuidString)")
      home = root.appending(path: "home")
      state = home.appending(path: ".config/macarchy")
      profile = root.appending(path: "profile.toml")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      if let original {
        try FileManager.default.createDirectory(
          at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: settings)
      }
      try presetTestProfile(presets: ["zed": true]).write(
        to: profile, atomically: true, encoding: .utf8)
      try activateCatppuccinMocha(stateRoot: state)
    }
    func apply(
      adopt: String? = nil,
      version: @escaping @Sendable () throws -> [Int] = { [1, 27, 0] },
      fault: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
    ) async throws -> (output: String, succeeded: Bool) {
      try await harness.apply(
        runner: EnvironmentApplyCommandRunner(
          prerequisites: .assumed,
          theme: stubThemeController(
            reconciled: ("applied", "Zed reloaded"), inspected: ("ready", "Zed ready")),
          verifier: .assumed, zedVersion: version, transactionFaultInjector: fault),
        consumerPaths: paths, adopt: adopt)
    }
  }
}
