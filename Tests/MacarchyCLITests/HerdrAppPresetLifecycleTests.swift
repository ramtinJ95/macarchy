import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HerdrAppPresetLifecycleTests {
  @Test(
    arguments: [
      nil, "{}\n", "{\"theme\": \"atom-one-dark\"}",
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
    #expect(ownership.enabledThemeAdapterIDs == ["herdr-app"])
    #expect(ownership.herdrApp != nil && ownership.herdrAppPalette != nil)
    let data = try Data(contentsOf: f.settings)
    #expect(try EnvironmentHerdrAppOwnership.matchesManaged(data, at: f.settings))
    if original == nil {
      #expect(String(decoding: data, as: UTF8.self) == "{\n  \"theme\": \"macarchy-current\"\n}\n")
    }
    #expect(
      try FileManager.default.attributesOfItem(atPath: f.palette.path)[.type] as? FileAttributeType
        == .typeRegular)
    #expect(try await f.apply().succeeded)
    let result = try await f.harness.teardown(consumerPaths: f.paths)
    #expect(result.succeeded, "\(result.output)")
    #expect((try? Data(contentsOf: f.settings)) == original.map { Data($0.utf8) })
    #expect(!FileManager.default.fileExists(atPath: f.palette.path))
    #expect(!FileManager.default.fileExists(atPath: f.palette.deletingLastPathComponent().path))
  }

  @Test(arguments: ["member", "palette", "settings-link", "directory-link"])
  func driftBlocksApplyAndTeardown(change: String) async throws {
    let f = try Fixture(original: "{\"theme\": \"atom-one-dark\"}")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    switch change {
    case "member": try Data("{\"theme\": \"user\"}".utf8).write(to: f.settings)
    case "palette":
      let text = try String(contentsOf: f.palette, encoding: .utf8)
      try Data(text.replacingOccurrences(of: "#1e1e2e", with: "#123456").utf8).write(to: f.palette)
    default:
      let url = change == "settings-link" ? f.settings : f.settings.deletingLastPathComponent()
      let target = f.home.appending(path: "redirected")
      try FileManager.default.moveItem(at: url, to: target)
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }
    let settings = try Data(contentsOf: f.settings)
    let palette = try Data(contentsOf: f.palette)
    #expect(try !f.harness.plan().succeeded)
    #expect(try await !f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(try Data(contentsOf: f.settings) == settings)
    #expect(try Data(contentsOf: f.palette) == palette)
  }

  @Test func existingPaletteIsNotAdoptedAndExistingDirectoryIsPreserved() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.createDirectory(
      at: f.palette.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("user palette".utf8).write(to: f.palette)
    #expect(try !f.harness.plan().succeeded)
    try FileManager.default.removeItem(at: f.palette)
    #expect(try await f.apply().succeeded)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(FileManager.default.fileExists(atPath: f.palette.deletingLastPathComponent().path))
  }

  @Test func unrelatedSettingsAndThemeFilesSurviveTeardown() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    try Data("{\"theme\": \"macarchy-current\", \"vim_mode\": true}".utf8).write(to: f.settings)
    let other = f.palette.deletingLastPathComponent().appending(path: "user.json")
    try Data("user".utf8).write(to: other)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(try String(contentsOf: f.settings, encoding: .utf8) == "{\"vim_mode\": true}")
    #expect(try String(contentsOf: other, encoding: .utf8) == "user")
  }

  @Test func runtimeChecksMemberAndPaletteAfterThemeChange() async throws {
    let f = try Fixture(
      original: "{\"theme\": {\"mode\": \"system\", \"light\": \"A\", \"dark\": \"B\"}}")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    #expect(try await f.apply(adopt: digest).succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    try paths.herdrAppValidateOwnership(f.palette)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let next = try ThemeActivator(root: f.state).activate(package: package)
    _ = next
    let adapter = HerdrAppAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [0, 1, 14] }, validateOwnership: paths.herdrAppValidateOwnership)
    let outcome = try await adapter.reconciliation().run()
    #expect(outcome.status == .applied)
    #expect(try Data(contentsOf: f.palette) == Data(HerdrAppAdapter.render(package: package).utf8))
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func publishedPaletteSurvivesInterruptedActivationAndGenerationCollection() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)  // Adopt A.
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = HerdrAppAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [0, 1, 14] }, validateOwnership: paths.herdrAppValidateOwnership)
    let b = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    let bManifest = try ThemeActivator(root: f.state).activate(package: b)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let bData = try Data(contentsOf: f.palette)
    let receipt = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: HerdrAppAdapter.publicationReceiptURL(root: f.state)))
        as? [String: String])
    #expect(receipt["path"] == f.palette.path)
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
    #expect(try Data(contentsOf: f.palette) == bData)  // C never reached HerdrApp.
    try activateCatppuccinMocha(stateRoot: f.state)  // A active; GC collects B.
    #expect(
      !FileManager.default.fileExists(
        atPath:
          f.state.appending(path: "generations/\(bManifest.generationID)").path))
    #expect(try Data(contentsOf: f.palette) == bData)
    #expect(try f.harness.plan().succeeded)
    try paths.herdrAppValidateOwnership(f.palette)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.palette.path))
  }

  @Test func failedReceiptPublicationDoesNotReportSuccessAndCanRetry() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = HerdrAppAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [0, 1, 14] }, validateOwnership: paths.herdrAppValidateOwnership)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night"))
    _ = try ThemeActivator(root: f.state).activate(package: package)
    let receipt = HerdrAppAdapter.publicationReceiptURL(root: f.state)
    try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await adapter.reconciliation().run() }
    #expect(try Data(contentsOf: f.palette) == Data(HerdrAppAdapter.render(package: package).utf8))
    try FileManager.default.removeItem(at: receipt)
    // No receipt was persisted. The validated active render authenticates retry.
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func preHerdrAppGenerationSupportsAdoptionAndReconciliationWithoutMutation() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let current = try ThemeGenerationReader(root: f.state).activeManifest()
    let generation = f.state.appending(path: "generations/\(current.generationID)")
    let manifestURL = generation.appending(path: "manifest.json")
    let artifact = generation.appending(path: HerdrAppAdapter.outputPath)
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: manifestURL)) as? [String: Any])
    var versions = try #require(object["renderer_versions"] as? [String: Int])
    var artifacts = try #require(object["artifacts"] as? [String: String])
    versions.removeValue(forKey: HerdrAppAdapter.id)
    artifacts.removeValue(forKey: HerdrAppAdapter.outputPath)
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
      try ThemeGenerationReader(root: f.state).activeManifest().rendererVersions["herdr-app"] == nil
    )
    #expect(try f.harness.plan().succeeded)
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let adapter = HerdrAppAdapter(
      root: f.state, configurationDirectory: f.settings.deletingLastPathComponent(),
      version: { [0, 1, 14] }, validateOwnership: paths.herdrAppValidateOwnership)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
    #expect(try Data(contentsOf: f.palette) == Data(HerdrAppAdapter.render(package: package).utf8))
    #expect(try Data(contentsOf: manifestURL) == legacyData)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(
      try ThemeGenerationReader(root: f.state).activeManifest().generationID == current.generationID
    )
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func rollbackRestoresBothFilesAfterAuthorityPublicationFailure() async throws {
    let original =
      "{\"theme\": {\"mode\": \"system\", \"light\": \"A\", \"dark\": \"B\"}}\n"
    let f = try Fixture(original: original)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let digest = try jsonObject(f.harness.plan().output)["adoption_evidence_digest"] as? String
    let result = try await f.apply(adopt: digest, fault: { _ in throw Injected.failure })
    #expect(!result.succeeded)
    #expect(try Data(contentsOf: f.settings) == Data(original.utf8))
    #expect(!FileManager.default.fileExists(atPath: f.palette.path))
    #expect(try EnvironmentStateStore(stateRoot: f.state).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: f.state).readTransaction() == nil)
  }

  @Test func overriddenConsumerHomeCannotRedirectTheOwnedPaletteWrite() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.apply().succeeded)
    let paths = try ThemeRuntimeSelection.consumerPaths(stateRoot: f.state, consumerPaths: f.paths)
    let other = f.home.appending(path: "other/herdrApp")
    let target = other.appending(path: "themes/macarchy-current.json")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("unowned".utf8)
    try original.write(to: target)
    let adapter = HerdrAppAdapter(
      root: f.state, configurationDirectory: other, version: { [0, 1, 14] },
      validateOwnership: paths.herdrAppValidateOwnership)
    let result = try await adapter.reconciliation().run()
    #expect(result.status == .drifted)
    #expect(try Data(contentsOf: target) == original)
    #expect(try await f.harness.teardown(consumerPaths: f.paths).succeeded)
  }

  @Test func enablementRequiresSupportedAppButDisablementDoesNot() async throws {
    let f = try Fixture(original: nil)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let old = PresetLifecycleTestHarness(
      profile: f.profile, state: f.state, home: f.home, herdrAppVersion: { [0, 1, 13] })
    #expect(try !old.plan().succeeded)
    let missing = PresetLifecycleTestHarness(
      profile: f.profile, state: f.state, home: f.home, herdrAppVersion: { throw Injected.failure })
    #expect(try !missing.plan().succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    #expect(try await f.apply().succeeded)
    try presetTestProfile(presets: ["herdr_app": false]).write(
      to: f.profile, atomically: true, encoding: .utf8)
    #expect(try await f.apply(version: { throw Injected.failure }).succeeded)
    #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    #expect(!FileManager.default.fileExists(atPath: f.palette.path))
  }

  @Test func replacementNamesSurviveThePersistedTransaction() throws {
    let names = EnvironmentReplacementNames([
      .herdrApp: ".herdr-app-settings-test", .herdrAppPalette: ".herdr-app-palette-test",
    ])
    let transaction = EnvironmentTransaction(
      operation: .apply, previousOwnership: nil, proposedOwnership: nil,
      previousCurrentDestination: nil, replacementNames: names)
    let decoded = try JSONDecoder().decode(
      EnvironmentTransaction.self, from: JSONEncoder().encode(transaction))
    #expect(decoded.replacementNames == names)
  }

  private enum Injected: Error { case failure }

  @Test func oversizedEditsAreRefusedBeforePublication() throws {
    let url = URL(filePath: "/home/test/.config/herdr-app/settings.json")
    let empty =
      Data("{".utf8) + Data(repeating: 32, count: BoundedRegularFile.maximumSize - 2)
      + Data("}".utf8)
    #expect(throws: EnvironmentLifecycleError.self) {
      try EnvironmentHerdrAppOwnership.managed(from: empty, at: url)
    }
    let member = Data(EnvironmentHerdrAppOwnership.managedMember)
    let full =
      Data("{".utf8) + member
      + Data(repeating: 32, count: BoundedRegularFile.maximumSize - member.count - 2)
      + Data("}".utf8)
    let original = Data(#""theme": {"mode": "system", "light": "A", "dark": "B"}"#.utf8)
    let owner = EnvironmentHerdrAppOwnership(
      path: url.path, originalFileExisted: true, originalMember: original)
    #expect(throws: EnvironmentLifecycleError.self) { try owner.restored(in: full, at: url) }
  }

  private struct Fixture {
    let root: URL
    let home: URL
    let state: URL
    let profile: URL
    var settings: URL { home.appending(path: ".config/herdr-app/settings.json") }
    var palette: URL { home.appending(path: ".config/herdr-app/themes/macarchy-current.json") }
    var harness: PresetLifecycleTestHarness { .init(profile: profile, state: state, home: home) }
    var paths: ThemeConsumerPaths {
      var paths = testConsumerPaths()
      paths.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      paths.starshipConfigurationURL = home.appending(path: ".config/starship.toml")
      return paths
    }
    init(original: String?) throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "herdrApp-preset-\(UUID().uuidString)")
      home = root.appending(path: "home")
      state = home.appending(path: ".config/macarchy")
      profile = root.appending(path: "profile.toml")
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      if let original {
        try FileManager.default.createDirectory(
          at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: settings)
      }
      try presetTestProfile(presets: ["herdr_app": true]).write(
        to: profile, atomically: true, encoding: .utf8)
      try activateCatppuccinMocha(stateRoot: state)
    }
    func apply(
      adopt: String? = nil,
      version: @escaping @Sendable () throws -> [Int] = { [0, 1, 14] },
      fault: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
    ) async throws -> (output: String, succeeded: Bool) {
      try await harness.apply(
        runner: EnvironmentApplyCommandRunner(
          prerequisites: .assumed,
          theme: stubThemeController(
            reconciled: ("applied", "HerdrApp reloaded"), inspected: ("ready", "HerdrApp ready")),
          verifier: .assumed, herdrAppVersion: version, transactionFaultInjector: fault),
        consumerPaths: paths, adopt: adopt)
    }
  }
}
