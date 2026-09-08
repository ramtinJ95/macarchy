import ArgumentParser
import CoreServices
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PreferencesTests {
  @Test
  func disabledPlanAndNoOpApplyNeverInspectNativePreferencesOrCreateState() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let plan = try fixture.lifecycle.plan(context: fixture.context, desired: .init())
    #expect(plan.report.outcome == "disabled")
    #expect(plan.report.approvalDigest == nil)
    _ = try fixture.lifecycle.apply(context: fixture.context, desired: .init(), approval: nil)
    #expect(fixture.os.state.withLock { $0.reads.isEmpty && $0.writes.isEmpty })
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test
  func previewApprovalApplyNoOpAndTeardownPreserveUnselectedValues() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    let plan = try fixture.lifecycle.plan(context: fixture.context, desired: desired)
    #expect(plan.report.preferences.count == 1)
    #expect(plan.report.preferences.first?.current == false)
    #expect(plan.report.preferences.first?.target == true)
    #expect(plan.report.preferences.first?.action == "claim")
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
    #expect(throws: (any Error).self) {
      try fixture.lifecycle.apply(context: fixture.context, desired: desired, approval: nil)
    }
    #expect(fixture.os.state.withLock { $0.writes.isEmpty })
    let result = try fixture.lifecycle.apply(
      context: fixture.context, desired: desired, approval: plan.report.approvalDigest)
    #expect(result.outcome == "applied")
    #expect(
      try fixture.store.read().owned == [.init(key: .dockAutohide, original: false, applied: true)])
    let before = try Data(contentsOf: fixture.store.url)
    let noOp = try fixture.lifecycle.apply(
      context: fixture.context, desired: desired, approval: nil)
    #expect(noOp.outcome == "no_change")
    #expect(try Data(contentsOf: fixture.store.url) == before)
    #expect(fixture.os.state.withLock { $0.writes.count == 1 })
    #expect(
      fixture.lifecycle.inspect(context: fixture.context, desired: desired, status: true).succeeded)
    let preview = try fixture.lifecycle.teardown(context: fixture.context, dryRun: true)
    #expect(preview.preferences.first?.target == false)
    #expect(try Data(contentsOf: fixture.store.url) == before)
    _ = try fixture.lifecycle.teardown(context: fixture.context, dryRun: false)
    #expect(try fixture.store.read().owned.isEmpty)
    #expect(
      fixture.os.state.withLock {
        $0.values == [.dockAutohide: false, .finderShowExtensions: false]
      })
    #expect(fixture.os.state.withLock { !$0.reads.contains(.finderShowExtensions) })
  }

  @Test
  func alreadyMatchingValueStillRequiresOwnershipApprovalButNotASetter() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: false)
    _ = try fixture.apply(desired)
    #expect(try fixture.store.read().owned.first?.original == false)
    #expect(fixture.os.state.withLock { $0.writes.isEmpty })
    _ = try fixture.lifecycle.teardown(context: fixture.context, dryRun: false)
    #expect(fixture.os.state.withLock { $0.writes.isEmpty })
  }

  @Test
  func staleApprovalBindsObservedValuesIntentAndReceiptRoot() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    let approval = try fixture.lifecycle.plan(context: fixture.context, desired: desired).report
      .approvalDigest
    fixture.os.state.withLock { $0.values[.dockAutohide] = true }
    #expect(throws: (any Error).self) {
      try fixture.lifecycle.apply(context: fixture.context, desired: desired, approval: approval)
    }
    fixture.os.state.withLock { $0.values[.dockAutohide] = false }
    #expect(throws: (any Error).self) {
      try fixture.lifecycle.apply(
        context: fixture.context, desired: .init(enabled: true, dockAutohide: false),
        approval: approval)
    }
    let other = PreferencesContext(
      stateRoot: fixture.root.appending(path: "other"),
      targetIdentity: fixture.context.targetIdentity)
    #expect(throws: (any Error).self) {
      try fixture.lifecycle.apply(context: other, desired: desired, approval: approval)
    }
    #expect(fixture.os.state.withLock { $0.writes.isEmpty })
  }

  @Test
  func statusDistinguishesUnappliedIntentFromExternalDriftAndPreservesDrift() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    #expect(
      fixture.lifecycle.inspect(context: fixture.context, desired: desired, status: true).outcome
        == "changes_required")
    _ = try fixture.apply(desired)
    fixture.os.state.withLock { $0.values[.dockAutohide] = false }
    #expect(
      fixture.lifecycle.inspect(context: fixture.context, desired: desired, status: true).outcome
        == "drifted")
    #expect(throws: (any Error).self) {
      try fixture.lifecycle.teardown(context: fixture.context, dryRun: false)
    }
    #expect(fixture.os.state.withLock { $0.writes.count == 1 && $0.values[.dockAutohide] == false })
    #expect(try fixture.store.read().owned.count == 1)
  }

  @Test
  func removingOneKeyAndDisablingTheModuleRestoreOnlyTheirOriginals() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.apply(.init(enabled: true, dockAutohide: true, finderShowExtensions: true))
    _ = try fixture.apply(.init(enabled: true, finderShowExtensions: true))
    #expect(try fixture.store.read().owned.map(\.key) == [.finderShowExtensions])
    #expect(
      fixture.os.state.withLock {
        $0.values[.dockAutohide] == false && $0.values[.finderShowExtensions] == true
      })
    _ = try fixture.apply(.init(enabled: false, finderShowExtensions: true))
    #expect(try fixture.store.read().owned.isEmpty)
    #expect(fixture.os.state.withLock { $0.values[.finderShowExtensions] == false })
  }

  @Test
  func partialFailureRestoresImmediatelyPreviousManagedValuesNotOriginals() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.apply(.init(enabled: true, dockAutohide: true))
    let before = try fixture.store.read()
    fixture.os.state.withLock { $0.rejectWrite = 3 }
    #expect(throws: (any Error).self) {
      try fixture.apply(.init(enabled: true, dockAutohide: false, finderShowExtensions: true))
    }
    #expect(try fixture.store.read() == before)
    #expect(
      fixture.os.state.withLock {
        $0.values == [.dockAutohide: true, .finderShowExtensions: false]
      })
  }

  @Test(arguments: [false, true])
  func deferredApplyCanRollBackOrCommitWithoutLosingOriginalOwnership(commit: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.apply(.init(enabled: true, dockAutohide: true))
    let previous = try fixture.store.read().owned
    _ = try fixture.apply(.init(enabled: true, dockAutohide: false), deferFinalization: true)
    #expect(try fixture.store.read().pending?.phase == .ready)
    #expect(
      fixture.lifecycle.inspect(context: fixture.context, desired: .init()).outcome
        == "recovery_required")
    if commit {
      try fixture.lifecycle.commit(context: fixture.context)
      #expect(
        try fixture.store.read().owned == [
          .init(key: .dockAutohide, original: false, applied: false)
        ])
    } else {
      try fixture.lifecycle.rollback(context: fixture.context)
      #expect(try fixture.store.read().owned == previous)
      #expect(fixture.os.state.withLock { $0.values[.dockAutohide] == true })
    }
    #expect(try fixture.store.read().pending == nil)
  }

  @Test
  func finalizationAlsoVerifiesUnchangedRetainedPreferences() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.apply(.init(enabled: true, dockAutohide: true, finderShowExtensions: true))
    _ = try fixture.apply(
      .init(enabled: true, dockAutohide: false, finderShowExtensions: true), deferFinalization: true
    )
    fixture.os.state.withLock { $0.values[.finderShowExtensions] = false }
    #expect(throws: PreferencesError.self) {
      try fixture.lifecycle.commit(context: fixture.context)
    }
    #expect(try fixture.store.read().pending?.phase == .ready)
    try fixture.lifecycle.rollback(context: fixture.context)
    #expect(
      fixture.os.state.withLock {
        $0.values == [.dockAutohide: true, .finderShowExtensions: false]
      })
    #expect(try fixture.store.read().pending == nil)
  }

  @Test
  func interruptionAfterAcknowledgedWriteRecoversOnlyAttemptedKeys() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let lifecycle = PreferencesLifecycle(
      native: fixture.os.native, checkpoint: { _ in throw PreferencesInterruption.injected })
    let desired = MacOSPreferencesProfile(
      enabled: true, dockAutohide: true, finderShowExtensions: true)
    let plan = try lifecycle.plan(context: fixture.context, desired: desired)
    #expect(throws: PreferencesInterruption.self) {
      try lifecycle.apply(
        context: fixture.context, desired: desired, approval: plan.report.approvalDigest)
    }
    // The unattempted key now changes externally; recovery must leave it alone.
    fixture.os.state.withLock { $0.values[.finderShowExtensions] = true }
    try fixture.lifecycle.rollback(context: fixture.context)
    #expect(
      fixture.os.state.withLock {
        $0.values == [.dockAutohide: false, .finderShowExtensions: true]
      })
    #expect(try fixture.store.read().pending == nil)
  }

  @Test(arguments: [false, true])
  func unacknowledgedWritesRequireExplicitSettledAcknowledgment(crash: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    fixture.os.state.withLock {
      $0.uncertainWrite = 1
      $0.crash = crash
    }
    let directory = fixture.store.url.deletingLastPathComponent()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    let lifecycle = PreferencesLifecycle(
      native: .init(
        read: fixture.os.native.read,
        write: { key, value in
          // The uncertainty journal exists before the setter. Losing write access
          // now must not replace an uncertain OS outcome with a receipt error.
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
          try fixture.os.native.write(key, value)
        }))
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    let approval = try lifecycle.plan(context: fixture.context, desired: desired).report
      .approvalDigest
    do {
      _ = try lifecycle.apply(context: fixture.context, desired: desired, approval: approval)
      Issue.record("An unacknowledged setter must not succeed")
    } catch {
      if crash {
        #expect(error is PreferencesInterruption)
      } else {
        guard case PreferencesError.uncertain = error else {
          Issue.record("Lost the uncertain write outcome: \(error)")
          return
        }
        let report = PreferencesReport.failure(error, context: fixture.context)
        #expect(report.mutated == nil)
        #expect(try jsonObject(report.render(json: true))["mutated"] == nil)
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try fixture.store.read().pending?.uncertainWrite == true)
    #expect(throws: (any Error).self) { try fixture.lifecycle.rollback(context: fixture.context) }
    #expect(fixture.os.state.withLock { $0.writes.count == 1 })
    try fixture.lifecycle.rollback(context: fixture.context, acknowledgeUncertainWrite: true)
    #expect(fixture.os.state.withLock { $0.values[.dockAutohide] == false })
    #expect(try fixture.store.read().pending == nil)
  }

  @Test
  func failedRollbackRetainsEvidenceAndRecoversWithoutReplayingApply() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let lifecycle = PreferencesLifecycle(
      native: fixture.os.native,
      checkpoint: { _ in
        throw PreferencesError.unavailable("injected after reply")
      })
    fixture.os.state.withLock { $0.rejectWrite = 2 }
    let desired = MacOSPreferencesProfile(enabled: true, dockAutohide: true)
    let plan = try lifecycle.plan(context: fixture.context, desired: desired)
    #expect(throws: (any Error).self) {
      try lifecycle.apply(
        context: fixture.context, desired: desired, approval: plan.report.approvalDigest)
    }
    #expect(try fixture.store.read().pending?.phase == .rollingBack)
    try fixture.lifecycle.rollback(context: fixture.context)
    #expect(fixture.os.state.withLock { $0.values[.dockAutohide] == false && $0.writes.count == 3 })
    #expect(try fixture.store.read().pending == nil)
  }

  @Test
  func rejectsUnknownReceiptFieldsDifferentMachineSymlinksAndInconsistentJournals() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.apply(.init(enabled: true, dockAutohide: true))
    let data = try Data(contentsOf: fixture.store.url)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["unknown"] = true
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.store.url)
    #expect(throws: (any Error).self) { try fixture.store.read() }
    try data.write(to: fixture.store.url)
    #expect(throws: (any Error).self) {
      try PreferencesStore(
        context: .init(stateRoot: fixture.context.stateRoot, targetIdentity: "another-mac")
      ).read()
    }
    var state = try fixture.store.read()
    state.pending = .init(
      after: [], changes: [.init(key: .dockAutohide, before: true, after: true)])
    #expect(throws: (any Error).self) { try fixture.store.write(state) }
    let outside = fixture.root.appending(path: "external.json")
    try FileManager.default.moveItem(at: fixture.store.url, to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.store.url, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try fixture.store.read() }
    #expect(try Data(contentsOf: outside) == data)
  }

  @Test
  func nativeOutboundRequestsUseOnlyPublicAllowlistedPropertiesAndSuppressConsent() throws {
    #expect(NativePreferenceEvent.sendOptions.contains(.neverInteract))
    #expect(
      NativePreferenceEvent.sendOptions.contains(
        .init(rawValue: UInt(kAEDoNotPromptForUserConsent))))
    #expect(throws: (any Error).self) {
      try NativePreferenceEvent.requireSupportedVersion(
        .init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }
    try NativePreferenceEvent.requireSupportedVersion(
      .init(majorVersion: 26, minorVersion: 3, patchVersion: 1))
    for key in MacOSPreference.allCases {
      let get = try NativePreferenceEvent.request(key: key, value: nil, target: .null())
      let set = try NativePreferenceEvent.request(key: key, value: true, target: .null())
      #expect(get.eventClass == AEEventClass(kAECoreSuite))
      #expect(get.eventID == AEEventID(kAEGetData))
      #expect(set.eventID == AEEventID(kAESetData))
      #expect(set.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.booleanValue == true)
      #expect(get.paramDescriptor(forKeyword: AEKeyword(keyAEData)) == nil)
      let specifier = try #require(get.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
      let expected: OSType = key == .dockAutohide ? 0x6461_6864 : 0x7073_6e78
      #expect(specifier.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == expected)
      #expect(
        NativePreferenceEvent.application(for: key).url.path.hasPrefix(
          "/System/Library/CoreServices/"))
    }
  }

  @Test(arguments: [false, true])
  func standaloneRecoveryCannotCrossUnifiedCommitPoint(committing: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let context = try PreferencesContext.live(
      stateRoot: fixture.context.stateRoot,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    let store = PreferencesStore(context: context)
    // A claim without a setter allows the real command/locking boundary to be
    // exercised without observing or writing this user's actual preferences.
    var state = PreferencesState(targetIdentity: context.targetIdentity)
    state.pending = .init(
      after: [.init(key: .dockAutohide, original: false, applied: false)],
      changes: [.init(key: .dockAutohide, before: false, after: false)])
    try store.write(state)
    try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).write(
      .init(
        operation: .apply, phase: committing ? .committing : .mutating,
        stages: [.preferences], desiredAppearance: .dark,
        contextDigest: "sha256:" + String(repeating: "a", count: 64)))
    var command = try #require(
      Macarchy.parseAsRoot([
        "preferences", "recover", "--state-root", context.stateRoot.path, "--json",
      ]) as? PreferencesCommand.Recover)
    if committing {
      await #expect(throws: ExitCode.self) { try await command.run() }
      #expect(try store.read() == state)
    } else {
      try await command.run()
      #expect(try store.read().pending == nil)
    }
    #expect(try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() != nil)
  }

  private struct Fixture {
    let root: URL
    let context: PreferencesContext
    let os = MemoryPreferences()
    var lifecycle: PreferencesLifecycle { .init(native: os.native) }
    var store: PreferencesStore { .init(context: context) }

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-preferences-test-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      context = .init(
        stateRoot: root.appending(path: "state"), targetIdentity: "test-user-and-machine")
    }

    func apply(_ desired: MacOSPreferencesProfile, deferFinalization: Bool = false) throws
      -> PreferencesReport
    {
      let approval = try lifecycle.plan(context: context, desired: desired).report.approvalDigest
      return try lifecycle.apply(
        context: context, desired: desired, approval: approval, deferFinalization: deferFinalization
      )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  final class MemoryPreferences: Sendable {
    struct State {
      var values: [MacOSPreference: Bool] = [.dockAutohide: false, .finderShowExtensions: false]
      var reads: [MacOSPreference] = []
      var writes: [MacOSPreference] = []
      var rejectWrite: Int?
      var uncertainWrite: Int?
      var crash = false
    }
    let state = Mutex(State())
    var native: NativeMacOSPreferences {
      .init(
        read: { key in
          self.state.withLock {
            $0.reads.append(key)
            return $0.values[key]!
          }
        },
        write: { key, value in
          try self.state.withLock { state in
            state.writes.append(key)
            if state.rejectWrite == state.writes.count {
              throw PreferencesError.unavailable("injected rejection")
            }
            state.values[key] = value
            if state.uncertainWrite == state.writes.count {
              if state.crash { throw PreferencesInterruption.injected }
              throw PreferencesError.uncertain("injected missing reply")
            }
          }
        })
    }
  }
}
