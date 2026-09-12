import ArgumentParser
import CoreGraphics
import Darwin
import Foundation
import Synchronization
import ThemeCore

struct NativeMenuToggleState {
  enum Action: Equatable { case hide, show }
  private(set) var hidden = false
  private var leavingSince: TimeInterval?

  mutating func step(distanceFromTop: Double, now: TimeInterval) -> Action? {
    if !hidden, distanceFromTop <= 10 {
      hidden = true
      leavingSince = nil
      return .hide
    }
    guard hidden else { return nil }
    guard distanceFromTop > 50 else {
      leavingSince = nil
      return nil
    }
    if leavingSince == nil { leavingSince = now }
    if now - leavingSince! >= 0.15 {
      hidden = false
      leavingSince = nil
      return .show
    }
    return nil
  }
}

struct ToggleHeartbeat: Sendable {
  let token: String
  let pid: Int32
  let milliseconds: UInt64
  let started: UInt64
  static func parse(_ text: String) -> Self? {
    let parts = text.split(separator: "|")
    guard parts.count == 4, let uuid = UUID(uuidString: String(parts[0])),
      uuid.uuidString.lowercased() == parts[0], let pid = Int32(parts[1]), pid > 0,
      String(pid) == parts[1], let milliseconds = UInt64(parts[2]),
      String(milliseconds) == parts[2],
      let started = UInt64(parts[3]), started > 0, String(started) == parts[3]
    else { return nil }
    return Self(token: String(parts[0]), pid: pid, milliseconds: milliseconds, started: started)
  }
  func fresh(at uptime: TimeInterval) -> Bool {
    let age = uptime * 1000 - Double(milliseconds)
    return age >= 0 && age <= 2500
  }
}

struct SketchyBarToggle {
  let processRunner: ProcessRunner
  let uptime: () -> TimeInterval
  let distance: () throws -> Double
  let wait: () -> Void
  let stopping: () -> Bool
  let foreignToggleAbsent: () throws -> Bool
  let pid: Int32
  let started: UInt64

  func execute(token: String) throws {
    guard UUID(uuidString: token)?.uuidString.lowercased() == token else {
      throw ToggleError.invalidToken
    }
    do {
      guard try owns(token) else { return }
      guard try foreignToggleAbsent() else { throw ToggleError.foreignProcess }
      try bar([
        "--bar", "hidden=off", "y_offset=0",
        "--set", "macarchy.toggle", "label.drawing=off",
      ])
      var state = NativeMenuToggleState()
      var heartbeat = -Double.infinity
      var conflictCheck = uptime()
      while !stopping() {
        let now = uptime()
        if now - heartbeat >= 1 {
          guard try owns(token) else { return }
          try bar([
            "--set", "macarchy.toggle", "drawing=off",
            "label=\(token)|\(pid)|\(UInt64(now * 1000))|\(started)",
          ])
          heartbeat = now
        }
        if now - conflictCheck >= 5 {
          guard try foreignToggleAbsent() else { throw ToggleError.foreignProcess }
          conflictCheck = now
        }
        let sample = try distance()
        guard sample.isFinite, sample >= 0 else { throw ToggleError.cursorScreenUnavailable }
        if let action = state.step(distanceFromTop: sample, now: now) {
          // Never repaint a replacement configuration based on an old cursor sample.
          guard try owns(token) else { return }
          switch action {
          case .hide: try bar(["--bar", "hidden=on"])
          case .show:
            try bar([
              "--bar", "hidden=off", "y_offset=-50", "--animate", "sin", "12", "--bar",
              "y_offset=0",
            ])
          }
        }
        wait()
      }
      if try owns(token) {
        try bar([
          "--bar", "hidden=off", "y_offset=0", "--set", "macarchy.toggle", "label=\(token)|stopped",
        ])
      }
    } catch {
      do {
        if try owns(token) {
          try bar([
            "--bar", "hidden=off", "y_offset=0", "--set", "macarchy.toggle", "drawing=on",
            "icon.drawing=off", "label.drawing=on", "label=\(token)|Toggle ERR: \(error)",
          ])
        }
      } catch let presentation {
        throw ToggleError.reporting(
          "Toggle failed (\(error)); error presentation failed (\(presentation))")
      }
      throw error
    }
  }

  private func owns(_ token: String) throws -> Bool {
    struct Bar: Decodable { let items: [String] }
    let inventory = try JSONDecoder().decode(Bar.self, from: Data(bar(["--query", "bar"]).utf8))
    guard inventory.items.contains("macarchy.toggle") else { return false }
    struct Item: Decodable {
      struct Label: Decodable { let value: String }
      let label: Label
    }
    let item = try JSONDecoder().decode(
      Item.self, from: Data(bar(["--query", "macarchy.toggle"]).utf8))
    return item.label.value.hasPrefix(token + "|")
  }

  @discardableResult private func bar(_ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else { throw ToggleError.barQuery }
    return result.output
  }

  static func noForeignToggle(processRunner: ProcessRunner = .live) throws -> Bool {
    let result = try processRunner.run(
      .init(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-u", String(getuid()), "-x", "sketchybar-toggle"], timeout: 1))
    guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
      throw ToggleError.processQuery
    }
    return result.terminationStatus == 1
  }

  static func cursorDistanceFromTop() throws -> Double {
    guard let event = CGEvent(source: nil) else { throw ToggleError.cursorScreenUnavailable }
    let point = event.location
    guard point.x.isFinite, point.y.isFinite else { throw ToggleError.cursorScreenUnavailable }
    var display = CGDirectDisplayID()
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else {
      throw ToggleError.cursorScreenUnavailable
    }
    return try distanceFromTop(point: point, bounds: CGDisplayBounds(display))
  }

  static func distanceFromTop(point: CGPoint, bounds: CGRect) throws -> Double {
    guard bounds.contains(point), point.x.isFinite, point.y.isFinite,
      bounds.minY.isFinite
    else { throw ToggleError.cursorScreenUnavailable }
    // CGEvent locations and display bounds share top-left global coordinates.
    return Double(point.y - bounds.minY)
  }

  static func processStart(_ pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid()
    else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
  }

  static func matchesProcess(_ heartbeat: ToggleHeartbeat) -> Bool {
    guard processStart(heartbeat.pid) == heartbeat.started else { return false }
    var path = [CChar](repeating: 0, count: 4_096)
    guard proc_pidpath(heartbeat.pid, &path, UInt32(path.count)) > 0 else { return false }
    let value = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: value, as: UTF8.self) == RuntimeEnvironment.live.executableURL.path
  }
}

enum ToggleError: Error {
  case invalidToken, foreignProcess, cursorScreenUnavailable, barQuery, processQuery
  case lock(String)
  case reporting(String)
}

extension Desktop {
  struct Toggle: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_bar-toggle", shouldDisplay: false)
    @Option var token: String
    @Option var stateRoot: String

    mutating func run() throws {
      guard stateRoot.hasPrefix("/") else { throw ToggleError.invalidToken }
      let stop = Mutex(false)
      signal(SIGTERM, SIG_IGN)
      signal(SIGINT, SIG_IGN)
      let sources = [SIGTERM, SIGINT].map { value in
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
        source.setEventHandler { stop.withLock { $0 = true } }
        source.resume()
        return source
      }
      defer {
        for source in sources { source.cancel() }
      }
      let lock = ProcessScopedFileLock<ToggleError>(
        filename: "sketchybar-toggle.lock",
        cannotCreateRunDirectory: { _, error in .lock(error) },
        operationError: { operation, code in .lock("\(operation): \(code)") })
      guard let started = SketchyBarToggle.processStart(getpid()) else {
        throw ToggleError.processQuery
      }
      try lock.withLockIfAvailable(root: URL(filePath: stateRoot)) {
        try SketchyBarToggle(
          processRunner: .live, uptime: { ProcessInfo.processInfo.systemUptime },
          distance: SketchyBarToggle.cursorDistanceFromTop,
          // AsyncParsableCommand does not guarantee the main thread. These
          // public CG queries need no AppKit run loop; an empty run loop would spin.
          wait: { Thread.sleep(forTimeInterval: 1.0 / 60) },
          stopping: { stop.withLock { $0 } },
          foreignToggleAbsent: { try SketchyBarToggle.noForeignToggle() }, pid: getpid(),
          started: started
        ).execute(token: token)
      }
    }
  }
}
