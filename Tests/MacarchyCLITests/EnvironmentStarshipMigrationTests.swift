import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentStarshipMigrationTests {
  @Test(arguments: ["missing", "selector", "conflict", "state", "public-alias"])
  func externalStarshipRejectsUnsafeOrUnpreparedSources(kind: String) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let manifest = try ReconciliationStatusStore(root: fixture.state).activeManifest()
    let palette = try String(
      contentsOf: fixture.state.appending(
        path: "generations/\(manifest.generationID)/generated/starship.toml"), encoding: .utf8)
    let source = (kind == "state" ? fixture.state : fixture.root).appending(path: "source.toml")
    let contents =
      "palette = \"\(kind == "selector" ? "personal" : "macarchy_current")\"\n" + palette
    if kind == "public-alias" {
      try contents.write(to: fixture.zshEntry, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: fixture.zshEntry)
    } else if kind != "missing" {
      try contents.write(to: source, atomically: true, encoding: .utf8)
    }
    let profile = try String(contentsOf: fixture.profile, encoding: .utf8)
    let path = kind == "state" ? "home/.config/macarchy/source.toml" : "source.toml"
    try
      (profile + "\n[starship]\nnative_configuration = \"\(path)\"\n"
      + (kind == "conflict" ? "behavior = \"source.toml\"\n" : "")).write(
        to: fixture.profile, atomically: true, encoding: .utf8)
    #expect(!(try fixture.plan().succeeded))
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test(arguments: [false, true])
  func externalSourceConnectsAndRepaintsWithoutCopying(existing: Bool) async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    if existing {
      let approval = try #require(
        try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String)
      #expect(try await fixture.apply(adopt: approval).succeeded)
    }
    try fixture.activateTheme()
    let source = fixture.root.appending(path: "my-prompt.toml")
    let alias = fixture.root.appending(path: "prompt-link.toml")
    let manifest = try ReconciliationStatusStore(root: fixture.state).activeManifest()
    let palette = try String(
      contentsOf: fixture.state.appending(
        path: "generations/\(manifest.generationID)/generated/starship.toml"), encoding: .utf8)
    let personal = "# personal prompt\npalette = \"macarchy_current\"\nformat = '$directory'\n"
    try (personal + palette).write(to: source, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    let profile = try String(contentsOf: fixture.profile, encoding: .utf8)
    try (profile + "\n[starship]\nnative_configuration = \"prompt-link.toml\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    if existing {
      #expect(!(try fixture.plan().succeeded))
      let migration = EnvironmentNativeFileMigration(
        provider: .starship, homeDirectory: fixture.home, stateRoot: fixture.state,
        sourceURL: alias)
      let (stale, _) = try migration.plan()
      try (personal + palette + "# new edit\n").write(
        to: source, atomically: true, encoding: .utf8)
      let coordinator = EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state)
      #expect(throws: (any Error).self) {
        try coordinator.migrateNativeFileLocked(
          provider: .starship, approval: stale.approval, sourceURL: alias)
      }
      let (plan, _) = try migration.plan()
      _ = try coordinator.migrateNativeFileLocked(
        provider: .starship, approval: plan.approval, sourceURL: alias)
    } else {
      let approval = try #require(
        try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String)
      let applied = try await fixture.apply(adopt: approval)
      #expect(applied.succeeded, "\(applied.output)")
    }
    #expect(try await fixture.apply(adopt: nil).succeeded)
    let ownership = try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    let paths = testConsumerPaths().managedEnvironmentPaths(
      stateRoot: fixture.state, homeDirectory: fixture.home, ownership: ownership)
    #expect(paths.starshipBehaviorURL == alias)
    let runtime = try ThemeRuntimeSelection.consumerPaths(
      stateRoot: fixture.state, consumerPaths: paths)
    #expect(runtime.starshipBehaviorURL == alias)
    let unauthorized = StarshipAdapter(
      root: fixture.state, configurationURL: paths.starshipConfigurationURL,
      behaviorURL: fixture.root.appending(path: "unrelated"),
      executableURL: StarshipAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        Issue.record("untrusted source must not invoke Starship")
        return ProcessResult(terminationStatus: 1, output: "")
      })
    #expect(try await unauthorized.reconciliation().run().status == .drifted)
    let adapter = StarshipAdapter(
      root: fixture.state, configurationURL: paths.starshipConfigurationURL,
      behaviorURL: runtime.starshipBehaviorURL,
      executableURL: StarshipAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        #expect(request.environmentOverrides["STARSHIP_CONFIG"] == source.path)
        return ProcessResult(terminationStatus: 0, output: "palette = \"macarchy_current\"")
      })
    let original = try String(contentsOf: source, encoding: .utf8)
    let changed = original.replacingOccurrences(
      of: "format = '$directory'", with: "format = '$character'")
    try changed.write(to: source, atomically: true, encoding: .utf8)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try String(contentsOf: source, encoding: .utf8) == changed)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == source.path)
    let next = try await fixture.apply(adopt: nil)
    #expect(next.succeeded, "\(next.output)")
    #expect(try jsonObject(next.output)["outcome"] as? String == "no_change")
    #expect(try fixture.status().succeeded)
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: source, encoding: .utf8) == changed)
  }

  private func fixture() async throws -> EnvironmentLifecycleFixture {
    let fixture = try EnvironmentLifecycleFixture()
    let approval = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String)
    let result = try await fixture.apply(adopt: approval)
    #expect(result.succeeded, "\(result.output)")
    try fixture.activateTheme()
    return fixture
  }

  @Test
  func migrationPreservesPersonalBehaviorThroughReapplyAndTeardown() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .starship, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) {
      try coordinator.migrateNativeFileLocked(provider: .starship, approval: "stale")
    }
    _ = try coordinator.migrateNativeFileLocked(provider: .starship, approval: plan.approval)
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(
      try store.readOwnership()
        == old.replacingTarget(for: .starship, with: migration.nativeURL.path))
    let edited =
      "# my personal prompt\n" + (try String(contentsOf: migration.nativeURL, encoding: .utf8))
    try edited.write(to: migration.nativeURL, atomically: true, encoding: .utf8)
    let adapter = StarshipAdapter(
      root: fixture.state, configurationURL: migration.publicURL,
      behaviorURL: fixture.root.appending(path: "unused"),
      executableURL: StarshipAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 0, output: "palette = \"macarchy_current\"")
      })
    #expect(adapter.inspection().status == .ready)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(try fixture.status().succeeded)
    #expect(try fixture.plan().output.contains(migration.nativeURL.path))
    #expect(try String(contentsOf: migration.nativeURL, encoding: .utf8) == edited)
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: migration.nativeURL, encoding: .utf8) == edited)
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryChangesOnlyStarship(rollback: Bool, switched: Bool) async throws {
    try await recover(rollback: rollback, switched: switched, external: false)
  }

  @Test(arguments: [false, true], [false, true])
  func externalRecoveryChangesOnlyStarship(rollback: Bool, switched: Bool) async throws {
    try await recover(rollback: rollback, switched: switched, external: true)
  }

  private func recover(rollback: Bool, switched: Bool, external: Bool) async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .starship, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, legacy) = try migration.plan()
    if external {
      _ = try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home, stateRoot: fixture.state
      )
      .migrateNativeFileLocked(provider: .starship, approval: plan.approval)
    } else {
      try migration.seed(legacy)
    }
    let old = try #require(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    let source = fixture.root.appending(path: "external-prompt.toml")
    if external { try FileManager.default.copyItem(at: migration.nativeURL, to: source) }
    let proposed = old.replacingTarget(
      for: .starship, with: external ? source.path : migration.nativeURL.path)
    if switched { try migration.transition(from: old, to: proposed) }
    let inspector = EnvironmentProviderInspector()
    let unrelated = old.records.filter { $0.id != .starship }.map {
      inspector.managedEntry(from: $0)
    }
    let before = try unrelated.map { try inspector.managedEntryIsExact($0) }
    #expect(before.allSatisfy { $0 })
    let transaction = EnvironmentTransaction(
      operation: .starshipMigration, previousOwnership: old, proposedOwnership: proposed,
      previousCurrentDestination: "generations/\(old.generationID)")
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    try store.writeTransaction(rollback ? transaction.rollingBack : transaction)
    #expect(
      try EnvironmentTransactionCoordinator(homeDirectory: fixture.home, stateRoot: fixture.state)
        .recoverLocked())
    #expect(try store.readOwnership() == (rollback ? old : proposed))
    #expect(try unrelated.map { try inspector.managedEntryIsExact($0) } == before)
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination()
        == "generations/\(old.generationID)")
    #expect(!store.transactionExists)
  }

  @Test
  func failedCutoverRetainsSeedAndMalformedScopeIsRejected() async throws {
    let fixture = try await fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let migration = EnvironmentNativeFileMigration(
      provider: .starship, homeDirectory: fixture.home, stateRoot: fixture.state)
    let (plan, old) = try migration.plan()
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.state,
      faultInjector: { _ in throw EnvironmentLifecycleError.blocked("injected") })
    #expect(throws: (any Error).self) {
      try coordinator.migrateNativeFileLocked(provider: .starship, approval: plan.approval)
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(try store.readOwnership() == old)
    try migration.validateNativeFile()
    #expect(throws: (any Error).self) { try migration.plan() }
    let forged = old.replacingTarget(for: .starship, with: migration.nativeURL.path)
      .replacingTarget(for: .zsh, with: "/unexpected")
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .starshipMigration, previousOwnership: old, proposedOwnership: forged,
        previousCurrentDestination: "generations/\(old.generationID)"))
    #expect(throws: (any Error).self) { try store.readTransaction() }
  }
}
