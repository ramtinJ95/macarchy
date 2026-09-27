// Developer-only helper. Never request TCC permission or capture the desktop.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Vision

enum ControlError: Error {
  case invalidArguments
  case permissionsMissing
  case wrongProcess
  case windowNotReady
  case foregroundChanged
  case eventCreationFailed
  case windowMoved
}

func emit(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

func permissions() -> [String: Bool] {
  ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()]
}

func targetWindow(pid: pid_t, executable: String, name: String) throws
  -> (
    NSRunningApplication, CGWindowID, CGRect
  )
{
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
      [.excludeDesktopElements],
      kCGNullWindowID) as? [[String: Any]]
  else { throw ControlError.windowNotReady }
  let matches = windows.filter {
    ($0[kCGWindowOwnerPID as String] as? Int32) == pid
      && ($0[kCGWindowName as String] as? String) == name
      && ($0[kCGWindowLayer as String] as? Int) == 0
  }
  guard matches.count == 1,
    let number = matches[0][kCGWindowNumber as String] as? UInt32,
    let dictionary = matches[0][kCGWindowBounds as String] as? NSDictionary,
    let bounds = CGRect(dictionaryRepresentation: dictionary)
  else { throw ControlError.windowNotReady }
  return (app, number, bounds)
}

func sendKey(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = []) throws {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
  else { throw ControlError.eventCreationFailed }
  down.flags = flags
  up.flags = flags
  down.postToPid(pid)
  Thread.sleep(forTimeInterval: 0.05)
  up.postToPid(pid)
}

func sendModifiedKey(_ code: CGKeyCode, modifier: CGKeyCode, flags: CGEventFlags, pid: pid_t)
  throws
{
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: true),
    let up = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: false)
  else { throw ControlError.eventCreationFailed }
  down.type = .flagsChanged
  up.type = .flagsChanged
  down.flags = flags
  up.flags = []
  down.postToPid(pid)
  defer { up.postToPid(pid) }
  Thread.sleep(forTimeInterval: 0.05)
  try sendKey(code, pid: pid, flags: flags)
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  if args == ["preflight"] {
    try emit(permissions())
  } else if args.count == 2 && args[0] == "text" {
    // Only a caller-supplied guest-window PNG; no new capture or clipboard access.
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = false
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(url: URL(fileURLWithPath: args[1])).perform([request])
    let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return [
        "text": candidate.string, "confidence": candidate.confidence,
        "x": observation.boundingBox.midX, "y": 1 - observation.boundingBox.midY,
      ]
    }
    try emit(["lines": lines])
  } else {
    guard args.count == 4, ["window", "space", "key", "type", "click"].contains(args[0]),
      let pid = Int32(args[1]), pid > 0
    else { throw ControlError.invalidArguments }
    // Include this exact owned window on other Spaces. Never activate, raise, or
    // move it: the host user may be reading or typing in another application.
    let (_, window, bounds) = try targetWindow(pid: pid, executable: args[2], name: args[3])
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let geometry = [bounds.minX, bounds.minY, bounds.width, bounds.height]
    if args[0] != "window" {
      var payload: [String: Any] = [:]
      if args[0] != "space" {
        guard
          let value = try JSONSerialization.jsonObject(
            with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]
        else { throw ControlError.invalidArguments }
        payload = value
      }
      let keys: [String: CGKeyCode] = [
        "space": 49, "return": 36, "tab": 48, "backtab": 48, "escape": 53,
        "keyboard-navigation": 98, "spotlight": 49,
        "up": 126, "down": 125, "left": 123, "right": 124,
      ]
      if args[0] == "type" {
        // Physical US/ABC key positions, not Unicode events ignored by virtual HID devices.
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789 ")
        let codes: [CGKeyCode] = [
          0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
          45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
          29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 49,
        ]
        let mapping = Dictionary(uniqueKeysWithValues: zip(letters, codes))
        guard let text = payload["text"] as? String, (1...100).contains(text.count),
          text.allSatisfy({ mapping[$0] != nil })
        else { throw ControlError.invalidArguments }
        for character in text {
          try sendKey(mapping[character]!, pid: pid)
          Thread.sleep(forTimeInterval: 0.05)
        }
      } else if args[0] == "click" {
        guard let x = payload["x"] as? Double, let y = payload["y"] as? Double,
          x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
          let expected = payload["bounds"] as? [Double], expected == geometry.map(Double.init),
          let expectedWindow = payload["window_id"] as? UInt32, expectedWindow == window
        else { throw ControlError.windowMoved }
        let (_, currentWindow, currentBounds) = try targetWindow(
          pid: pid, executable: args[2], name: args[3])
        guard currentWindow == window, currentBounds == bounds else {
          throw ControlError.windowMoved
        }
        let point = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
          guard
            let event = NSEvent.mouseEvent(
              with: type, location: NSPoint(x: x * bounds.width, y: (1 - y) * bounds.height),
              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: Int(window), context: nil, eventNumber: 0,
              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)?.cgEvent
          else { throw ControlError.eventCreationFailed }
          event.location = point
          event.flags = []
          event.setIntegerValueField(.mouseEventClickState, value: 1)
          event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
          event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
          event.postToPid(pid)
          Thread.sleep(forTimeInterval: 0.05)
        }
      } else {
        let name = args[0] == "space" ? "space" : payload["key"] as? String
        guard let name, let code = keys[name] else { throw ControlError.invalidArguments }
        if name == "backtab" {
          // Public IOLLEvent.h device-left flags distinguish the modifier's HID side.
          try sendModifiedKey(
            code, modifier: 56, flags: [.maskShift, .init(rawValue: 0x2)], pid: pid)
        } else if name == "spotlight" {
          try sendModifiedKey(
            code, modifier: 55, flags: [.maskCommand, .init(rawValue: 0x8)], pid: pid)
        } else if name == "keyboard-navigation" {
          // Control-F7 toggles guest keyboard navigation; still PID-only, never global.
          try sendModifiedKey(
            code, modifier: 59, flags: [.maskControl, .init(rawValue: 0x1)], pid: pid)
        } else {
          try sendKey(code, pid: pid)
        }
      }
      Thread.sleep(forTimeInterval: 0.2)
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else {
        // This could be user activity; never "repair" it by stealing focus back.
        throw ControlError.foregroundChanged
      }
    }
    try emit([
      "pid": pid, "window_id": window, "bounds": geometry, "action": args[0],
      "target_is_foreground": foreground == pid,
    ])
  }
} catch {
  try? emit(["error": String(describing: error)])
  if case ControlError.windowNotReady = error { exit(75) }
  exit(1)
}
