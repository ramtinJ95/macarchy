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
