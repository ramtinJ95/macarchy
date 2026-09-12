import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentStandardMigrationTests {
  @Test(arguments: [EnvironmentNativeSeed.Provider.zsh, .kitty, .atuin, .starship])
  func originalDotfileLinkSpellingAndRetainedBackupSurvive(provider: EnvironmentNativeSeed.Provider)
    async throws
  {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let approval = try #require(
      jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String)
    #expect(try await fixture.apply(adopt: approval).succeeded)
    try fixture.activateTheme()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let old = try #require(try store.readOwnership())
    let record = try #require(old.records.first { $0.id == provider.entryID })
    let retained = URL(filePath: try #require(record.retainedPath))
    let retainedEvidence = try EnvironmentProviderInspector().capture(retained, directoryLink: nil)
    let originalTarget = try #require(record.original.linkDestination)
    let linked = URL(
      filePath: originalTarget,
      relativeTo: URL(filePath: record.publicPath).deletingLastPathComponent()
    )
    .standardizedFileURL
    let source = provider == .kitty ? linked.appending(path: "kitty.conf") : linked
    let text: String
    switch provider {
    case .kitty:
      text =
        "font_size 19\ninclude " + fixture.state.appending(path: KittyAdapter.bridgePath).path
        + "\n"
    case .atuin:
      text = "search_mode = \"prefix\"\n[theme]\nname = \"macarchy-current\"\n"
    case .starship:
      text = try EnvironmentNativeSeed(
        provider: provider, destination: fixture.root.appending(path: "preview-only"),
        homeDirectory: fixture.home, stateRoot: fixture.state,
        resourcesRoot: repositoryRoot.appending(path: "Environment")
      ).plan().contents
    default: text = "export PERSONAL=kept\n"
    }
    try text.write(to: source, atomically: true, encoding: .utf8)
    let migration = EnvironmentStandardMigration(
      provider: provider, homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: source)
    let (plan, transaction) = try migration.plan()
    #expect(transaction.standardMigration?.linkTarget == originalTarget)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    try (text + "# changed after review\n").write(to: source, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
      try coordinator.migrateStandardLocked(
        provider: provider, sourceURL: source, approval: plan.approval)
    }
    let reviewed = try migration.plan().0
    _ = try coordinator.migrateStandardLocked(
      provider: provider, sourceURL: source, approval: reviewed.approval)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: record.publicPath) == originalTarget
    )
    #expect(
      try EnvironmentProviderInspector().capture(retained, directoryLink: nil) == retainedEvidence)
    #expect(try String(contentsOf: source, encoding: .utf8) == text + "# changed after review\n")
  }

  @Test
  func existingNativeNeovimMoveRecoversItsTemporarySelfLink() async throws {
    let (fixture, prepared) = try await prepared(.neovim)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let native = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: prepared.sourceURL)
    _ = try coordinator.migrateNeovimLocked(
      approval: native.plan().0.approval, sourceURL: prepared.sourceURL)
    let (_, transaction) = try prepared.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(transaction)
    try prepared.transition(transaction)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: prepared.sourceURL.path)
        == prepared.sourceURL.path)
    #expect(try coordinator.recoverLocked())
    #expect(try store.readOwnership() == transaction.proposedOwnership)
    #expect(
      FileManager.default.fileExists(
        atPath: prepared.publicURL.appending(path: "personal.txt").path))
  }

  @Test
  func kittyCleanupResidueRecoversAndUnknownChildrenBlock() async throws {
    let (fixture, migration) = try await prepared(.kitty)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (_, transaction) = try migration.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(transaction)
    try migration.transition(transaction)
    try store.writeOwnership(transaction.proposedOwnership)
    let staging = URL(filePath: transaction.standardMigration!.staging)
    let unknown = staging.appending(path: "personal.conf")
    try "keep me\n".write(to: unknown, atomically: true, encoding: .utf8)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) { try coordinator.recoverLocked() }
    #expect(store.transactionExists)
    #expect(try String(contentsOf: unknown, encoding: .utf8) == "keep me\n")
    try FileManager.default.removeItem(at: unknown)
    try FileManager.default.removeItem(at: staging.appending(path: "kitty.conf"))
    #expect(try coordinator.recoverLocked())
    #expect(!store.transactionExists)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
  }

  private func prepared(_ provider: EnvironmentNativeSeed.Provider) async throws
    -> (EnvironmentLifecycleFixture, EnvironmentStandardMigration)
  {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    try "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n".write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(try await fixture.apply(adopt: nil).succeeded)
    try fixture.activateTheme()
    let personal = fixture.root.appending(path: "personal")
    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    let source = personal.appending(path: provider == .kitty ? "kitty.conf" : provider.rawValue)
    let seed = EnvironmentNativeSeed(
      provider: provider, destination: source, homeDirectory: fixture.home,
      stateRoot: fixture.state,
      resourcesRoot: repositoryRoot.appending(path: "Environment"))
    _ = try seed.seed(approval: seed.plan().approval)
    if provider == .kitty {
      let text = try String(contentsOf: source, encoding: .utf8)
      try (text + "\ninclude " + fixture.state.appending(path: KittyAdapter.bridgePath).path + "\n")
        .write(to: source, atomically: true, encoding: .utf8)
    }
    // This is mutable personal state, not a sealed or recursively enumerated seed.
    if provider == .neovim {
      try "personal lock and plugins\n".write(
        to: source.appending(path: "personal.txt"), atomically: true, encoding: .utf8)
    }
    return (
      fixture,
      EnvironmentStandardMigration(
        provider: provider, homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: source
      )
    )
  }

  @Test(arguments: EnvironmentNativeSeed.Provider.allCases)
  func migrateReapplyAndTeardownPreservePersonalConfiguration(
    provider: EnvironmentNativeSeed.Provider
  ) async throws {
    let (fixture, migration) = try await prepared(provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (plan, transaction) = try migration.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let before = transaction.previousOwnership!
    let pointer = try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination()
    let sourceBytes = provider == .neovim ? nil : try Data(contentsOf: migration.sourceURL)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) {
      try coordinator.migrateStandardLocked(
        provider: provider, sourceURL: migration.sourceURL, approval: "stale")
    }
    #expect(!store.transactionExists)
    _ = try coordinator.migrateStandardLocked(
      provider: provider, sourceURL: migration.sourceURL, approval: plan.approval)
    #expect(try store.readOwnership() == before.releasingStandardEntry(provider.entryID))
    #expect(!store.transactionExists)
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == pointer)
    let standard = provider.standardURL(homeDirectory: fixture.home)
    if provider == .neovim {
      #expect(!FileManager.default.fileExists(atPath: migration.sourceURL.path))
      #expect(
        try String(contentsOf: standard.appending(path: "personal.txt"), encoding: .utf8)
          == "personal lock and plugins\n")
    } else {
      #expect(try Data(contentsOf: standard) == sourceBytes)
      #expect(try Data(contentsOf: migration.sourceURL) == sourceBytes)
    }
    let base = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (base + "\n[\(provider.rawValue)]\n\(provider.profileKey) = \"\(standard.path)\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    let reapply = try await fixture.apply(adopt: nil)
    #expect(reapply.succeeded, "\(reapply.output)")
    #expect(try fixture.status().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(FileManager.default.fileExists(atPath: standard.path))
    if let sourceBytes { #expect(try Data(contentsOf: standard) == sourceBytes) }
  }

  @Test(arguments: EnvironmentNativeSeed.Provider.allCases, [false, true])
  func journalRecoversBeforeAndAfterSwap(
    provider: EnvironmentNativeSeed.Provider, cutover: Bool
  ) async throws {
    let (fixture, migration) = try await prepared(provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (_, transaction) = try migration.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(transaction)
    #expect(try store.readTransaction() == transaction)
    if cutover { try migration.transition(transaction) }
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(try coordinator.recoverLocked())
    #expect(try store.readOwnership() == transaction.proposedOwnership)
    #expect(!store.transactionExists)
    // Rollback must also recover after cleanup, when the managed staging object is gone.
    try store.writeTransaction(transaction.rollingBack)
    #expect(try coordinator.recoverLocked())
    #expect(try store.readOwnership() == transaction.previousOwnership)
    #expect(!store.transactionExists)
    #expect(FileManager.default.fileExists(atPath: migration.sourceURL.path))
    let record = transaction.previousOwnership!.records.first { $0.id == provider.entryID }!
    let inspector = EnvironmentProviderInspector()
    #expect(try inspector.managedEntryIsExact(inspector.managedEntry(from: record)))
  }

  @Test(arguments: EnvironmentNativeSeed.Provider.allCases)
  func authorityFailureRollsBackOnlySelectedEntry(provider: EnvironmentNativeSeed.Provider)
    async throws
  {
    let (fixture, migration) = try await prepared(provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (plan, transaction) = try migration.plan()
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state,
      faultInjector: { _ in throw EnvironmentLifecycleError.blocked("injected") })
    #expect(throws: (any Error).self) {
      try coordinator.migrateStandardLocked(
        provider: provider, sourceURL: migration.sourceURL, approval: plan.approval)
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(!store.transactionExists)
    #expect(try store.readOwnership() == transaction.previousOwnership)
    #expect(FileManager.default.fileExists(atPath: migration.sourceURL.path))
  }
}
