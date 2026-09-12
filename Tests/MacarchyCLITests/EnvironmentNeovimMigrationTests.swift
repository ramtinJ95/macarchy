import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentNeovimMigrationTests {
  @Test(arguments: ["missing", "theme", "state", "public-alias", "ancestor", "conflict"])
  func externalNeovimRejectsUnpreparedOrManagedTrees(kind: String) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try preparedSource(fixture)
    var selected = source
    if kind == "missing" { selected = fixture.root.appending(path: "missing") }
    if kind == "theme" {
      try FileManager.default.removeItem(
        at: source.appending(path: EnvironmentNeovimMigration.themePaths[0]))
    }
    if kind == "state" {
      try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
      selected = fixture.state.appending(path: "native-nvim")
      try FileManager.default.moveItem(at: source, to: selected)
    }
    if kind == "public-alias" {
      let entry = fixture.home.appending(path: ".config/nvim")
      try FileManager.default.moveItem(at: source, to: entry)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: entry)
    }
    if kind == "ancestor" { selected = fixture.home }
    if kind == "conflict" {
      try """
      schema_version = 1
      [neovim]
      native_configuration = "external-nvim"
      configuration = "external-nvim"
      """.write(to: fixture.profile, atomically: true, encoding: .utf8)
      #expect(!(try fixture.plan().succeeded))
    } else {
      #expect(throws: (any Error).self) {
        try EnvironmentNeovimMigration(
          homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: selected
        )
        .validateNativeTree()
      }
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  private func preparedSource(_ fixture: EnvironmentLifecycleFixture) throws -> URL {
    let source = fixture.root.appending(path: "external-nvim")
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Environment/neovim/default"), to: source)
    for path in EnvironmentNeovimMigration.themePaths {
      let url = source.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: url,
        withDestinationURL: fixture.state.appending(path: "environment/current/neovim/\(path)"))
    }
    return source
  }

  @Test(arguments: [false, true])
  func externalNeovimSourcePreservesBehaviorAndRealConsumerSeam(existing: Bool) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n"
    try base.write(to: fixture.profile, atomically: true, encoding: .utf8)
    if existing { #expect(try await fixture.apply(adopt: nil).succeeded) }
    let source = try preparedSource(fixture)
    let alias = fixture.root.appending(path: "nvim-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    try (base + "[neovim]\nnative_configuration = \"nvim-link\"\n").write(
      to: fixture.profile, atomically: true, encoding: .utf8)
    if existing {
      #expect(!(try fixture.plan().succeeded))
      let migration = EnvironmentNeovimMigration(
        homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: alias)
      let (stale, old) = try migration.plan()
      let before = try unrelatedEvidence(fixture)
      let initURL = source.appending(path: "init.lua")
      let initText = try String(contentsOf: initURL, encoding: .utf8)
      try (initText + "\n-- edited after preview\n").write(
        to: initURL, atomically: true, encoding: .utf8)
      let coordinator = EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state)
      #expect(throws: (any Error).self) {
        try coordinator.migrateNeovimLocked(approval: stale.approval, sourceURL: alias)
      }
      #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == old)
      let (plan, _) = try migration.plan()
      _ = try coordinator.migrateNeovimLocked(approval: plan.approval, sourceURL: alias)
      #expect(try unrelatedEvidence(fixture) == before)
    }
    let neverRestore = EnvironmentNeovimPreparer { _, _ in
      Issue.record("external native configuration must never restore plugin worktrees")
      return EnvironmentVerification(id: "neovim_plugins", status: "failed", message: "unexpected")
    }
    let applied = try await fixture.apply(adopt: nil, neovim: neverRestore)
    #expect(applied.succeeded, "\(applied.output)")
    try fixture.activateTheme()
    let active = try ReconciliationStatusStore(root: fixture.state).activeManifest()
    let adapter = NeovimAdapter(
      root: fixture.state, configurationDirectoryURL: fixture.home.appending(path: ".config/nvim"),
      executableURL: NeovimAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(
          terminationStatus: 0,
          output: "MACARCHY_THEME=\(active.generationID):\(active.themeID)")
      })
    #expect(adapter.inspection(includeRuntimeChecks: true).status == .ready)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let generation = try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination()
    let lock = source.appending(path: "lazy-lock.json")
    try "{}\n".write(to: lock, atomically: true, encoding: .utf8)
    let repeated = try await fixture.apply(adopt: nil, neovim: neverRestore)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == generation)
    #expect(try fixture.status().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: lock, encoding: .utf8) == "{}\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == source.path)
  }

  private func unrelatedEvidence(_ fixture: EnvironmentLifecycleFixture) throws
    -> [EnvironmentEntryEvidence]
  {
    try [
      ".zshrc", ".config/kitty/kitty.conf", ".config/btop/btop.conf",
      ".config/macarchy/environment/current",
    ].map {
      try EnvironmentProviderInspector().capture(
        fixture.home.appending(path: $0), directoryLink: nil)
    }
  }

  private func fixture() async throws -> EnvironmentLifecycleFixture {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    try """
    schema_version = 1
    [focus_ring]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let original = fixture.root.appending(path: "personal-nvim")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try Data("original personal config\n".utf8).write(to: original.appending(path: "init.lua"))
    try FileManager.default.createSymbolicLink(
      at: fixture.home.appending(path: ".config/nvim"), withDestinationURL: original)
    let plan = try fixture.plan()
    let approval = try #require(try jsonObject(plan.output)["adoption_evidence_digest"] as? String)
    let applied = try await fixture.apply(adopt: approval)
    #expect(applied.succeeded, "\(applied.output)")
    return fixture
  }

  @Test
  func migrateEditReapplyAndTeardownPreserveNativeBehavior() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let unrelated = try unrelatedEvidence(fixture)
    let (plan, old) = try migration.plan()
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let sealedLock = fixture.state.appending(path: "environment/current/neovim/lazy-lock.json")
    let oldLock = try Data(contentsOf: sealedLock)
    #expect(!FileManager.default.fileExists(atPath: migration.nativeRoot.path))

    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    _ = try coordinator.migrateNeovimLocked(approval: plan.approval)
    #expect(try store.readOwnership() == old.replacingNeovimTarget(migration.nativeRoot.path))
    #expect(try unrelatedEvidence(fixture) == unrelated)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: migration.publicURL.path)
        == migration.nativeRoot.path)
    try migration.validateNativeTree()
    #expect(try Data(contentsOf: migration.nativeRoot.appending(path: "lazy-lock.json")) == oldLock)

    // The real consumer must accept the migrated topology, not just the owner.
    try fixture.activateTheme()
    let active = try ReconciliationStatusStore(root: fixture.state).activeManifest()
    let adapter = NeovimAdapter(
      root: fixture.state, configurationDirectoryURL: migration.publicURL,
      executableURL: NeovimAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(
          terminationStatus: 0, output: "MACARCHY_THEME=\(active.generationID):\(active.themeID)")
      })
    let inspected = adapter.inspection(includeRuntimeChecks: true)
    #expect(inspected.status == .ready, "\(inspected.message ?? "no diagnostic")")
    #expect(try await adapter.reconciliation().run().status == .applied)

    let lock = migration.publicURL.appending(path: "lazy-lock.json")
    let options = migration.publicURL.appending(path: "lua/config/options.lua")
    #expect(access(lock.path, W_OK) == 0)
    let nativeLock = Data("{}\n".utf8)
    let nativeOptions = Data("vim.opt.number = false\n".utf8)
    try nativeLock.write(to: lock)
    try nativeOptions.write(to: options)
    let nextPlan = try fixture.plan()
    #expect(nextPlan.succeeded, "\(nextPlan.output)")
    #expect(!nextPlan.output.contains("restore_neovim_plugins"))
    #expect(nextPlan.output.contains("user-owned"))
    let mustNotRestore = EnvironmentNeovimPreparer { _, _ in
      Issue.record("native reapply must not run plugin restoration")
      return EnvironmentVerification(id: "neovim_plugins", status: "failed", message: "unexpected")
    }
    let applied = try await fixture.apply(adopt: nil, neovim: mustNotRestore)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(try fixture.status().succeeded)
    #expect(try Data(contentsOf: lock) == nativeLock)
    #expect(try Data(contentsOf: options) == nativeOptions)
    #expect(try Data(contentsOf: sealedLock) == oldLock)

    let removed = try await fixture.teardown()
    #expect(removed.succeeded, "\(removed.output)")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: migration.publicURL.path)
        == fixture.root.appending(path: "personal-nvim").path)
    #expect(
      try Data(contentsOf: migration.nativeRoot.appending(path: "lazy-lock.json")) == nativeLock)
    #expect(
      try Data(contentsOf: migration.nativeRoot.appending(path: "lua/config/options.lua"))
        == nativeOptions)
    #expect(
      try Data(contentsOf: migration.publicURL.appending(path: "init.lua"))
        == Data("original personal config\n".utf8))
    #expect(try store.readOwnership() == nil)
  }

  @Test
  func approvalAndDestinationConflictsCannotChangeTheEntry() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, before) = try migration.plan()
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) {
      try coordinator.migrateNeovimLocked(approval: "stale")
    }
    #expect(!FileManager.default.fileExists(atPath: migration.nativeRoot.path))
    // A dangling link is still an existing, unowned destination.
    try FileManager.default.createSymbolicLink(
      at: migration.nativeRoot, withDestinationURL: fixture.root.appending(path: "absent"))
    #expect(throws: (any Error).self) {
      try coordinator.migrateNeovimLocked(approval: plan.approval)
    }
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == before)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: migration.publicURL.path)
        == migration.legacyTarget)
  }

  @Test
  func failedCutoverRestoresOnlyTheEntryAndKeepsTheWritableCopy() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let unrelated = try unrelatedEvidence(fixture)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state,
      faultInjector: { _ in throw EnvironmentLifecycleError.blocked("injected") })
    #expect(throws: (any Error).self) {
      try coordinator.migrateNeovimLocked(approval: plan.approval)
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(try store.readOwnership() == old)
    #expect(!store.transactionExists)
    #expect(try unrelatedEvidence(fixture) == unrelated)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: migration.publicURL.path)
        == migration.legacyTarget)
    try migration.validateNativeTree()
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryIsNeovimOnly(rollback: Bool, entryAlreadySwitched: Bool) async throws {
    try await recover(
      rollback: rollback, entryAlreadySwitched: entryAlreadySwitched, external: false)
  }

  @Test(arguments: [false, true], [false, true])
  func externalRecoveryIsNeovimOnly(rollback: Bool, entryAlreadySwitched: Bool) async throws {
    try await recover(
      rollback: rollback, entryAlreadySwitched: entryAlreadySwitched, external: true)
  }

  private func recover(rollback: Bool, entryAlreadySwitched: Bool, external: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, legacy) = try migration.plan()
    if external {
      _ = try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state
      )
      .migrateNeovimLocked(approval: plan.approval)
    } else {
      try migration.seed(legacy)
    }
    let old = try #require(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    let source = external ? try preparedSource(fixture) : migration.nativeRoot
    let new = old.replacingNeovimTarget(source.path)
    let unrelated = try unrelatedEvidence(fixture)
    if entryAlreadySwitched { try migration.transition(from: old, to: new) }
    let journal = EnvironmentTransaction(
      operation: .neovimMigration, previousOwnership: old, proposedOwnership: new,
      previousCurrentDestination: "generations/\(old.generationID)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(rollback ? journal.rollingBack : journal)
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(try coordinator.recoverLocked())
    #expect(try store.readOwnership() == (rollback ? old : new))
    #expect(!store.transactionExists)
    #expect(try unrelatedEvidence(fixture) == unrelated)
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination()
        == "generations/\(old.generationID)")
    try migration.validateNativeTree()
  }

  @Test
  func migrationJournalCannotChangeAnotherProvider() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (_, old) = try migration.plan()
    let new = old.replacingNeovimTarget(migration.nativeRoot.path)
    let forged = EnvironmentOwnership(
      generationID: new.generationID,
      records: new.records.filter { $0.id != .zsh },
      createdDirectories: new.createdDirectories,
      originalThemeBridges: new.originalThemeBridges,
      btop: new.btop)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .neovimMigration, previousOwnership: old, proposedOwnership: forged,
        previousCurrentDestination: "generations/\(old.generationID)"))
    #expect(throws: (any Error).self) { try store.readTransaction() }
    #expect(try store.readOwnership() == old)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_LAZY_NVIM_ROOT"] != nil),
    arguments: [false, true])
  func installedLazyCanWriteTheMigratedLockWithoutDownloads(external: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lazyRoot = try #require(ProcessInfo.processInfo.environment["MACARCHY_TEST_LAZY_NVIM_ROOT"])
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, _) = try migration.plan()
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateNeovimLocked(approval: plan.approval)
    if external {
      let source = try preparedSource(fixture)
      let migration = EnvironmentNeovimMigration(
        homeDirectory: fixture.home, stateRoot: fixture.state, sourceURL: source)
      let (plan, _) = try migration.plan()
      _ = try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state
      )
      .migrateNeovimLocked(approval: plan.approval, sourceURL: source)
    }
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: NeovimAdapter.liveExecutableURL,
        arguments: [
          "--clean", "--headless", "-i", "NONE", "-l",
          repositoryRoot.appending(path: "Tests/Fixtures/NeovimNativeLock/check.lua").path,
          lazyRoot, fixture.state.appending(path: "environment/current/neovim/lazy-lock.json").path,
        ],
        timeout: 10,
        environmentOverrides: [
          "HOME": fixture.home.path, "NVIM_APPNAME": "nvim",
          "XDG_CONFIG_HOME": fixture.home.appending(path: ".config").path,
          "XDG_STATE_HOME": fixture.root.appending(path: "nvim-state").path,
          "XDG_CACHE_HOME": fixture.root.appending(path: "nvim-cache").path,
          "XDG_DATA_HOME": fixture.root.appending(path: "nvim-data").path,
        ]))
    #expect(result.terminationStatus == 0, "\(result.output)")
    #expect(result.output.contains("Lazy lock writer succeeded"))
  }

  @Test
  func nativeDriftIsVisibleAndCannotTurnIntoWritesThroughAnExternalLink() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNeovimMigration(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, _) = try migration.plan()
    _ = try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
      .migrateNeovimLocked(approval: plan.approval)
    let lock = migration.nativeRoot.appending(path: "lazy-lock.json")
    try FileManager.default.removeItem(at: lock)
    let external = fixture.root.appending(path: "external-lock")
    try Data("do not touch".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: external)
    let status = try fixture.status()
    #expect(!status.succeeded)
    #expect(status.output.contains("ordinary writable file"))
    #expect(!(try await fixture.apply(adopt: nil).succeeded))
    #expect(try Data(contentsOf: external) == Data("do not touch".utf8))
  }
}
