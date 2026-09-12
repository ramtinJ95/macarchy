import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentAtuinMigrationTests {
  private let nativeSettings =
    "# personal settings\nsearch_mode = \"prefix\"\n[theme]\nname = \"macarchy-current\"\n"

  @Test(arguments: [false, true])
  func nativeSourceCanBeConnectedAtFirstApplyOrReviewedMigration(existing: Bool) async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    if existing {
      let approval = try #require(
        jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String)
      #expect(try await fixture.apply(adopt: approval).succeeded)
    }
    let source = fixture.root.appending(path: "personal-atuin.toml")
    let connection = fixture.root.appending(path: "linked-atuin.toml")
    try nativeSettings.write(to: source, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: connection, withDestinationURL: source)
    let profile = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (profile + "\n[atuin]\nnative_configuration = \"linked-atuin.toml\"\n").write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    if existing {
      let blocked = try fixture.plan()
      #expect(!blocked.succeeded)
      #expect(blocked.output.contains("migrate-atuin --source"))
      let migration = EnvironmentNativeFileMigration(
        provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state,
        sourceURL: connection)
      let (plan, old) = try migration.plan()
      let unrelatedBefore = try unrelated(fixture)
      let coordinator = EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state)
      try (nativeSettings + "# changed after review\n").write(
        to: source, atomically: true, encoding: .utf8)
      #expect(throws: (any Error).self) {
        try coordinator.migrateNativeFileLocked(
          provider: .atuin, approval: plan.approval, sourceURL: connection)
      }
      #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == old)
      let (reviewed, _) = try migration.plan()
      _ = try coordinator.migrateNativeFileLocked(
        provider: .atuin, approval: reviewed.approval, sourceURL: connection)
      #expect(try unrelated(fixture) == unrelatedBefore)
    }
    let plan = try fixture.plan()
    #expect(plan.succeeded, "\(plan.output)")
    #expect(try jsonObject(plan.output)["atuin_configuration"] as? String == connection.path)
    let result = try await fixture.apply(
      adopt: jsonObject(plan.output)["adoption_evidence_digest"] as? String)
    #expect(result.succeeded, "\(result.output)")
    let generation = try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination()
    let edited = nativeSettings + "# edited natively\n"
    try edited.write(to: source, atomically: true, encoding: .utf8)
    let repeated = try await fixture.apply(adopt: nil)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == generation)
    #expect(try fixture.status().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == edited)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: connection.path) == source.path)
  }

  @Test(arguments: ["missing", "selector", "conflict", "state", "public-alias"])
  func nativeSourcesRejectMissingConflictingAndManagedInputs(kind: String) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var source = fixture.root.appending(path: "source.toml")
    if kind == "state" {
      source = fixture.state.appending(path: "source.toml")
      try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
    }
    if kind == "public-alias" {
      try nativeSettings.write(to: fixture.zshEntry, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: fixture.zshEntry)
    } else if kind != "missing" {
      try (kind == "selector" ? "[theme]\nname = \"personal\"\n" : nativeSettings).write(
        to: source, atomically: true, encoding: .utf8)
    }
    let profile = try String(contentsOf: fixture.profile, encoding: .utf8)
    let path = kind == "state" ? "home/.config/macarchy/source.toml" : "source.toml"
    try
      (profile + "\n[atuin]\nnative_configuration = \"\(path)\"\n"
      + (kind == "conflict" ? "search_mode = \"prefix\"\n" : "")).write(
        to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(!(try fixture.plan().succeeded))
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  private func fixture() async throws -> EnvironmentLifecycleFixture {
    let fixture = try EnvironmentLifecycleFixture()
    let plan = try jsonObject(fixture.plan().output)
    let approval = try #require(plan["adoption_evidence_digest"] as? String)
    let applied = try await fixture.apply(adopt: approval)
    #expect(applied.succeeded, "\(applied.output)")
    return fixture
  }

  private func unrelated(_ fixture: EnvironmentLifecycleFixture) throws
    -> [EnvironmentEntryEvidence]
  {
    try [
      ".zshrc", ".config/kitty/kitty.conf", ".config/nvim", ".config/macarchy/environment/current",
      ".config/atuin/themes/macarchy-current.toml",
    ].map {
      try EnvironmentProviderInspector().capture(
        fixture.home.appending(path: $0), directoryLink: nil)
    }
  }

  @Test
  func migrateEditReapplyThemeAndTeardownPreserveNativeSettings() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let before = try unrelated(fixture)
    let seed = try Data(contentsOf: migration.publicURL)
    #expect(!FileManager.default.fileExists(atPath: migration.nativeURL.path))
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateAtuinLocked(approval: plan.approval)
    #expect(try unrelated(fixture) == before)
    #expect(try Data(contentsOf: migration.nativeURL) == seed)
    let edited =
      "# personal edits\nsearch_mode = \"prefix\"\n[theme]\nname = \"macarchy-current\"\n"
    try edited.write(to: migration.nativeURL, atomically: true, encoding: .utf8)
    try fixture.activateTheme()
    let adapter = AtuinAdapter(
      root: fixture.state,
      configurationDirectoryURL: migration.publicURL.deletingLastPathComponent(),
      executableURL: URL(filePath: "/fixture/atuin"), controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
      })
    #expect(adapter.inspection().status == .ready)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let next = try await fixture.apply(adopt: nil)
    #expect(next.succeeded, "\(next.output)")
    #expect(try fixture.status().succeeded)
    #expect(try fixture.plan().output.contains(migration.nativeURL.path))
    #expect(try Data(contentsOf: migration.nativeURL) == Data(edited.utf8))
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
        == old.replacingTarget(for: .atuinConfiguration, with: migration.nativeURL.path))
    #expect(try await fixture.teardown().succeeded)
    #expect(try Data(contentsOf: migration.nativeURL) == Data(edited.utf8))
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryIsAtuinOnly(rollback: Bool, switched: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (_, old) = try migration.plan()
    let new = old.replacingTarget(for: .atuinConfiguration, with: migration.nativeURL.path)
    let before = try unrelated(fixture)
    try migration.seed(old)
    if switched { try migration.transition(from: old, to: new) }
    let journal = EnvironmentTransaction(
      operation: .atuinMigration, previousOwnership: old, proposedOwnership: new,
      previousCurrentDestination: "generations/\(old.generationID)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(rollback ? journal.rollingBack : journal)
    #expect(
      try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
        .recoverLocked())
    #expect(try store.readOwnership() == (rollback ? old : new))
    #expect(!store.transactionExists)
    #expect(try unrelated(fixture) == before)
    try migration.validateNativeFile()
  }

  @Test(arguments: [false, true], [false, true])
  func externalSourceRecoveryIsAtuinOnly(rollback: Bool, switched: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let seeded = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (seedPlan, _) = try seeded.plan()
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateAtuinLocked(approval: seedPlan.approval)
    let source = fixture.root.appending(path: "external.toml")
    try nativeSettings.write(to: source, atomically: true, encoding: .utf8)
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: source)
    let (_, old) = try migration.plan()
    let new = old.replacingTarget(for: .atuinConfiguration, with: source.path)
    let before = try unrelated(fixture)
    if switched { try migration.transition(from: old, to: new) }
    let journal = EnvironmentTransaction(
      operation: .atuinMigration, previousOwnership: old, proposedOwnership: new,
      previousCurrentDestination: "generations/\(old.generationID)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(rollback ? journal.rollingBack : journal)
    #expect(
      try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
        .recoverLocked())
    #expect(try store.readOwnership() == (rollback ? old : new))
    #expect(try unrelated(fixture) == before)
    #expect(try String(contentsOf: source, encoding: .utf8) == nativeSettings)
  }

  @Test
  func staleApprovalDestinationConflictAndForgedJournalAreRejected() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) { try coordinator.migrateAtuinLocked(approval: "stale") }
    #expect(!FileManager.default.fileExists(atPath: migration.nativeURL.path))
    try FileManager.default.createSymbolicLink(
      atPath: migration.nativeURL.path, withDestinationPath: "missing")
    #expect(throws: (any Error).self) {
      try coordinator.migrateAtuinLocked(approval: plan.approval)
    }
    let forged = old.replacingTarget(for: .atuinConfiguration, with: migration.nativeURL.path)
      .replacingTarget(for: .zsh, with: "/unexpected")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .atuinMigration, previousOwnership: old, proposedOwnership: forged,
        previousCurrentDestination: "generations/\(old.generationID)"))
    #expect(throws: (any Error).self) { try store.readTransaction() }
    #expect(try store.readOwnership() == old)
  }

  @Test
  func failedCutoverKeepsSeedAndRestoresOnlyAtuin() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let before = try unrelated(fixture)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state,
      faultInjector: { _ in throw EnvironmentLifecycleError.blocked("injected") })
    #expect(throws: (any Error).self) {
      try coordinator.migrateAtuinLocked(approval: plan.approval)
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(try store.readOwnership() == old)
    #expect(!store.transactionExists)
    #expect(try unrelated(fixture) == before)
    try migration.validateNativeFile()
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_ATUIN_CONFIG"] == "1"),
    arguments: [false, true])
  func installedAtuinReadsMigratedSettingsAndThemeSelector(external: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "external-atuin.toml")
    if external { try nativeSettings.write(to: source, atomically: true, encoding: .utf8) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state,
      sourceURL: external ? source : nil)
    let (plan, _) = try migration.plan()
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateNativeFileLocked(
        provider: .atuin, approval: plan.approval, sourceURL: external ? source : nil)
    try fixture.activateTheme()
    let adapter = AtuinAdapter(
      root: fixture.state,
      configurationDirectoryURL: migration.publicURL.deletingLastPathComponent(),
      executableURL: AtuinAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: AtuinAdapter.liveExecutableURL.path)
      },
      processRunner: .live)
    let result = try await adapter.reconciliation().run()
    #expect(result.status == .applied, "\(result)")
  }

  @Test
  func changedThemeSelectionIsDriftNotOverwritePermission() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .atuin, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, _) = try migration.plan()
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateAtuinLocked(approval: plan.approval)
    let edited = "[theme]\nname = \"personal\"\n"
    try edited.write(to: migration.nativeURL, atomically: true, encoding: .utf8)
    #expect(!(try fixture.status().succeeded))
    #expect(!(try await fixture.apply(adopt: nil).succeeded))
    #expect(try String(contentsOf: migration.nativeURL, encoding: .utf8) == edited)
  }
}
