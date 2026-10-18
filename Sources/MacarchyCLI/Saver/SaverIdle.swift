import Foundation
import ThemeCore

/// `<state root>/run/saver-idle.json`, which exists while idle activation is on.
struct SaverIdleRecord: Codable, Equatable, Sendable {
  static let defaultTimeout = 5 * 60
  static let timeouts = 60...(4 * 60 * 60)
  /// Held by every change to the record and by each observer poll, from its read of the record
  /// until its start returns.
  static let lock = ProcessScopedFileLock<SaverError>(
    filename: "saver-idle.lock",
    cannotCreateRunDirectory: { url, error in SaverError("cannot create \(url.path): \(error)") },
    operationError: { operation, code in
      SaverError("cannot \(operation) the idle screensaver lock (errno \(code))")
    })

  /// Idle seconds before the saver starts.
  let timeout: Int
  let paused: Bool

  static func runState(stateRoot: URL) -> RunStateRecord<Self> {
    RunStateRecord("saver-idle.json", stateRoot: stateRoot) { Self.timeouts.contains($0.timeout) }
  }
}

/// "5 minutes", "1 hour 30 minutes" or "90 seconds".
func idleDuration(_ seconds: Int) -> String {
  func count(_ value: Int, _ unit: String) -> String {
    value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
  }
  guard seconds % 60 == 0 else { return count(seconds, "second") }
  let (hours, minutes) = (seconds / 60).quotientAndRemainder(dividingBy: 60)
  if hours == 0 { return count(minutes, "minute") }
  return minutes == 0 ? count(hours, "hour") : "\(count(hours, "hour")) \(count(minutes, "minute"))"
}
