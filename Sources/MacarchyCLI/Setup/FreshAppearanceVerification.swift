import Foundation
import ThemeCore

/// Read-only post-consent checks in new processes from this exact executable.
/// The prompting process must not re-query its potentially stale verdict.
enum FreshAppearanceVerification {
  enum Failure: Error, CustomStringConvertible, Equatable {
    case unconfirmed
    case timedOut
    case invalidReply

    var description: String {
      switch self {
      case .unconfirmed:
        "[consent_unconfirmed] Native consent completed, but access is not yet confirmed. If you chose Allow, the grant may not yet be visible. Run macarchy setup check-appearance --json in this same Terminal to check without prompting or changing appearance. Configuration is retained; no grant is assumed."
      case .timedOut:
        "[timed_out] Fresh System Events verification exceeded its deadline. Run macarchy setup check-appearance --json in this same Terminal. Configuration is retained."
      case .invalidReply:
        "[verification_failed] Fresh System Events check returned an invalid or inconsistent reply; no grant is assumed. Run macarchy setup check-appearance --json in this same Terminal."
      }
    }
  }

  static func verify(
    executableURL: URL = RuntimeEnvironment.live.executableURL,
    runner: ProcessRunner = .live,
    now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) throws {
    let deadline = now() + 5
    // Each completed consent-required check permits another fresh observation.
    // Both the deadline and attempt cap bound work; no sleep or repeated prompt.
    for _ in 0..<3 {
      let remaining = deadline - now()
      guard remaining > 0 else { throw Failure.unconfirmed }
      let result: ProcessResult
      do {
        result = try runner.run(
          .init(
            executableURL: executableURL, arguments: ["setup", "check-appearance", "--json"],
            timeout: remaining))
      } catch ProcessRunnerError.timedOut { throw Failure.timedOut }
      guard
        let reply = try? JSONDecoder().decode(
          SetupAppearanceCheck.self, from: Data(result.output.utf8)),
        result.terminationStatus == reply.exitStatus
      else { throw Failure.invalidReply }
      if reply.status == .notGranted && reply.code == -1744 {
        if now() >= deadline { throw Failure.unconfirmed }
        continue
      }
      guard now() < deadline else { throw Failure.timedOut }
      switch (reply.status, reply.code) {
      case (.verified, nil): return
      case (.notGranted, -1743):
        throw MacOSAppearanceEvents.Failure(reply.message, code: reply.code)
      case (.failed, .some) where reply.code != -1743 && reply.code != -1744:
        throw MacOSAppearanceEvents.Failure(reply.message, code: reply.code)
      default: throw Failure.invalidReply
      }
    }
    throw Failure.unconfirmed
  }
}
