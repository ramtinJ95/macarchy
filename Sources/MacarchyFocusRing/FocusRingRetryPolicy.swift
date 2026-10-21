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
}

/// Remembers when the front process went missing so stderr gets one line on entering
/// and one on leaving that state, never one per refresh. There is no give-up: exiting
/// would leave the outline gone, because launchd restarts the helper only after a crash.
struct FrontProcessAbsence {
  private var since: Double?

  mutating func observe(_ lookup: FrontLookup, uptime: Double) -> String? {
    switch (lookup, since) {
    case (.unavailable(let status), nil):
      since = uptime
      return "no front process (status \(status)); outline hidden until one returns"
    case (.available, let start?):
      since = nil
      return "front process is back after \(Int(uptime - start))s; refreshing the outline"
    default:
      return nil
    }
  }
}
