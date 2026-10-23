/// Bounded transient retries; no file publication or repeated error logging.
struct FocusRingRetryPolicy {
  enum PaletteFailure: Equatable {
    case logAndRetry, retry, refuse
  }

  private var consecutivePaletteFailures = 0

  mutating func paletteFailed() -> PaletteFailure {
    consecutivePaletteFailures += 1
    if consecutivePaletteFailures >= 8 { return .refuse }
    return consecutivePaletteFailures == 1 ? .logAndRetry : .retry
  }

  mutating func paletteSucceeded() { consecutivePaletteFailures = 0 }

  enum SessionDecision: Equatable {
    case ready, wait, refuse
  }

  static func session(ready: Bool, elapsed: Double, managed: Bool) -> SessionDecision {
    if ready { return .ready }
    return managed && elapsed < 60 ? .wait : .refuse
  }

  enum RefreshDecision: Equatable {
    case waitOut, stop
  }

  /// A missing front process is always a state. Other refresh failures are passing
  /// window-server states once a refresh has worked, or during a managed helper's
  /// first minute (it may start mid-wake); otherwise they report an unusable system.
  static func refreshFailed(
    noFrontProcess: Bool, hasRefreshed: Bool, elapsed: Double, managed: Bool
  ) -> RefreshDecision {
    noFrontProcess || hasRefreshed || (managed && elapsed < 60) ? .waitOut : .stop
  }
}

/// Remembers when full refreshes started failing so stderr gets one line when an
/// outage starts and one when it ends, never one per retry. There is no give-up:
/// exiting would leave the outline gone, because launchd restarts the helper only
/// after a crash.
struct RefreshOutage {
  private var since: Double?

  /// `failure` is nil for a refresh that succeeded.
  mutating func observe(_ failure: String?, uptime: Double) -> String? {
    switch (failure, since) {
    case (let failure?, nil):
      since = uptime
      return "outline hidden: \(failure); retrying"
    case (nil, let start?):
      since = nil
      return "refreshes succeed again after \(Int(uptime - start))s"
    default:
      return nil
    }
  }
}
