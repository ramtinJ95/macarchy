import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct BordersLifecycleTests {
  @Test
  func failedRollbackRetainsBothForwardAndRecoveryErrors() async throws {
    let fixture = try ManagedBordersFixture(kind: "absent", running: false)
    defer { fixture.remove() }
    fixture.state.withLock {
      $0.failRequest = true
      $0.failStop = true
    }
    let result = try await fixture.apply()
    #expect(!result.succeeded)
    #expect(result.output.contains("injected request failure"))
    #expect(result.output.contains("injected stop failure"))
    #expect(result.output.contains("recovery_required"))
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readTransaction() != nil)
  }

  @Test(arguments: ["absent", "file", "directory-link", "fallback"])
  func managedApplyReapplyAndTeardownPreserveNativeConfiguration(kind: String) async throws {
    let fixture = try ManagedBordersFixture(kind: kind, running: kind != "absent")
    defer { fixture.remove() }
    let plan = try fixture.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let digest = try fixture.digest(plan.output)
    #expect((digest != nil) == (kind != "absent"))
    if digest != nil {
      let unapproved = try await fixture.apply()
      #expect(!unapproved.succeeded)
      #expect(fixture.state.withLock { $0.actions.isEmpty })
    }
    let applied = try await fixture.apply(adopt: digest)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(
      fixture.state.withLock { $0.actions } == [kind == "absent" ? "start" : "restart", "#cba6f7"])
    let ownership = try #require(try EnvironmentStateStore(stateRoot: fixture.root).readOwnership())
    #expect(ownership.borders?.originalServiceWasRunning == (kind != "absent"))
    #expect(ownership.enabledThemeAdapterIDs == [BordersAdapter.id])
    let reapplied = try await fixture.apply()
    #expect(reapplied.succeeded, "\(reapplied.output)")
    #expect(fixture.state.withLock { $0.actions.last } == "#cba6f7")
    #expect(
      fixture.state.withLock { $0.actions.filter { ["start", "restart"].contains($0) }.count } == 1)
    let teardown = try await fixture.teardown()
    #expect(teardown.succeeded, "\(teardown.output)")
    #expect(fixture.state.withLock { $0.running } == (kind != "absent"))
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readOwnership() == nil)
    try fixture.verifyOriginal()
  }

  @Test
  func applyPersistsCurrentBordersResultForDoctorAndReplacesFailure() async throws {
    let fixture = try ManagedBordersFixture(kind: "absent", running: false)
    defer { fixture.remove() }
    let status = ReconciliationStatusStore(root: fixture.root)
    for failedRecord in [false, true] {
      if failedRecord {
        _ = try status.persist(
          manifest: ThemeGenerationReader(root: fixture.root).activeManifest(),
          results: [
            AdapterResult(adapterID: BordersAdapter.id, requirement: .required, status: .failed)
          ])
      }
      #expect(try await fixture.apply().succeeded)
      let doctor = DoctorCommandRunner(
        read: readThemeStatusSnapshot,
        inspect: { root, paths in
          try ThemeRuntimeSelection.activationCoordinator(
            stateRoot: root, consumerPaths: paths, bordersRuntime: fixture.runtime
          ).inspectAdapters([], includeRuntimeChecks: true)
        },
        enabledAdapterIDs: { root, paths in
          try ThemeRuntimeSelection.enabledAdapterIDs(stateRoot: root, consumerPaths: paths)
        })
      let result = try doctor.execute(
        stateRoot: fixture.root,
        consumerPaths: testConsumerPaths(homeDirectory: fixture.home), json: true)
      #expect(result.succeeded, "\(result.output)")
    }
  }

  @Test(arguments: [false, true])
  func selectedReconciliationExcludesLifecycleOwnedBordersEvenWithoutCurrentStatus(stale: Bool)
    async throws
  {
    let fixture = try ManagedBordersFixture(kind: "absent", running: false)
    defer { fixture.remove() }
    if stale {
      let status = ReconciliationStatusStore(root: fixture.root)
      _ = try status.persist(
        manifest: ThemeGenerationReader(root: fixture.root).activeManifest(), results: [])
      try fixture.activate("tokyo-night")
    }
    let calls = Mutex(0)
    let coordinator = try ThemeActivationCoordinator(
      root: fixture.root, consumerPaths: testConsumerPaths(homeDirectory: fixture.home),
      enabledAdapterIDs: [BordersAdapter.id, EzaAdapter.id],
      bordersManagedMode: BordersManagedMode(
        preflight: {}, inspect: { "fixture" },
        reconcile: {
          calls.withLock { $0 += 1 }
          throw BordersServiceError.blocked("must not re-enter lifecycle-owned Borders")
        }))
    let result = try await coordinator.reconcile(
      adapterIDs: [EzaAdapter.id], excludingAdapterIDs: [BordersAdapter.id])
    #expect(calls.withLock { $0 } == 0)
    #expect(result.record.results.map(\.adapterID) == [EzaAdapter.id])
  }

  @Test
  func changedExternalFallbackTargetModeBlocksNativeRestoration() async throws {
    let fixture = try ManagedBordersFixture(kind: "fallback", running: true)
    defer { fixture.remove() }
    let fallback = fixture.home.appending(path: ".bordersrc")
    let target = fixture.directory.appending(path: "external-rc")
    try FileManager.default.moveItem(at: fallback, to: target)
    try FileManager.default.createSymbolicLink(at: fallback, withDestinationURL: target)
    let digest = try #require(try fixture.digest(fixture.plan().output))
    #expect(try await fixture.apply(adopt: digest).succeeded)
    let actions = fixture.state.withLock { $0.actions }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    let result = try await fixture.teardown()
    #expect(!result.succeeded)
    #expect(result.output.contains("native restoration would chmod"))
    // Teardown rolls back to the managed executable, not the unsafe external target.
    #expect(fixture.state.withLock { $0.actions } == actions + ["restart", "#cba6f7"])
    #expect(try BoundedRegularFile.read(at: target).permissions == 0o644)
  }

  @Test
  func rollbackBeforeNativeAttemptDoesNotRequireExecutableExternalStartup() throws {
    let fixture = try ManagedBordersFixture(kind: "fallback", running: true)
    defer { fixture.remove() }
    let fallback = fixture.home.appending(path: ".bordersrc")
    let target = fixture.directory.appending(path: "external-rc")
    try FileManager.default.moveItem(at: fallback, to: target)
    try FileManager.default.createSymbolicLink(at: fallback, withDestinationURL: target)
    try fixture.stageUnverifiedApply()
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    #expect(try store.readTransaction()?.bordersRuntimeAttempted == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    #expect(
      try EnvironmentApplyCommandRunner(
        prerequisites: .assumed, theme: nil, verifier: .assumed, bordersRuntime: fixture.runtime
      ).finishDeferredApply(stateRoot: fixture.root, homeDirectory: fixture.home, commit: false))
    #expect(fixture.state.withLock { $0.actions.isEmpty && $0.running && $0.pid == 100 })
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership() == nil)
    #expect(try BoundedRegularFile.read(at: target).permissions == 0o644)
    try fixture.verifyOriginal()
  }

  @Test
  func planningReportsReadOnlyProviderCompatibilityFailure() throws {
    let fixture = try ManagedBordersFixture(kind: "absent", running: false)
    defer { fixture.remove() }
    fixture.state.withLock { $0.incompatible = true }
    let plan = try fixture.plan()
    #expect(!plan.succeeded)
    #expect(plan.output.contains("unsupported provider compatibility"))
    #expect(fixture.state.withLock { $0.actions.isEmpty })
  }

  @Test
  func adoptionDigestBindsTheObservedServiceAndBlocksChangedPIDWithoutMutation() async throws {
    let fixture = try ManagedBordersFixture(kind: "file", running: true)
    defer { fixture.remove() }
    let digest = try #require(try fixture.digest(fixture.plan().output))
    fixture.state.withLock { $0.pid += 1 }
    let result = try await fixture.apply(adopt: digest)
    #expect(!result.succeeded)
    #expect(fixture.state.withLock { $0.actions.isEmpty })
    try fixture.verifyOriginal()
  }

  @Test(arguments: [false, true])
  func failedPaletteRequestRollsBackConfigAndPriorRunningState(running: Bool) async throws {
    let fixture = try ManagedBordersFixture(kind: "file", running: running)
    defer { fixture.remove() }
    let digest = try #require(try fixture.digest(fixture.plan().output))
    fixture.state.withLock { $0.failRequest = true }
    let result = try await fixture.apply(adopt: digest)
    #expect(!result.succeeded)
    #expect(fixture.state.withLock { $0.running } == running)
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readOwnership() == nil)
    #expect(try EnvironmentStateStore(stateRoot: fixture.root).readTransaction() == nil)
    try fixture.verifyOriginal()
  }

  @Test
  func appliedSelectionNotProfileEditsControlsLiveCanonicalRequests() async throws {
    let fixture = try ManagedBordersFixture(kind: "absent", running: false)
    defer { fixture.remove() }
    let result = try await fixture.apply()
    #expect(result.succeeded, "\(result.output)")
    try fixture.writeProfile(enabled: false)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.root, homeDirectory: fixture.home
      ).contains(BordersAdapter.id))
    let coordinator = try ThemeRuntimeSelection.activationCoordinator(
      stateRoot: fixture.root,
      consumerPaths: testConsumerPaths(homeDirectory: fixture.home),
      bordersRuntime: fixture.runtime)
    _ = try await coordinator.activate(
      package: ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")))
    #expect(fixture.state.withLock { $0.actions.last } == "#7aa2f7")
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded, "\(disabled.output)")
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.root, homeDirectory: fixture.home
      ).contains(BordersAdapter.id))
    #expect(!fixture.state.withLock { $0.running })
  }

  @Test
  func changedFallbackAndStoppedOwnedServiceAreVisibleDrift() async throws {
    let fixture = try ManagedBordersFixture(kind: "fallback", running: true)
    defer { fixture.remove() }
    let digest = try #require(try fixture.digest(fixture.plan().output))
    #expect(try await fixture.apply(adopt: digest).succeeded)
    fixture.state.withLock { $0.running = false }
    #expect(try !fixture.plan().succeeded)
    fixture.state.withLock { $0.running = true }
    try Data("external new fallback".utf8).write(to: fixture.home.appending(path: ".bordersrc"))
    let teardown = try await fixture.teardown()
    #expect(!teardown.succeeded)
    #expect(fixture.state.withLock { $0.running })
  }

  @Test
  func runningNativeConfigMustBeRestorableWithoutProviderChmod() throws {
    let fixture = try ManagedBordersFixture(kind: "file", running: true)
    defer { fixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.home.appending(path: ".config/borders/bordersrc").path)
    let plan = try fixture.plan()
    #expect(!plan.succeeded)
    #expect(plan.output.contains("native restoration would chmod"))
    #expect(fixture.state.withLock { $0.actions.isEmpty })
  }

  @Test(arguments: [false, true], [false, true])
  func interruptedNativeAttemptUsesExistingAggregateRollback(running: Bool, registrationOnly: Bool)
    throws
  {
    let fixture = try ManagedBordersFixture(kind: "file", running: running)
    defer { fixture.remove() }
    try fixture.stageUnverifiedApply()
    let store = EnvironmentStateStore(stateRoot: fixture.root)
    var interrupted = try #require(try store.readTransaction())
    interrupted.bordersRuntimeAttempted = true
    try store.writeTransaction(interrupted)
    // Simulate death after native start/restart but before recording verification.
    if running {
      try fixture.runtime.restart(fixture.home)
    } else {
      try fixture.runtime.start(fixture.home)
    }
    if registrationOnly {
      fixture.state.withLock {
        $0.running = false
        $0.interruptedRegistration = true
      }
    }
    #expect(
      try EnvironmentApplyCommandRunner(
        prerequisites: .assumed, theme: nil, verifier: .assumed, bordersRuntime: fixture.runtime
      ).finishDeferredApply(stateRoot: fixture.root, homeDirectory: fixture.home, commit: false))
    #expect(fixture.state.withLock { $0.running } == running)
    #expect(
      fixture.state.withLock { $0.actions }
        == (running ? ["restart", "restart"] : ["start", "stop"]))
    #expect(try store.readTransaction() == nil)
    #expect(try store.readOwnership() == nil)
    try fixture.verifyOriginal()
  }
}
