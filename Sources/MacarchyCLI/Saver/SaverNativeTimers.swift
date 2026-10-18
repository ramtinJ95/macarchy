import Foundation
import ThemeCore

/// A macOS idle timer that may come before Macarchy's. Macarchy only reads it.
enum NativeIdleTimer: Equatable, Sendable {
  case never
  /// Seconds without input.
  case after(Int)
  /// Never set, so macOS may apply a default of its own.
  case notSet
  /// Why it could not be read.
  case unreadable(String)

  var summary: String {
    switch self {
    case .never: "never"
    case .after(let seconds): "after \(idleDuration(seconds)) idle"
    case .notSet:
      "not set explicitly, so macOS may apply its own default; see Start Screen Saver when "
        + "inactive in System Settings > Lock Screen"
    case .unreadable(let reason): "unknown, because \(reason)"
    }
  }

  var json: [String: Any] {
    var document: [String: Any] = ["state": "never", "seconds": NSNull(), "error": NSNull()]
    switch self {
    case .never:
      break
    case .after(let seconds):
      document["state"] = "after"
      document["seconds"] = seconds
    case .notSet:
      document["state"] = "notSet"
    case .unreadable(let reason):
      document["state"] = "unreadable"
      document["error"] = reason
    }
    return document
  }
}

/// The native screensaver's and display sleep's idle timers, either of which hides Macarchy's
/// screensaver when it is no longer than Macarchy's timeout.
struct SaverNativeTimers: Equatable, Sendable {
  let screensaver: NativeIdleTimer
  let displaySleep: NativeIdleTimer

  func warnings(timeout: Int) -> [String] {
    let macarchy = idleDuration(timeout)
    var warnings: [String] = []
    if case .after(let seconds) = screensaver, timeout >= seconds {
      warnings.append(
        "Warning: the macOS screensaver starts after \(idleDuration(seconds)) idle, no later than "
          + "Macarchy's \(macarchy), so Macarchy's screensaver will not show. In System Settings > "
          + "Lock Screen, set Start Screen Saver when inactive to longer than \(macarchy) or to "
          + "Never.")
    }
    if case .after(let seconds) = displaySleep, timeout >= seconds {
      warnings.append(
        "Warning: the display turns off after \(idleDuration(seconds)) idle, no later than "
          + "Macarchy's \(macarchy), so Macarchy's screensaver will not show. In System Settings > "
          + "Lock Screen, set Turn display off when inactive to longer than \(macarchy) or to "
          + "Never.")
    }
    return warnings
  }

  static func read(processRunner: ProcessRunner) -> Self {
    Self(
      screensaver: screensaver(processRunner: processRunner),
      displaySleep: displaySleep(processRunner: processRunner))
  }

  /// The current host's `com.apple.screensaver idleTime` in seconds; 0 is never.
  static func screensaver(processRunner: ProcessRunner) -> NativeIdleTimer {
    let request = ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/defaults"),
      arguments: ["-currentHost", "read", "com.apple.screensaver", "idleTime"], timeout: 5)
    let result: ProcessResult
    do {
      result = try processRunner.run(request)
    } catch {
      return .unreadable("defaults failed: \(error)")
    }
    guard result.terminationStatus == 0 else {
      guard result.output.contains("does not exist") else {
        return .unreadable("defaults exited with status \(result.terminationStatus)")
      }
      return .notSet
    }
    guard let seconds = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
      seconds >= 0
    else { return .unreadable("defaults did not report a whole number of seconds") }
    return seconds == 0 ? .never : .after(seconds)
  }

  /// `pmset -g`'s `displaysleep` for the current power source, in minutes; 0 is never.
  static func displaySleep(processRunner: ProcessRunner) -> NativeIdleTimer {
    let request = ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/pmset"), arguments: ["-g"], timeout: 5)
    let result: ProcessResult
    do {
      result = try processRunner.run(request)
    } catch {
      return .unreadable("pmset failed: \(error)")
    }
    guard result.terminationStatus == 0 else {
      return .unreadable("pmset exited with status \(result.terminationStatus)")
    }
    for line in result.output.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.first == "displaysleep" else { continue }
      guard fields.count > 1, let minutes = Int(fields[1]), minutes >= 0 else {
        return .unreadable("pmset did not report displaysleep as a whole number of minutes")
      }
      return minutes == 0 ? .never : .after(minutes * 60)
    }
    return .unreadable("pmset did not report displaysleep")
  }
}
