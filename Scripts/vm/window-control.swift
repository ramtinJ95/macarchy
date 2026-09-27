// Developer-only helper. Never request TCC permission or capture the desktop.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ControlError: Error {
  case invalidArguments
  case permissionsMissing
  case wrongProcess
  case windowNotReady
  case activationFailed
  case eventCreationFailed
}

func emit(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

func permissions() -> [String: Bool] {
  ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()]
}

func targetWindow(pid: pid_t, executable: String, name: String) throws -> (
  NSRunningApplication, CGWindowID
) {
  guard permissions().values.allSatisfy({ $0 }) else { throw ControlError.permissionsMissing }
  guard let app = NSRunningApplication(processIdentifier: pid) else {
    throw ControlError.windowNotReady
  }
  guard !app.isTerminated,
    app.executableURL?.standardizedFileURL.path
      == URL(fileURLWithPath: executable).standardizedFileURL.path
  else { throw ControlError.wrongProcess }
  guard
    let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else { throw ControlError.windowNotReady }
  let matches = windows.filter {
    ($0[kCGWindowOwnerPID as String] as? Int32) == pid
      && ($0[kCGWindowName as String] as? String) == name
      && ($0[kCGWindowLayer as String] as? Int) == 0
  }
  guard matches.count == 1,
    let number = matches[0][kCGWindowNumber as String] as? UInt32
  else { throw ControlError.windowNotReady }
  return (app, number)
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  if args == ["preflight"] {
    try emit(permissions())
  } else {
    guard args.count == 4, ["window", "space"].contains(args[0]),
      let pid = Int32(args[1]), pid > 0
    else { throw ControlError.invalidArguments }
    let (app, window) = try targetWindow(pid: pid, executable: args[2], name: args[3])
    if args[0] == "space" {
      // Activate only the verified owned Tart process; never send global input.
      guard app.activate() else { throw ControlError.activationFailed }
      let deadline = Date().addingTimeInterval(2)
      while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw ControlError.activationFailed
      }
      guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)
      else { throw ControlError.eventCreationFailed }
      down.flags = []
      up.flags = []
      down.postToPid(pid)
      up.postToPid(pid)
    }
    try emit(["pid": pid, "window_id": window, "action": args[0]])
  }
} catch {
  try? emit(["error": String(describing: error)])
  if case ControlError.windowNotReady = error { exit(75) }
  exit(1)
}
