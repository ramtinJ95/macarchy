import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSIconStyleAdapterTests {
  @Test func firstWriteRecordsOriginalBeforeMutationAndLaterWritesPreserveIt() throws {
    try withTemporaryRoot(named: "icon-style-original") { (root: URL) throws in
      let fake = IconStyleFake(IconStyleFixtureValues.original, root: root)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.applied).status
          == .applied)
      #expect(
        try MacOSIconStyleStore(root: root).load()
          == .init(
            original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending).status
          == .applied)
      #expect(
        try MacOSIconStyleStore(root: root).load()
          == .init(
            original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.pending))
      #expect(fake.writes == [IconStyleFixtureValues.applied, IconStyleFixtureValues.pending])
    }
  }

  @Test func matchingAndUnsetThemesNeverWrite() throws {
    try withTemporaryRoot(named: "icon-style-no-write") { (root: URL) throws in
      let fake = IconStyleFake(IconStyleFixtureValues.applied, root: root)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.applied).status
          == .applied)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: nil).message
          == "theme does not set an icon style")
      #expect(fake.writes.isEmpty)
      #expect(try MacOSIconStyleStore(root: root).load() == nil)
      let missing = MacOSIconStyleAdapter(
        root: root,
        helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      #expect(missing.reconcileHoldingActivationLock(desired: nil).status == .applied)
    }
  }

  @Test func nonTintedTargetsJournalTheEffectiveTripleAndKeepTint() throws {
    try withTemporaryRoot(named: "icon-style-keep-tint") { (root: URL) throws in
      let fake = IconStyleFake(IconStyleFixtureValues.applied, root: root)
      let target = MacOSIconStyle(style: "RegularDark", tint: "-", custom: nil)
      let expected = MacOSIconStyle(style: "RegularDark", tint: "Other", custom: "#0011ff")
      #expect(
        MacOSIconStyleAdapter(root: root, helper: fake.helper)
          .reconcileHoldingActivationLock(desired: target).status == .applied)
      #expect(fake.current == expected)
      #expect(
        try MacOSIconStyleStore(root: root).load()
          == .init(original: IconStyleFixtureValues.applied, applied: expected))
    }
  }

  @Test func originalHardwareTintRestoresStyleOnlyAndReportsTheLimit() throws {
    try withTemporaryRoot(named: "icon-style-hardware") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      let original = MacOSIconStyle(style: "RegularLight", tint: "Hardware", custom: nil)
      try store.persist(.init(original: original, applied: IconStyleFixtureValues.applied))
      let fake = IconStyleFake(IconStyleFixtureValues.applied, root: root)
      let result = try MacOSIconStyleAdapter(root: root, helper: fake.helper)
        .restoreHoldingActivationLock()
      #expect(fake.current == .init(style: "RegularLight", tint: "Other", custom: "#0011ff"))
      #expect(result.message?.contains("Original hardware tint cannot be restored") == true)
      #expect(result.consumesRecord)
    }
  }

  @Test(arguments: [
    IconStyleFixtureValues.applied, IconStyleFixtureValues.original,
    IconStyleFixtureValues.external,
  ])
  func restoreUsesThreeWayRuleAndDryRunNeverWrites(current: MacOSIconStyle) throws {
    try withTemporaryRoot(named: "icon-style-restore") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      try store.persist(
        .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      let fake = IconStyleFake(current, root: root)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      let plan = try adapter.restorationPlan()
      #expect(fake.writes.isEmpty)
      #expect(!plan.mutated)
      let result = try adapter.restoreHoldingActivationLock()
      #expect(result.consumesRecord)
      #expect(
        fake.writes
          == (current == IconStyleFixtureValues.applied ? [IconStyleFixtureValues.original] : []))
      if current == IconStyleFixtureValues.external {
        #expect(
          result.message
            == "Kept the ClearLight / Green / no custom tint icon style, which was changed after setup."
        )
      }
      // Enclosing teardown must commit before deleting the evidence.
      #expect(try store.load() != nil)
      try store.remove()
      #expect(try store.load() == nil)
    }
  }

  @Test(arguments: ["unsupported", "failed", "garbled", "timeout", "crash", "mismatch"])
  func failuresDoNotLoseOriginals(mode: String) throws {
    try withTemporaryRoot(named: "icon-style-failure") { (root: URL) throws in
      let fake = IconStyleFake(IconStyleFixtureValues.applied, root: root, mode: mode)
      let store = MacOSIconStyleStore(root: root)
      let original = MacOSIconStyleRecord(
        original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied)
      try store.persist(original)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      let result = adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending)
      #expect(result.status == (mode == "unsupported" ? .unsupported : .failed))
      let retained = MacOSIconStyleRecord(
        original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied,
        pending: mode == "unsupported" ? nil : IconStyleFixtureValues.pending)
      #expect(try store.load() == retained)
      #expect(throws: (any Error).self) { try adapter.restoreHoldingActivationLock() }
      #expect(try store.load() == retained)
    }
  }

  @Test(arguments: ["crash", "timeout", "garbled", "record-write"], [false, true])
  func interruptedNativeWriteRestoresTheOriginal(mode: String, laterWrite: Bool) throws {
    try withTemporaryRoot(named: "icon-style-interrupted-set") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      if laterWrite {
        try store.persist(
          .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      }
      let current: MacOSIconStyle =
        laterWrite ? IconStyleFixtureValues.applied : IconStyleFixtureValues.original
      let fake = IconStyleFake(current, root: root, mode: "mutating-" + mode)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending).status
          == .failed)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: store.url.deletingLastPathComponent().path)
      #expect(fake.current == IconStyleFixtureValues.pending)
      #expect(
        try store.load()
          == .init(
            original: IconStyleFixtureValues.original, applied: current,
            pending: IconStyleFixtureValues.pending))
      let plan = try adapter.restorationPlan()
      #expect(
        plan.message
          == "Would restore the original RegularLight icon style. Tint restoration uses eight-bit sRGB precision."
      )
      #expect(fake.current == IconStyleFixtureValues.pending)
      let restored = try adapter.restoreHoldingActivationLock()
      #expect(
        restored.message
          == "Restored the original RegularLight icon style. Tint restoration uses eight-bit sRGB precision."
      )
      #expect(fake.current == IconStyleFixtureValues.original)
      #expect(try store.load()?.pending == IconStyleFixtureValues.pending)
    }
  }

  @Test(arguments: ["crash", "timeout", "garbled", "record-write"])
  func alreadyDesiredFinalizesInterruptedWriteWithoutAnotherSet(mode: String) throws {
    try withTemporaryRoot(named: "icon-style-interrupted-confirm") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      let fake = IconStyleFake(
        IconStyleFixtureValues.original, root: root, mode: "mutating-" + mode)
      let adapter = MacOSIconStyleAdapter(root: root, helper: fake.helper)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending).status
          == .failed)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: store.url.deletingLastPathComponent().path)
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending).status
          == .applied)
      #expect(
        try store.load()
          == .init(
            original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.pending))
      #expect(fake.writes == [IconStyleFixtureValues.pending])
    }
  }

  @Test func observedPendingValueIsOwnedBeforeAttemptingAnotherTarget() throws {
    try withTemporaryRoot(named: "icon-style-interrupted-next-theme") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      try store.persist(
        .init(
          original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied,
          pending: IconStyleFixtureValues.pending))
      let fake = IconStyleFake(IconStyleFixtureValues.pending, root: root, mode: "failed")
      #expect(
        MacOSIconStyleAdapter(root: root, helper: fake.helper)
          .reconcileHoldingActivationLock(desired: IconStyleFixtureValues.next).status == .failed)
      #expect(
        try store.load()
          == .init(
            original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.pending,
            pending: IconStyleFixtureValues.next))
      let recovery = IconStyleFake(IconStyleFixtureValues.pending, root: root)
      let result = try MacOSIconStyleAdapter(root: root, helper: recovery.helper)
        .restoreHoldingActivationLock()
      #expect(
        result.message
          == "Restored the original RegularLight icon style. Tint restoration uses eight-bit sRGB precision."
      )
      #expect(recovery.current == IconStyleFixtureValues.original)
    }
  }

  @Test func invalidRecordsAreRejectedAndLegacyRecordsHaveNoPendingValue() throws {
    try withTemporaryRoot(named: "icon-style-record-version") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      try store.persist(
        .init(
          original: IconStyleFixtureValues.original,
          applied: IconStyleFixtureValues.applied,
          pending: .init(style: "RegularDark", tint: "-", custom: nil)))
      #expect(throws: MacOSLookError.self) { try store.load() }
      try store.persist(
        .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      let object =
        try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
      #expect(object["pending"] == nil)
      #expect(try store.load()?.pending == nil)
    }
  }

  @Test func missingHelperCannotWriteOrDropRestorationEvidence() throws {
    try withTemporaryRoot(named: "icon-style-missing") { (root: URL) throws in
      let adapter = MacOSIconStyleAdapter(
        root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      #expect(
        adapter.reconcileHoldingActivationLock(desired: IconStyleFixtureValues.applied).status
          == .unsupported)
      let store = MacOSIconStyleStore(root: root)
      try store.persist(
        .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      #expect(throws: (any Error).self) { try adapter.restorationPlan() }
      #expect(throws: (any Error).self) { try adapter.restoreHoldingActivationLock() }
      #expect(try store.load() != nil)
    }
  }

  @Test func unreadableRecordPreventsNativeWrites() throws {
    try withTemporaryRoot(named: "icon-style-corrupt") { (root: URL) throws in
      let store = MacOSIconStyleStore(root: root)
      try store.persist(
        .init(original: IconStyleFixtureValues.original, applied: IconStyleFixtureValues.applied))
      try Data("broken".utf8).write(to: store.url)
      let fake = IconStyleFake(IconStyleFixtureValues.applied, root: root)
      #expect(
        MacOSIconStyleAdapter(root: root, helper: fake.helper)
          .reconcileHoldingActivationLock(desired: IconStyleFixtureValues.pending).status == .failed
      )
      #expect(fake.writes.isEmpty)
      #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
  }
}

private final class IconStyleFake: Sendable {
  struct State {
    var current: MacOSIconStyle
    var writes: [MacOSIconStyle] = []
  }
  let state: Mutex<State>
  let root: URL
  let mode: String
  init(_ current: MacOSIconStyle, root: URL, mode: String = "success") {
    state = Mutex(State(current: current))
    self.root = root
    self.mode = mode
  }
  var writes: [MacOSIconStyle] { state.withLock { $0.writes } }
  var current: MacOSIconStyle { state.withLock { $0.current } }
  var helper: MacOSLookHelper {
    MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunner { request in
        #expect(request.timeout == 20)
        if request.arguments == ["check"] {
          return ProcessResult(
            terminationStatus: 0,
            output:
              "{\"ok\":true,\"value\":{\"build\":\"\(self.mode == "unsupported" ? "unknown" : "25G83")\",\"accent\":true,\"iconStyle\":true}}"
          )
        }
        if request.arguments == ["get", "icon-style"] {
          return ProcessResult(
            terminationStatus: 0,
            output: self.current.fixtureReply)
        }
        #expect(try MacOSIconStyleStore(root: self.root).load() != nil)
        if self.mode.hasPrefix("mutating-") {
          let value = MacOSIconStyle(
            style: request.arguments[2], tint: request.arguments[3],
            custom: request.arguments.count == 5 ? request.arguments[4] : nil
          ).keepingTint(from: self.current)
          let first = self.state.withLock { state in
            let first = state.writes.isEmpty
            state.current = value
            state.writes.append(value)
            return first
          }
          if first {
            #expect(try MacOSIconStyleStore(root: self.root).load()?.pending == value)
            switch self.mode {
            case "mutating-timeout": throw ProcessRunnerError.timedOut(request.executableURL, 20)
            case "mutating-crash":
              return ProcessResult(terminationStatus: 139, output: "Segmentation fault")
            case "mutating-garbled":
              return ProcessResult(terminationStatus: 0, output: "garbled after native write")
            case "mutating-record-write":
              try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: MacOSIconStyleStore(root: self.root).url.deletingLastPathComponent()
                  .path
              )
            default: Issue.record("Unexpected mutating failure mode")
            }
          }
          return ProcessResult(
            terminationStatus: 0, output: value.fixtureReply)
        }
        switch self.mode {
        case "timeout": throw ProcessRunnerError.timedOut(request.executableURL, 20)
        case "crash": return ProcessResult(terminationStatus: 139, output: "Segmentation fault")
        case "garbled": return ProcessResult(terminationStatus: 0, output: "garbled")
        case "failed", "mismatch":
          return ProcessResult(
            terminationStatus: 1,
            output: #"{"ok":false,"error":"accent readback mismatch; reverted"}"#)
        default: break
        }
        let value = MacOSIconStyle(
          style: request.arguments[2], tint: request.arguments[3],
          custom: request.arguments.count == 5 ? request.arguments[4] : nil
        ).keepingTint(from: self.current)
        self.state.withLock {
          $0.current = value
          $0.writes.append(value)
        }
        return ProcessResult(
          terminationStatus: 0, output: value.fixtureReply)
      })
  }
}
