import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HerdrPresetLifecycleTests {
  @Test
  func versionAndReloadContractsAreStrictAndHaveNoUpperCap() throws {
    #expect(HerdrAdapter.parseVersion("herdr 0.8.0") == [0, 8, 0])
    #expect(HerdrAdapter.parseVersion("herdr 99.1.2\n") == [99, 1, 2])
    #expect(HerdrAdapter.parseVersion("0.8.0") == nil)
    #expect(HerdrAdapter.parseVersion("herdr 0.8") == nil)
    #expect(HerdrAdapter.parseVersion("herdr 0.8.0-beta") == nil)
    #expect(
      HerdrAdapter.reloadResponseIsUnambiguousSuccess(
        #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"status":"applied","type":"config_reload"}}"#
      )
    )
    for rejected in [
      "",
      #"{"status":"applied","diagnostics":[]}"#,
      #"{"status":"partial","diagnostics":[]}"#,
      #"{"status":"applied","diagnostics":["disabled keys.split"]}"#,
      #"{"status":"applied","diagnostics":[],"extra":true}"#,
      #"{"id":"cli:server:reload-config","result":{"diagnostics":["warning"],"status":"applied","type":"config_reload"}}"#,
      #"{"id":"cli:other","result":{"diagnostics":[],"status":"applied","type":"config_reload"}}"#,
      #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"status":"applied","type":"other"}}"#,
      #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"status":"applied","type":"config_reload","extra":true}}"#,
      #"{"id":"cli:server:reload-config","result":{"diagnostics":{},"status":"applied","type":"config_reload"}}"#,
      #"{"id":"other","id":"cli:server:reload-config","result":{"diagnostics":[],"status":"applied","type":"config_reload"}}"#,
      #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"status":"partial","status":"applied","type":"config_reload"}}"#,
    ] {
      #expect(!HerdrAdapter.reloadResponseIsUnambiguousSuccess(rejected))
    }

    #expect(try versionAdapter("herdr 0.8.0").supportedVersion() == "0.8.0")
    #expect(try versionAdapter("herdr 20.0.0").supportedVersion() == "20.0.0")
    #expect(throws: HerdrAdapterError.self) {
      _ = try versionAdapter("herdr 0.7.9").supportedVersion()
    }
  }

  @Test
  func cleanEnableNoOpDisableAndTeardownPublishAppliedAuthority() throws {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let first = try fixture.apply(enabled: true)
    #expect(first.changed)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "[theme]\nname = \"catppuccin\"\n"
    )
    var ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(ownership.herdrEnabled)
    #expect(ownership.enabledThemeAdapterIDs == [HerdrAdapter.id])
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == [HerdrAdapter.id]
    )

    #expect(try !fixture.apply(enabled: true).changed)
    #expect(try fixture.apply(enabled: false).changed)
    #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(!ownership.herdrEnabled)
    #expect(ownership.enabledThemeAdapterIDs == [])
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(HerdrAdapter.id)
    )

    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home,
      stateRoot: fixture.state
    )
    let teardown = try coordinator.teardownLocked(dryRun: false)
    #expect(teardown.changed)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test
  func reviewedOrdinaryAdoptionPreservesProviderRewritesAndExactSelectorBoundary() throws {
    let original =
      "onboarding = false\n[theme]\n  name = \"personal\" # keep\n"
      + "auto_switch = false\n[terminal]\nshell_mode = \"auto\"\n"
    let fixture = try HerdrFixture(configuration: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let inspection = try fixture.inspection(enabled: true)
    let digest = try #require(inspection.adoptionEvidenceDigest)
    _ = try fixture.apply(enabled: true, inspection: inspection, adoptionDigest: digest)
    var managed = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(managed.contains("  name = \"catppuccin\" # keep"))

    managed = managed.replacingOccurrences(
      of: "onboarding = false",
      with: "onboarding = true # provider rewrite"
    )
    try managed.write(to: fixture.configuration, atomically: true, encoding: .utf8)
    _ = try fixture.apply(enabled: false)
    let restored = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(restored.contains("onboarding = true # provider rewrite"))
    #expect(restored.contains("  name = \"personal\" # keep"))
    #expect(restored.contains("shell_mode = \"auto\""))
  }

  @Test
  func importedThemeOwnsAndRemovesExactlyTheEstablishedSixteenCustomKeys() throws {
    let fixture = try HerdrFixture(
      configuration: "[theme]\nname = \"personal\"\n",
      importedPalette: true
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let inspection = try fixture.inspection(enabled: true)
    _ = try fixture.apply(
      enabled: true,
      inspection: inspection,
      adoptionDigest: inspection.adoptionEvidenceDigest
    )
    let managed = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(managed.contains("[theme.custom]"))
    #expect(HerdrAdapter.customKeys.count == 16)
    for key in HerdrAdapter.customKeys {
      #expect(managed.contains("\n\(key) = \""))
    }
    #expect(!managed.contains("user_message_bg"))
    #expect(!managed.contains("assistant_message_bg"))
    #expect(!managed.contains("tool_message_bg"))

    _ = try fixture.apply(enabled: false)
    let restored = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(restored == "[theme]\nname = \"personal\"\n")
  }

  @Test
  func commandEnableOfImportedThemeAndFollowingThemeSetStayUnderAggregateAuthority() async throws {
    let fixture = try HerdrFixture(
      configuration: "[theme]\nname = \"personal\"\n",
      importedPalette: true
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let inspection = try fixture.inspection(enabled: true)
    let reloads = Mutex(0)
    let runtime = EnvironmentHerdrRuntimeReloader { _, _ in
      reloads.withLock { $0 += 1 }
      return "Herdr reloaded the active configuration"
    }

    let apply = try await fixture.commandApply(
      enabled: true,
      adopt: inspection.adoptionEvidenceDigest,
      runtime: runtime
    )
    #expect(apply.succeeded)
    #expect(reloads.withLock { $0 } == 1)

    let result = try await fixture.themeSetRunner(runtime: runtime).execute(
      repository: ThemeRepository(
        builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
      ),
      themeID: "tokyo-night",
      stateRoot: fixture.state,
      consumerPaths: fixture.consumerPaths,
      dryRun: false,
      json: true
    )
    #expect(result.succeeded)
    #expect(reloads.withLock { $0 } == 2)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8).contains(
        "name = \"tokyo-night\""
      )
    )
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.herdr
    )
    #expect(ownership.managedTheme.name == "tokyo-night")
    #expect(ownership.managedTheme.custom.isEmpty)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "state/adapters/herdr-theme-ownership.json").path
      )
    )
  }

  @Test
  func disableRetainsProviderAdditionsToAnIntroducedConfiguration() throws {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.apply(enabled: true)
    var configuration = try String(contentsOf: fixture.configuration, encoding: .utf8)
    configuration += "\nonboarding = true\n[terminal]\nshell_mode = \"auto\"\n"
    try configuration.write(to: fixture.configuration, atomically: true, encoding: .utf8)

    _ = try fixture.apply(enabled: false)

    let restored = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(restored.contains("onboarding = true"))
    #expect(restored.contains("shell_mode = \"auto\""))
    #expect(!restored.contains("name ="))
    #expect(!restored.contains("[theme.custom]"))
  }

  @Test
  func reviewedHerdrDirectorySymlinkKeepsLexicalInodeAndTargetWhileReplacingTargetFile()
    throws
  {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let dotfiles = fixture.home.appending(path: "dotfiles/herdr", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appending(path: "config.toml")
    try "[theme]\nname = \"personal\"\n".write(
      to: target,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: fixture.configuration.deletingLastPathComponent().deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.configuration.deletingLastPathComponent(),
      withDestinationURL: dotfiles
    )
    let linkBefore = try metadata(fixture.configuration.deletingLastPathComponent())
    let destinationBefore = try FileManager.default.destinationOfSymbolicLink(
      atPath: fixture.configuration.deletingLastPathComponent().path
    )
    let targetBefore = try metadata(target)

    let inspection = try fixture.inspection(enabled: true)
    let digest = try #require(inspection.adoptionEvidenceDigest)
    _ = try fixture.apply(enabled: true, inspection: inspection, adoptionDigest: digest)
    #expect(try metadata(fixture.configuration.deletingLastPathComponent()) == linkBefore)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.configuration.deletingLastPathComponent().path
      ) == destinationBefore
    )
    #expect(try metadata(target).inode != targetBefore.inode)
    #expect(try metadata(target).mode == targetBefore.mode)

    _ = try fixture.apply(enabled: false)
    #expect(try String(contentsOf: target, encoding: .utf8) == "[theme]\nname = \"personal\"\n")
    #expect(try metadata(fixture.configuration.deletingLastPathComponent()) == linkBefore)
    #expect(try metadata(target).mode == targetBefore.mode)
  }

  @Test
  func authenticatedLegacyJournalMigratesAndRestoresItsCatppuccinOriginal() throws {
    let fixture = try HerdrFixture(
      configuration: "[theme]\nname = \"tokyo-night\"\n",
      theme: "tokyo-night"
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = "[theme]\nname = \"catppuccin\" # original\n"
    let adapters = fixture.state.appending(path: "state/adapters")
    try FileManager.default.createDirectory(at: adapters, withIntermediateDirectories: true)
    try original.write(
      to: adapters.appending(path: "herdr-config.toml.backup"),
      atomically: true,
      encoding: .utf8
    )
    let journal: [String: Any] = [
      "schema_version": 1,
      "desired": ["name": "tokyo-night", "custom": [:]],
      "backup_digest": sha256Digest(Data(original.utf8)),
    ]
    try JSONSerialization.data(withJSONObject: journal).write(
      to: adapters.appending(path: "herdr-theme-ownership.json"),
      options: .atomic
    )

    let inspection = try fixture.inspection(enabled: true)
    #expect(inspection.adoptionEvidenceDigest == nil)
    #expect(
      inspection.entries.first { $0.id == "herdr_configuration" }?.status == .migrationRequired)
    _ = try fixture.apply(enabled: true, inspection: inspection)

    let managedOwnership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.herdr
    )
    #expect(managedOwnership.migratedLegacy)

    _ = try fixture.apply(enabled: false)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == original)
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.herdr?.migratedLegacy
        == true
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: adapters.appending(path: "herdr-theme-ownership.json").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: adapters.appending(path: "herdr-config.toml.backup").path
      )
    )
  }

  @Test
  func legacyMigrationRollbackRestoresTheAuthenticatedManagedState() throws {
    let fixture = try HerdrFixture(
      configuration: "[theme]\nname = \"tokyo-night\"\n",
      theme: "tokyo-night"
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = "[theme]\nname = \"catppuccin\" # original\n"
    let adapters = fixture.state.appending(path: "state/adapters")
    try FileManager.default.createDirectory(at: adapters, withIntermediateDirectories: true)
    try original.write(
      to: adapters.appending(path: "herdr-config.toml.backup"),
      atomically: true,
      encoding: .utf8
    )
    try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 1,
        "desired": ["name": "tokyo-night", "custom": [:]],
        "backup_digest": sha256Digest(Data(original.utf8)),
      ]
    ).write(
      to: adapters.appending(path: "herdr-theme-ownership.json"),
      options: .atomic
    )
    let inspection = try fixture.inspection(enabled: true)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home,
      stateRoot: fixture.state
    )
    _ = try coordinator.applyLocked(
      composition: fixture.composition(enabled: true),
      inspection: inspection,
      adoptionDigest: nil,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )

    try coordinator.rollbackApplyLocked()

    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "[theme]\nname = \"tokyo-night\"\n"
    )
    let transaction = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readTransaction()
    )
    #expect(transaction.direction == .rollback)
    #expect(transaction.herdrLegacyMigration == true)
    #expect(transaction.proposedOwnership?.herdr?.migratedLegacy == true)
    #expect(transaction.herdrRuntimeTarget == .managed)
    try coordinator.markHerdrRuntimeVerifiedLocked(.managed)
    _ = try coordinator.prepareRecoveryLocked()
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(
      try HerdrAdapter(
        root: fixture.state,
        configurationURL: fixture.configuration,
        executableURL: fixture.home.appending(path: ".local/bin/herdr"),
        controlIsAvailable: { true }
      ).legacyOwnershipEvidence() != nil
    )
  }

  @Test
  func malformedCustomConflictAndStaleEvidenceBlockBeforeMutation() throws {
    for text in [
      "[theme\nname = \"catppuccin\"\n",
      "[theme]\nname = \"catppuccin\"\nauto_switch = true\n",
      "[theme]\nname = \"catppuccin\"\n[theme.custom]\naccent = \"#ffffff\"\n",
    ] {
      let fixture = try HerdrFixture(configuration: text)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      #expect(try fixture.inspection(enabled: true).isBlocked)
      #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == text)
    }

    let fixture = try HerdrFixture(configuration: "[theme]\nname = \"personal\"\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let inspection = try fixture.inspection(enabled: true)
    let digest = try #require(inspection.adoptionEvidenceDigest)
    try "[theme]\nname = \"changed\"\n".write(
      to: fixture.configuration,
      atomically: true,
      encoding: .utf8
    )
    #expect(throws: EnvironmentLifecycleError.self) {
      _ = try fixture.apply(
        enabled: true,
        inspection: inspection,
        adoptionDigest: digest
      )
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test
  func interruptedDisableAndTeardownRequireRuntimeVerificationBeforeCleanup() throws {
    let disable = try HerdrFixture(configuration: "[theme]\nname = \"personal\"\n")
    defer { try? FileManager.default.removeItem(at: disable.root) }
    let enabledInspection = try disable.inspection(enabled: true)
    _ = try disable.apply(
      enabled: true,
      inspection: enabledInspection,
      adoptionDigest: enabledInspection.adoptionEvidenceDigest
    )
    let disableCoordinator = EnvironmentTransactionCoordinator(
      homeDirectory: disable.home,
      stateRoot: disable.state
    )
    _ = try disableCoordinator.applyLocked(
      composition: disable.composition(enabled: false),
      inspection: disable.inspection(enabled: false),
      adoptionDigest: nil,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    #expect(try disableCoordinator.prepareRecoveryLocked().runtimeTarget == .original)
    #expect(EnvironmentStateStore(stateRoot: disable.state).transactionExists)
    try disableCoordinator.markHerdrRuntimeVerifiedLocked(.original)
    _ = try disableCoordinator.prepareRecoveryLocked()
    #expect(
      try EnvironmentStateStore(stateRoot: disable.state).readOwnership()?.herdrEnabled == false
    )

    let teardown = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: teardown.root) }
    _ = try teardown.apply(enabled: true)
    let teardownCoordinator = EnvironmentTransactionCoordinator(
      homeDirectory: teardown.home,
      stateRoot: teardown.state
    )
    _ = try teardownCoordinator.teardownLocked(dryRun: false)
    #expect(try teardownCoordinator.prepareRecoveryLocked().runtimeTarget == .original)
    #expect(EnvironmentStateStore(stateRoot: teardown.state).transactionExists)
    try teardownCoordinator.markHerdrRuntimeVerifiedLocked(.original)
    _ = try teardownCoordinator.prepareRecoveryLocked()
    #expect(try EnvironmentStateStore(stateRoot: teardown.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: teardown.state).transactionExists)
  }

  @Test
  func disableRollbackReloadFailureRetainsActionableTransaction() async throws {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.apply(enabled: true)
    let reloads = Mutex(0)
    let result = try await fixture.commandApply(
      enabled: false,
      runtime: EnvironmentHerdrRuntimeReloader { _, _ in
        reloads.withLock { $0 += 1 }
        throw EnvironmentLifecycleError.blocked("partial Herdr reload")
      }
    )

    #expect(!result.succeeded)
    #expect(reloads.withLock { $0 } == 2)
    let transaction = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readTransaction()
    )
    #expect(transaction.direction == .rollback)
    #expect(transaction.herdrRuntimeTarget == .managed)
    #expect(transaction.herdrRuntimeVerified != true)
    #expect(result.output.contains("recovery_required"))
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "[theme]\nname = \"catppuccin\"\n"
    )
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.herdrEnabled == true
    )
    #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  @Test
  func interruptedTeardownCommandReloadsBeforeRemovingAuthority() async throws {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.apply(enabled: true)
    _ = try EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home,
      stateRoot: fixture.state
    ).teardownLocked(dryRun: false)
    let reloads = Mutex(0)

    let result = try await EnvironmentTeardownCommandRunner(
      herdrRuntime: EnvironmentHerdrRuntimeReloader { _, _ in
        let ownership = try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
        #expect(ownership != nil)
        reloads.withLock { $0 += 1 }
        return "Herdr restored"
      }
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )

    #expect(result.succeeded)
    #expect(reloads.withLock { $0 } == 1)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
  }

  @Test
  func teardownReportsTheStoppedServerNextLaunchBoundary() async throws {
    let fixture = try HerdrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.apply(enabled: true)
    let reloads = Mutex(0)
    let result = try await EnvironmentTeardownCommandRunner(
      herdrRuntime: EnvironmentHerdrRuntimeReloader { _, _ in
        reloads.withLock { $0 += 1 }
        return "Herdr will use the active configuration on next launch"
      }
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      consumerPaths: testConsumerPaths(),
      dryRun: false,
      json: true
    )

    #expect(result.succeeded)
    #expect(reloads.withLock { $0 } == 1)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    )
    let theme = try #require(report["theme"] as? [[String: Any]])
    #expect(theme.first?["adapter_id"] as? String == HerdrAdapter.id)
    #expect(
      theme.first?["message"] as? String
        == "Herdr will use the active configuration on next launch"
    )
  }

  private func versionAdapter(_ output: String) -> HerdrAdapter {
    HerdrAdapter(
      root: URL(filePath: "/tmp/state"),
      configurationURL: URL(filePath: "/tmp/herdr/config.toml"),
      executableURL: URL(filePath: "/tmp/herdr"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 0, output: output)
      }
    )
  }
}

private struct HerdrFixture {
  let root: URL
  let home: URL
  let state: URL
  let configuration: URL

  init(
    configuration contents: String?,
    theme: String = "catppuccin-mocha",
    importedPalette: Bool = false
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-herdr-preset-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    configuration = home.appending(path: ".config/herdr/config.toml")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if let contents {
      try FileManager.default.createDirectory(
        at: configuration.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: configuration, atomically: true, encoding: .utf8)
    }
    let packageID = theme == "tokyo-night" ? "tokyo-night" : theme
    let loadedPackage = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(packageID)")
    )
    let package =
      importedPalette
      ? ThemePackage(
        packageURL: loadedPackage.packageURL,
        schemaVersion: loadedPackage.schemaVersion,
        id: loadedPackage.id,
        displayName: loadedPackage.displayName,
        appearance: loadedPackage.appearance,
        semantic: loadedPackage.semantic,
        terminal: loadedPackage.terminal,
        backgrounds: loadedPackage.backgrounds,
        backgroundData: loadedPackage.backgroundData,
        mappings: [:]
      ) : loadedPackage
    _ = try ThemeActivator(root: state).activate(package: package)
  }

  func inspection(enabled: Bool) throws -> EnvironmentProviderInspection {
    let composition = try composition(enabled: enabled)
    return EnvironmentProviderInspector().inspect(
      composition: composition,
      homeDirectory: home,
      stateRoot: state
    )
  }

  func apply(
    enabled: Bool,
    inspection supplied: EnvironmentProviderInspection? = nil,
    adoptionDigest: String? = nil
  ) throws -> (changed: Bool, generationID: String) {
    let composition = try composition(enabled: enabled)
    let inspection =
      supplied
      ?? EnvironmentProviderInspector().inspect(
        composition: composition,
        homeDirectory: home,
        stateRoot: state
      )
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: home,
      stateRoot: state
    )
    let result = try coordinator.applyLocked(
      composition: composition,
      inspection: inspection,
      adoptionDigest: adoptionDigest,
      themeBridges: EnvironmentThemeBridgeState(entries: [])
    )
    if let target = try coordinator.pendingHerdrRuntimeTargetLocked() {
      try coordinator.markHerdrRuntimeVerifiedLocked(target)
    }
    try coordinator.finishApplyLocked(composition: composition)
    return result
  }

  func commandApply(
    enabled: Bool,
    adopt: String? = nil,
    runtime: EnvironmentHerdrRuntimeReloader
  ) async throws -> (output: String, succeeded: Bool) {
    let profile = try writeProfile(enabled: enabled)
    return try await EnvironmentApplyCommandRunner(
      prerequisites: .assumed,
      theme: DesktopThemeController(
        reconcile: { adapterIDs, stateRoot, _ in
          DesktopThemeReconciliation(
            generationID: try ReconciliationStatusStore(root: stateRoot).activeManifest()
              .generationID,
            results: adapterIDs.map {
              DesktopThemeAdapterStatus(
                adapterID: $0,
                requirement: "required",
                status: "applied",
                message: "test reconciliation"
              )
            },
            succeeded: true
          )
        },
        inspect: { _, _, _ in [] }
      ),
      verifier: .assumed,
      herdrRuntime: runtime
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      adopt: adopt,
      json: true
    )
  }

  func themeSetRunner(runtime: EnvironmentHerdrRuntimeReloader) -> ThemeSetCommandRunner {
    let makeCoordinator: @Sendable () throws -> ThemeActivationCoordinator = {
      let managedMode = ThemeRuntimeSelection.managedHerdrMode(
        stateRoot: state,
        homeDirectory: home,
        runtime: runtime
      )
      return ThemeActivationCoordinator(
        root: state,
        consumerPaths: consumerPaths,
        processRunner: ProcessRunner { request in
          ProcessResult(
            terminationStatus: 0,
            output: request.arguments == ["--version"] ? "herdr 0.8.2" : ""
          )
        },
        wallpaperControl: WallpaperControl(inspect: { [] }, set: { _, _ in }),
        wallpaperSignal: .personal(homeDirectory: home),
        enabledAdapterIDs: [HerdrAdapter.id],
        herdrManagedMode: managedMode
      )
    }
    return ThemeSetCommandRunner(
      preflight: { package, background, _, _ in
        try makeCoordinator().preflight(package: package, requestedBackgroundID: background)
      },
      activate: { package, background, _, _, expected in
        try await makeCoordinator().activate(
          package: package,
          expectedActiveGenerationID: expected,
          requestedBackgroundID: background
        )
      }
    )
  }

  var consumerPaths: ThemeConsumerPaths {
    let paths = testConsumerPaths()
    return ThemeConsumerPaths(
      kittyConfigurationURL: paths.kittyConfigurationURL,
      sketchyBarConfigurationURL: paths.sketchyBarConfigurationURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      ezaConfigurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      batConfigurationDirectoryURL: paths.batConfigurationDirectoryURL,
      batCacheDirectoryURL: paths.batCacheDirectoryURL,
      btopConfigurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      yaziConfigurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      atuinConfigurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
      neovimConfigurationDirectoryURL: paths.neovimConfigurationDirectoryURL,
      starshipConfigurationURL: paths.starshipConfigurationURL,
      starshipBehaviorURL: paths.starshipBehaviorURL,
      piConfigurationDirectoryURL: home.appending(path: ".pi/agent"),
      herdrConfigurationURL: configuration,
      tuicrConfigurationDirectoryURL: paths.tuicrConfigurationDirectoryURL,
      codexConfigurationDirectoryURL: paths.codexConfigurationDirectoryURL,
      spicetifyConfigurationDirectoryURL: paths.spicetifyConfigurationDirectoryURL
    )
  }

  func composition(enabled: Bool) throws -> EnvironmentComposition {
    let profile = try writeProfile(enabled: enabled)
    return try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: PortableProfileLoader().load(at: profile, required: true),
      stateRoot: state
    )
  }

  private func writeProfile(enabled: Bool) throws -> URL {
    let profile = root.appending(path: "profile-\(enabled).toml")
    try """
    schema_version = 1
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    [editor]
    provider = "disabled"
    [tools]
    bat = false
    eza = false
    btop = false
    yazi = false
    [presets]
    herdr = \(enabled)
    """.write(to: profile, atomically: true, encoding: .utf8)
    return profile
  }
}

private struct HerdrMetadata: Equatable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt32
}

private func metadata(_ url: URL) throws -> HerdrMetadata {
  var value = stat()
  guard lstat(url.path, &value) == 0 else {
    throw EnvironmentLifecycleError.system("inspect Herdr test path", url, errno)
  }
  return HerdrMetadata(
    device: UInt64(value.st_dev),
    inode: UInt64(value.st_ino),
    mode: UInt32(value.st_mode)
  )
}
