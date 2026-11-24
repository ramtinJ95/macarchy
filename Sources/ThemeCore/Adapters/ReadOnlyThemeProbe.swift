import Foundation

/// Only the read-only subprocess belongs in this scope, never publication,
/// preflight, cache builds or provider activation. A deadline is not rejection.
enum ReadOnlyThemeProbe {
  // Fresh Homebrew installs measured 0.75/2.15/1.06s for Atuin/eza/Starship,
  // versus <0.01s warm. Leave bounded cold-start headroom, not an unbounded retry.
  static let timeout: TimeInterval = 5

  static func verify(
    adapterID: String, _ operation: () throws -> AdapterOutcome
  ) throws -> AdapterOutcome {
    do {
      return try operation()
    } catch let ProcessRunnerError.timedOut(_, seconds) {
      return AdapterOutcome(
        status: .verificationTimedOut,
        message:
          "\(adapterID) is not yet converged: read-only theme verification could not finish within \(seconds) s. "
          + "Configuration is retained; the next theme activation retries it, or run macarchy reconcile \(adapterID)."
      )
    }
  }
}
