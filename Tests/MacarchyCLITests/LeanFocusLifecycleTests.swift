import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct LeanFocusLifecycleTests {
  @Test func profileIsOptInAndHasNoBordersPackageRequirement() throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.remove() }
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: true)
    #expect(PortableProfile.defaults.environment.focusRing == .borders)
    #expect(profile.environment.focusRing == .lean)
    #expect(profile.environment.selectedThemeAdapterIDs == [BordersAdapter.leanID])
    let dependencies = DependencyProfile.personal(homeDirectory: fixture.home)
      .selectedForEnvironment(profile.environment).map(\.id)
    #expect(dependencies.contains(BordersAdapter.leanID))
    #expect(!dependencies.contains(BordersAdapter.id))
    #expect(!dependencies.contains("homebrew"))
  }

  @Test func freshApplyReapplyDisableAndTeardownOwnOnlyLean() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    let planned = try fixture.plan()
    #expect(planned.succeeded, "\(planned.output)")
    #expect(try fixture.digest(planned.output) == nil)
    let applied = try await fixture.apply()
    #expect(applied.succeeded, "\(applied.output)")
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    let ownership = try #require(try store.readOwnership())
    #expect(ownership.schemaVersion == 3)
    #expect(ownership.borders?.retainsBorders == false)
    #expect(ownership.records.isEmpty)
    #expect(ownership.enabledThemeAdapterIDs == [BordersAdapter.leanID])
    #expect(try await fixture.apply().succeeded)
    #expect(state.withLock { $0.actions } == ["start", "ack", "ack"])
    #expect(fixture.state.withLock { $0.actions.isEmpty })
    try fixture.verifyOriginal()
    try fixture.writeProfile(provider: .disabled)
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded, "\(disabled.output)")
    #expect(state.withLock { $0.configuration } == nil)
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership() == nil)
    try fixture.writeProfile(provider: .lean)
    #expect(try await fixture.apply().succeeded)
    let teardown = try await fixture.teardown()
    #expect(teardown.succeeded, "\(teardown.output)")
    #expect(state.withLock { $0.configuration } == nil)
    #expect(try store.readOwnership() == nil)
    #expect(try store.readTransaction() == nil)
    try expectRemovedLean(teardown.output)
  }

  @Test func rollbackBeforeNativeWorkPreservesNewlyStartedUserBorders() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    let original = try #require(try store.readOwnership())
    // The user starts brew Borders after applying fresh lean (no retained Borders).
    fixture.state.withLock { $0.running = true }
    let before = try fixture.runtime.inspectIncumbent(fixture.home)
    try fixture.writeProfile(provider: .borders)
    try fixture.stageUnverifiedApply()
    let journal = try #require(try store.readTransaction())
    #expect(journal.previousOwnership == original)
    #expect(journal.proposedOwnership?.borders?.originalServiceWasRunning == true)
    #expect(journal.bordersRuntimeAttempted == nil)
    #expect(journal.bordersPreviousRuntime == before)
    // Failure in another adapter before the focus native phase.
    #expect(
      try EnvironmentApplyCommandRunner(
        prerequisites: .assumed, theme: nil, verifier: .assumed, bordersRuntime: fixture.runtime
      ).finishDeferredApply(stateRoot: fixture.root, homeDirectory: fixture.home, commit: false))
    #expect(try fixture.runtime.inspectIncumbent(fixture.home) == before)
    #expect(fixture.state.withLock { $0.actions.isEmpty && $0.running })
    #expect(state.withLock { $0.actions } == ["start", "ack"])
    #expect(try store.readOwnership() == original)
    #expect(try store.readTransaction() == nil)
  }

  @Test(arguments: [false, true], [false, true])
  func removalIgnoresUnownedBorders(teardown: Bool, registered: Bool) async throws {
    var (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    fixture.state.withLock { $0.running = true }
    if !registered {
      fixture.runtime.inspectIncumbent = { _ in
        // Matches the native inspector's unregistered-process refusal. Removal
        // must not call it, rather than pretending such a process is stopped.
        Issue.record("lean-only removal inspected an unrelated Borders process")
        throw BordersServiceError.blocked("process and Homebrew job disagree")
      }
    }
    let before = try fixture.runtime.recoveryPreflight(fixture.home)
    try fixture.writeProfile(provider: .disabled)
    let result = try await (teardown ? fixture.teardown() : fixture.apply())
    #expect(result.succeeded, "\(result.output)")
    #expect(try fixture.runtime.recoveryPreflight(fixture.home) == before)
    #expect(fixture.state.withLock { $0.actions.isEmpty && $0.running })
    #expect(state.withLock { $0.configuration } == nil)
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    #expect(try store.readOwnership() == nil)
    #expect(try store.readTransaction() == nil)
    try expectRemovedLean(result.output)
  }

  @Test(arguments: [false, true], [false, true])
  func removalRollbackRespectsUnownedBorders(registered: Bool, attempted: Bool) async throws {
    var (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    let original = try #require(try store.readOwnership())
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: fixture.home, stateRoot: fixture.root)
    let lock = ActivationLock(root: fixture.root)
    let lifecycleLock = EnvironmentLifecycleLock(stateRoot: fixture.root)
    let descriptor = try lifecycleLock.acquire()
    defer { lifecycleLock.release(descriptor) }
    // Disabled apply and explicit teardown share this removal transaction.
    _ = try lock.withLock {
      try coordinator.teardownLocked(dryRun: false, bordersService: .stopped)
    }
    if attempted {
      var journal = try #require(try store.readTransaction())
      journal.bordersRuntimeAttempted = true
      try lock.withLock { try store.writeTransaction(journal) }
      try fixture.runtime.lean.stop(fixture.home, #require(original.borders?.leanService))
    }
    fixture.state.withLock { $0.running = true }
    let nativeInspector = fixture.runtime.inspectIncumbent
    if !registered {
      fixture.runtime.inspectIncumbent = { _ in
        if !attempted { Issue.record("pre-native rollback inspected unrelated Borders") }
        throw BordersServiceError.blocked("process and Homebrew job disagree")
      }
    }
    try lock.withLock { try coordinator.rollbackApplyLocked() }
    if attempted {
      do {
        _ = try verifyPendingBordersRuntime(coordinator: coordinator, runtime: fixture.runtime)
        Issue.record("rollback started lean alongside unmanaged Borders")
      } catch {
        let message = String(describing: error)
        #expect(message.contains("JankyBorders"))
        #expect(message.contains("unregister"))
        #expect(message.contains("retry environment apply"))
      }
      #expect(try store.readTransaction()?.direction == .rollback)
      #expect(state.withLock { $0.configuration } == nil)
      #expect(fixture.state.withLock { $0.actions.isEmpty && $0.running })
      // The user removes the external renderer; the retained journal can finish.
      fixture.state.withLock { $0.running = false }
      fixture.runtime.inspectIncumbent = nativeInspector
    }
    _ = try verifyPendingBordersRuntime(coordinator: coordinator, runtime: fixture.runtime)
    _ = try lock.withLock { try coordinator.prepareRecoveryLocked() }
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership() == original)
    #expect(fixture.state.withLock { $0.actions.isEmpty })
    #expect(
      state.withLock { $0.actions }
        == (attempted ? ["start", "ack", "stop", "start", "ack"] : ["start", "ack"]))
  }

  @Test func frozenPreSchemaThreeBordersOwnershipRetainsLegacySemantics() throws {
    let legacy = Data(
      """
      {
        "schema_version": 1,
        "generation_id": "e-00000000-0000-0000-0000-000000000001",
        "records": [{
          "id": "borders_configuration", "public_path": "/fixture/.config/borders/bordersrc",
          "managed_kind": "symbolic_link", "managed_target": "/fixture/state/environment/current/borders/bordersrc",
          "original": {"kind": "absent", "inventory": []}
        }],
        "created_directories": [], "original_theme_bridges": [],
        "borders": {
          "originalServiceWasRunning": false,
          "fallbackConfiguration": {"kind": "absent", "inventory": []}
        },
        "enabled_theme_adapter_ids": ["borders"]
      }
      """.utf8)
    let decoded = try JSONDecoder().decode(EnvironmentOwnership.self, from: legacy)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.hasValidShape)
    #expect(
      decoded.records.first?.managedKind
        == EnvironmentManagedEntry.ManagedKind.symbolicLink.rawValue)
    #expect(ThemeRuntimeSelection.appliedAdapterIDs(for: decoded) == [BordersAdapter.id])
    let borders = try #require(decoded.borders)
    #expect(borders.retainsBorders && borders.leanService == nil)
    let (fixture, _) = try makeFixture()
    defer { fixture.remove() }
    let restored = try EnvironmentProviderInspector().inspectBorders(
      enabled: false, previous: borders, homeDirectory: fixture.home, service: .stopped)
    #expect(restored.ownership == nil)
    #expect(restored.entries.first?.status == .restorationRequired)
    #expect(restored.entries.first?.message.contains("Stop and unregister") == true)
  }

  @Test(arguments: ["file", "directory-link", "fallback"], [false, true])
  func managedBordersHandoffAndSwitchBackPreserveOriginal(kind: String, running: Bool) async throws
  {
    let (fixture, state) = try makeFixture(kind: kind, running: running)
    defer { fixture.remove() }
    try fixture.writeProfile(provider: .borders)
    let digest = try fixture.digest(fixture.plan().output)
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let original = try #require(
      try EnvironmentStateStore(stateRoot: fixture.root).readOwnership()?.borders)
    try fixture.writeProfile(provider: .lean)
    let switched = try await fixture.apply()
    #expect(switched.succeeded, "\(switched.output)")
    #expect(!fixture.state.withLock { $0.running })
    #expect(state.withLock { $0.configuration } != nil)
    let retained = try #require(
      try EnvironmentStateStore(stateRoot: fixture.root).readOwnership()?.borders)
    #expect(retained.retainsBorders)
    #expect(retained.selectingLean(nil) == original)
    try fixture.writeProfile(provider: .borders)
    let rollback = try await fixture.apply()
    #expect(rollback.succeeded, "\(rollback.output)")
    #expect(state.withLock { $0.configuration } == nil)
    #expect(fixture.state.withLock { $0.running })
    let teardown = try await fixture.teardown()
    #expect(teardown.succeeded, "\(teardown.output)")
    #expect(fixture.state.withLock { $0.running } == running)
    try fixture.verifyOriginal()
  }

  @Test func unmanagedBordersRefusesWithoutAdoptingOrStopping() async throws {
    let (fixture, state) = try makeFixture(running: true)
    defer { fixture.remove() }
    let plan = try fixture.plan()
    #expect(!plan.succeeded && plan.output.contains("unmanaged JankyBorders"))
    let applied = try await fixture.apply()
    #expect(!applied.succeeded)
    #expect(fixture.state.withLock { $0.actions.isEmpty && $0.running })
    #expect(state.withLock { $0.actions.isEmpty })
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readOwnership() == nil)
  }

  @Test func unownedLeanRefusesAndNeverStopsIt() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    state.withLock { $0.foreign = true }
    let result = try await fixture.apply()
    #expect(!result.succeeded && result.output.contains("unowned lean"))
    #expect(state.withLock { $0.actions.isEmpty })
  }

  @Test func teardownStillCleansRetainedLeanAfterExternalUnregistration() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    state.withLock { $0.registered = false }
    let result = try await fixture.teardown()
    #expect(result.succeeded, "\(result.output)")
    #expect(state.withLock { $0.actions } == ["start", "ack", "stop"])
    #expect(state.withLock { $0.configuration } == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readTransaction() == nil)
    try expectRemovedLean(result.output)
  }

  @Test(arguments: [false, true])
  func failedLeanAcknowledgementRollsBackToThePreviousProvider(previousBorders: Bool) async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    if previousBorders {
      try fixture.writeProfile(provider: .borders)
      #expect(try await fixture.apply().succeeded)
      try fixture.writeProfile(provider: .lean)
    }
    state.withLock { $0.failAcknowledgement = true }
    let applied = try await fixture.apply()
    #expect(!applied.succeeded, "\(applied.output)")
    #expect(applied.output.contains("missing lean acknowledgement"))
    #expect(state.withLock { $0.actions.contains("start") })
    #expect(state.withLock { $0.configuration } == nil)
    #expect(fixture.state.withLock { $0.running } == previousBorders)
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership()?.borders?.leanService == nil)
  }

  @Test func failedStopRollsBackVisiblyAndAcknowledgesLean() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    let original = try store.readOwnership()
    state.withLock { $0.failStop = true }
    try fixture.writeProfile(provider: .borders)
    let applied = try await fixture.apply()
    #expect(!applied.succeeded)
    #expect(applied.output.contains("injected lean stop"))
    #expect(applied.output.contains("rolled back"))
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership() == original)
    #expect(state.withLock { $0.actions } == ["start", "ack", "ack"])
    #expect(fixture.state.withLock { $0.actions.isEmpty && !$0.running })
  }

  @Test func failedStopAndFailedRollbackAcknowledgementKeepRecoveryVisible() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    state.withLock {
      $0.failStop = true
      $0.failAcknowledgement = true
    }
    try fixture.writeProfile(provider: .borders)
    let applied = try await fixture.apply()
    #expect(!applied.succeeded)
    #expect(fixture.state.withLock { $0.actions.isEmpty && !$0.running })
    #expect(state.withLock { $0.configuration } != nil)
    #expect(applied.output.contains("injected lean stop"))
    #expect(applied.output.contains("recovery_required"))
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readTransaction() != nil)
  }

  @Test(arguments: [false, true])
  func interruptedStartRollsBackThroughExistingJournal(attempted: Bool) throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    try fixture.stageUnverifiedApply()
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    var journal = try #require(try store.readTransaction())
    #expect(journal.bordersRuntimeTarget == .lean)
    #expect(journal.bordersRuntimeAttempted == nil)
    #expect(
      journal.previousOwnership == nil && journal.proposedOwnership?.borders?.leanService != nil)
    if attempted {
      journal.bordersRuntimeAttempted = true
      try store.writeTransaction(journal)
      try fixture.runtime.lean.start(
        fixture.home, #require(journal.proposedOwnership?.borders?.leanService))
    }
    #expect(
      try EnvironmentApplyCommandRunner(
        prerequisites: .assumed, theme: nil, verifier: .assumed, bordersRuntime: fixture.runtime
      ).finishDeferredApply(stateRoot: fixture.root, homeDirectory: fixture.home, commit: false))
    #expect(state.withLock { $0.configuration } == nil)
    #expect(try store.readOwnership() == nil)
    #expect(try store.readTransaction() == nil)
    #expect(fixture.state.withLock { $0.actions.isEmpty })
    #expect(state.withLock { $0.actions } == (attempted ? ["start", "stop"] : []))
  }

  @Test func liveThemeUsesAppliedSelectionAndReportsMissingAcknowledgement() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    try fixture.writeProfile(provider: .disabled)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.root, homeDirectory: fixture.home) == [BordersAdapter.leanID])
    let coordinator = try ThemeRuntimeSelection.activationCoordinator(
      stateRoot: fixture.root, consumerPaths: testConsumerPaths(homeDirectory: fixture.home),
      bordersRuntime: fixture.runtime)
    _ = try await coordinator.activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))
    #expect(state.withLock { $0.lastAccent } == "#7aa2f7")
    let mode = ThemeRuntimeSelection.managedLeanMode(
      stateRoot: fixture.root, homeDirectory: fixture.home, runtime: fixture.runtime.lean)
    #expect(throws: Never.self) { try mode.inspect() }
    state.withLock { $0.outdatedExecutable = true }
    _ = try mode.reconcile()
    #expect(!state.withLock { $0.outdatedExecutable })
    #expect(state.withLock { $0.actions.contains("restart") })
    state.withLock { $0.running = false }
    let repaired = try mode.reconcile()
    #expect(repaired.hasPrefix("Started stopped owned lean service. "))
    #expect(state.withLock { $0.running && $0.actions.suffix(2) == ["start", "ack"] })
    state.withLock { $0.registered = false }
    let actions = state.withLock { $0.actions }
    #expect(throws: (any Error).self) { try mode.reconcile() }
    #expect(state.withLock { $0.actions } == actions)
    state.withLock { $0.registered = true }
    state.withLock { $0.failAcknowledgement = true }
    #expect(throws: (any Error).self) { try mode.inspect() }
    let result = try await coordinator.reconcile(adapterIDs: [BordersAdapter.leanID])
    #expect(
      result.record.results.contains {
        $0.adapterID == BordersAdapter.leanID && $0.status == .failed
      })
  }
}

private func expectRemovedLean(_ output: String) throws {
  let report = try #require(
    JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  let rows = try #require(report["theme"] as? [[String: Any]])
  let lean = try #require(rows.first { $0["adapter_id"] as? String == BordersAdapter.leanID })
  #expect(lean["status"] as? String == "applied")
  #expect(
    lean["message"] as? String
      == "Stopped and unregistered owned lean; no Borders state was adopted or changed.")
}

private struct LeanFixtureState {
  var configuration: LeanFocusServiceConfiguration?
  var registered = true
  var running = true
  var outdatedExecutable = false
  var actions: [String] = []
  var foreign = false
  var failAcknowledgement = false
  var failStop = false
  var lastAccent: String?
}

private final class LeanStateBox: Sendable {
  private let value = Mutex(LeanFixtureState())
  func withLock<T>(_ body: (inout LeanFixtureState) throws -> T) rethrows -> T {
    try value.withLock { try body(&$0) }
  }
}

private func makeFixture(
  kind: String = "absent", running: Bool = false
) throws -> (ManagedBordersFixture, LeanStateBox) {
  var fixture = try ManagedBordersFixture(kind: kind, running: running)
  let state = LeanStateBox()
  let bordersState = fixture.state
  fixture.runtime.inspectIncumbent = fixture.runtime.recoveryPreflight
  fixture.runtime.lean = EnvironmentLeanRuntime(
    configuration: {
      LeanFocusServiceConfiguration(
        stateRoot: $0, executableURL: URL(filePath: "/fixture/bin/macarchy-focus-ring"))
    },
    inspect: { _, known in
      try state.withLock {
        guard !$0.foreign,
          $0.configuration.map({ known.contains($0) }) ?? true
        else { throw EnvironmentLifecycleError.blocked("unowned lean") }
        return (
          $0.configuration == nil || !$0.registered
            ? .absent
            : LeanFocusServiceInspection(
              registered: true, loaded: true, processID: $0.running ? 200 : nil,
              executableIsCurrent: !$0.outdatedExecutable),
          $0.configuration ?? known.first
        )
      }
    },
    start: { _, configuration in
      #expect(!bordersState.withLock { $0.running })
      state.withLock {
        if $0.configuration == nil || !$0.running { $0.actions.append("start") }
        if $0.outdatedExecutable { $0.actions.append("restart") }
        $0.configuration = configuration
        $0.registered = true
        $0.running = true
        $0.outdatedExecutable = false
      }
    },
    stop: { _, configuration in
      try state.withLock {
        guard !$0.failStop else { throw EnvironmentLifecycleError.blocked("injected lean stop") }
        #expect($0.configuration == nil || $0.configuration == configuration)
        $0.actions.append("stop")
        $0.configuration = nil
      }
    },
    acknowledge: { _, configuration, _ in
      let palette = try BordersPalette.read(root: URL(filePath: configuration.stateRoot))
      return try state.withLock {
        guard $0.configuration == configuration, $0.registered, $0.running, !$0.failAcknowledgement
        else {
          throw EnvironmentLifecycleError.drift("missing lean acknowledgement")
        }
        $0.actions.append("ack")
        $0.lastAccent = palette.accent
        return "Acknowledged \(palette.generationID) \(palette.accent)"
      }
    })
  try fixture.writeProfile(provider: .lean)
  return (fixture, state)
}
