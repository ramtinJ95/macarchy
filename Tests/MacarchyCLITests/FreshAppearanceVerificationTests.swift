import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct FreshAppearanceVerificationTests {
  private static let executable = URL(filePath: "/exact/current/macarchy")

  private static func reply(
    _ status: SetupAppearanceCheck.Status, code: Int32? = nil, exit: Int32? = nil
  ) throws -> ProcessResult {
    let check = SetupAppearanceCheck(status: status, code: code, message: "native verdict")
    return .init(
      terminationStatus: exit ?? check.exitStatus,
      output: String(decoding: try JSONEncoder().encode(check), as: UTF8.self))
  }

  @Test func postAllowUsesOnlyFreshReadOnlyChildrenWithShrinkingDeadlines() throws {
    let requests = Mutex([ProcessRequest]())
    let clock = Mutex(100.0)
    try FreshAppearanceVerification.verify(
      executableURL: Self.executable,
      runner: .init { request in
        let count = requests.withLock {
          $0.append(request)
          return $0.count
        }
        clock.withLock { $0 += 0.5 }
        return try Self.reply(count == 1 ? .notGranted : .verified, code: count == 1 ? -1744 : nil)
      }, now: { clock.withLock { $0 } })
    let seen = requests.withLock { $0 }
    #expect(seen.count == 2)
    #expect(seen.map(\.timeout) == [5, 4.5])
    for request in seen {
      #expect(request.executableURL == Self.executable)
      #expect(request.arguments == ["setup", "check-appearance", "--json"])
      #expect(request.environmentOverrides.isEmpty)
      #expect(request.environmentRemovals.isEmpty)
    }
  }

  @Test func remainingConsentRequiredHasExplicitRecoveryAndAttemptBound() {
    let calls = Mutex(0)
    #expect(throws: FreshAppearanceVerification.Failure.unconfirmed) {
      try FreshAppearanceVerification.verify(
        runner: .init { _ in
          calls.withLock { $0 += 1 }
          return try Self.reply(.notGranted, code: -1744)
        }, now: { 0 })
    }
    #expect(calls.withLock { $0 } == 3)
    let message = FreshAppearanceVerification.Failure.unconfirmed.description
    #expect(message.contains("If you chose Allow"))
    #expect(message.contains("macarchy setup check-appearance --json"))
    #expect(!message.contains("permissions are incomplete"))
  }

  @Test func consentRequiredAtDeadlineIsUnconfirmedNotAssumedGranted() {
    let clock = Mutex(0.0)
    let calls = Mutex(0)
    #expect(throws: FreshAppearanceVerification.Failure.unconfirmed) {
      try FreshAppearanceVerification.verify(
        runner: .init { _ in
          calls.withLock { $0 += 1 }
          clock.withLock { $0 = 5 }
          return try Self.reply(.notGranted, code: -1744)
        }, now: { clock.withLock { $0 } })
    }
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: [Int32(-1743), -1712, -600, -1708])
  func denialTimeoutAndEventFailuresAreFinal(code: Int32) {
    let calls = Mutex(0)
    do {
      try FreshAppearanceVerification.verify(
        runner: .init { _ in
          calls.withLock { $0 += 1 }
          return try Self.reply(code == -1743 ? .notGranted : .failed, code: code)
        }, now: { 0 })
      Issue.record("A negative child verdict is not a grant")
    } catch let failure as MacOSAppearanceEvents.Failure {
      #expect(failure.code == code)
      if code == -1712 { #expect(failure.description.contains("timed_out")) }
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(calls.withLock { $0 } == 1)
  }

  @Test func childDeadlineIsNamedAndDoesNotStartAnotherChild() {
    let calls = Mutex(0)
    #expect(throws: FreshAppearanceVerification.Failure.timedOut) {
      try FreshAppearanceVerification.verify(
        runner: .init { request in
          calls.withLock { $0 += 1 }
          throw ProcessRunnerError.timedOut(request.executableURL, request.timeout!)
        }, now: { 0 })
    }
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: [0, 1, 2, 3, 4, 5])
  func malformedAndInconsistentRepliesNeverAuthorize(mode: Int) {
    let calls = Mutex(0)
    #expect(throws: FreshAppearanceVerification.Failure.invalidReply) {
      try FreshAppearanceVerification.verify(
        runner: .init { _ in
          calls.withLock { $0 += 1 }
          switch mode {
          case 0: return .init(terminationStatus: 0, output: "not JSON")
          case 1: return try Self.reply(.verified, code: -1744)
          case 2: return try Self.reply(.verified, exit: 77)
          case 3: return try Self.reply(.notGranted, code: -600)
          case 4: return try Self.reply(.failed, code: -1743)
          default: return try Self.reply(.failed)
          }
        }, now: { 0 })
    }
    #expect(calls.withLock { $0 } == 1)
  }
}
