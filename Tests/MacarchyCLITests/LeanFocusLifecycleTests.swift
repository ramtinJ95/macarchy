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

  @Test func failedStopKeepsRecoveryVisibleAndDoesNotStartBorders() async throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    #expect(try await fixture.apply().succeeded)
    state.withLock { $0.failStop = true }
    try fixture.writeProfile(provider: .borders)
    let applied = try await fixture.apply()
    #expect(!applied.succeeded)
    #expect(fixture.state.withLock { $0.actions.isEmpty && !$0.running })
    #expect(state.withLock { $0.configuration } != nil)
  }

  @Test(arguments: [false, true])
  func interruptedStartRollsBackThroughExistingJournal(attempted: Bool) throws {
    let (fixture, state) = try makeFixture()
    defer { fixture.remove() }
    try fixture.stageUnverifiedApply()
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    var journal = try #require(try store.readTransaction())
    #expect(journal.bordersRuntimeTarget == .lean)
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
    state.withLock { $0.failAcknowledgement = true }
    #expect(throws: (any Error).self) { try mode.inspect() }
    let result = try await coordinator.reconcile(adapterIDs: [BordersAdapter.leanID])
    #expect(
      result.record.results.contains {
        $0.adapterID == BordersAdapter.leanID && $0.status == .failed
      })
  }
}

private struct LeanFixtureState {
  var configuration: LeanFocusServiceConfiguration?
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
          $0.configuration == nil
            ? .absent
            : LeanFocusServiceInspection(registered: true, loaded: true, processID: 200),
          $0.configuration
        )
      }
    },
    start: { _, configuration in
      #expect(!bordersState.withLock { $0.running })
      state.withLock {
        if $0.configuration == nil { $0.actions.append("start") }
        $0.configuration = configuration
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
        guard $0.configuration == configuration, !$0.failAcknowledgement else {
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
