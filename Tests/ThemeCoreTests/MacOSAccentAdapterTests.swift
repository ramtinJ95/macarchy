import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSAccentAdapterTests {
  @Test func firstWriteRecordsOriginalBeforeMutationAndLaterWritesPreserveIt() throws {
    try withTemporaryRoot(named: "accent-original") { (root: URL) throws in
      let fake = AccentFake(.graphite, root: root)
      let adapter = MacOSAccentAdapter(root: root, helper: fake.helper)
      #expect(adapter.reconcileHoldingActivationLock(desired: .blue).status == .applied)
      #expect(try MacOSAccentStore(root: root).load() == .init(original: .graphite, applied: .blue))
      #expect(adapter.reconcileHoldingActivationLock(desired: .red).status == .applied)
      #expect(try MacOSAccentStore(root: root).load() == .init(original: .graphite, applied: .red))
      #expect(fake.writes == [.blue, .red])
    }
  }

  @Test(arguments: [MacOSAccent.hardware, .blue])
  func hardwareAndAlreadyMatchingValuesAreNotWritten(current: MacOSAccent) throws {
    try withTemporaryRoot(named: "accent-no-write") { (root: URL) throws in
      let fake = AccentFake(current, root: root)
      let result = MacOSAccentAdapter(root: root, helper: fake.helper)
        .reconcileHoldingActivationLock(desired: .blue)
      #expect(result.status == (current == .blue ? .applied : .failed))
      if current == .hardware {
        #expect(
          result.message
            == "the hardware-matched accent cannot be restored once changed, so it is left unchanged"
        )
      }
      #expect(fake.writes.isEmpty)
      #expect(try MacOSAccentStore(root: root).load() == nil)
    }
  }

  @Test(arguments: [MacOSAccent.blue, .graphite, .green])
  func restoreUsesThreeWayRuleAndDryRunNeverWrites(current: MacOSAccent) throws {
    try withTemporaryRoot(named: "accent-restore") { (root: URL) throws in
      let store = MacOSAccentStore(root: root)
      try store.persist(.init(original: .graphite, applied: .blue))
      let fake = AccentFake(current, root: root)
      let adapter = MacOSAccentAdapter(root: root, helper: fake.helper)
      let plan = try adapter.restorationPlan()
      #expect(fake.writes.isEmpty)
      #expect(!plan.mutated)
      let result = try adapter.restoreHoldingActivationLock()
      #expect(result.consumesRecord)
      #expect(fake.writes == (current == .blue ? [.graphite] : []))
      if current == .green {
        #expect(result.message == "Kept the green accent, which was changed after setup.")
      }
      // Enclosing teardown must commit before deleting the evidence.
      #expect(try store.load() != nil)
      try store.remove()
      #expect(try store.load() == nil)
    }
  }

  @Test(arguments: ["unsupported", "failed", "garbled", "timeout", "crash", "mismatch"])
  func failuresDoNotLoseOriginals(mode: String) throws {
    try withTemporaryRoot(named: "accent-failure") { (root: URL) throws in
      let fake = AccentFake(.blue, root: root, mode: mode)
      let store = MacOSAccentStore(root: root)
      let original = MacOSAccentRecord(original: .graphite, applied: .blue)
      try store.persist(original)
      let adapter = MacOSAccentAdapter(root: root, helper: fake.helper)
      let result = adapter.reconcileHoldingActivationLock(desired: .red)
      #expect(result.status == (mode == "unsupported" ? .unsupported : .failed))
      #expect(try store.load() == original)
      #expect(throws: (any Error).self) { try adapter.restoreHoldingActivationLock() }
      #expect(try store.load() == original)
    }
  }

  @Test func missingHelperCannotWriteOrDropRestorationEvidence() throws {
    try withTemporaryRoot(named: "accent-missing") { (root: URL) throws in
      let adapter = MacOSAccentAdapter(
        root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      #expect(adapter.reconcileHoldingActivationLock(desired: .blue).status == .unsupported)
      let store = MacOSAccentStore(root: root)
      try store.persist(.init(original: .graphite, applied: .blue))
      #expect(throws: (any Error).self) { try adapter.restorationPlan() }
      #expect(throws: (any Error).self) { try adapter.restoreHoldingActivationLock() }
      #expect(try store.load() != nil)
    }
  }

  @Test func unreadableRecordPreventsNativeWrites() throws {
    try withTemporaryRoot(named: "accent-corrupt") { (root: URL) throws in
      let store = MacOSAccentStore(root: root)
      try store.persist(.init(original: .graphite, applied: .blue))
      try Data("broken".utf8).write(to: store.url)
      let fake = AccentFake(.blue, root: root)
      #expect(
        MacOSAccentAdapter(root: root, helper: fake.helper)
          .reconcileHoldingActivationLock(desired: .red).status == .failed)
      #expect(fake.writes.isEmpty)
      #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }
  }
}

private final class AccentFake: Sendable {
  struct State {
    var current: MacOSAccent
    var writes: [MacOSAccent] = []
  }
  let state: Mutex<State>
  let root: URL
  let mode: String
  init(_ current: MacOSAccent, root: URL, mode: String = "success") {
    state = Mutex(State(current: current))
    self.root = root
    self.mode = mode
  }
  var writes: [MacOSAccent] { state.withLock { $0.writes } }
  var helper: MacOSLookHelper {
    MacOSLookHelper(
      executableURL: URL(filePath: "/usr/bin/true"),
      processRunner: ProcessRunner { request in
        #expect(request.timeout == 20)
        if request.arguments == ["check"] {
          return ProcessResult(
            terminationStatus: 0,
            output:
              "{\"ok\":true,\"value\":{\"build\":\"\(self.mode == "unsupported" ? "unknown" : "25G83")\",\"accent\":true}}"
          )
        }
        if request.arguments == ["get", "accent"] {
          return ProcessResult(
            terminationStatus: 0,
            output: "{\"ok\":true,\"value\":\(self.state.withLock { $0.current.rawValue })}")
        }
        #expect(try MacOSAccentStore(root: self.root).load() != nil)
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
        let raw = try #require(Int(request.arguments[2]))
        let value = try #require(MacOSAccent(rawValue: raw))
        self.state.withLock {
          $0.current = value
          $0.writes.append(value)
        }
        return ProcessResult(
          terminationStatus: 0, output: "{\"ok\":true,\"value\":\(value.rawValue)}")
      })
  }
}
