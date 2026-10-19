import ArgumentParser
import CoreGraphics
import Foundation
import ThemeCore

/// A bar popup that opens on click. SketchyBar stops sending `mouse.exited.global` to the owner
/// once the pointer has entered the popup, so opening one starts a detached watcher that closes
/// it when the pointer leaves.
enum BarPopup: String, CaseIterable, ExpressibleByArgument, Sendable {
  case wifi = "macarchy.wifi.bracket"
  case volume = "macarchy.volume.bracket"
  case battery = "macarchy.battery"
  case media = "macarchy.media"

  /// The `macarchy` command that watches this popup.
  var watchArguments: [String] { ["desktop", "_popup-watch", "--popup", rawValue] }
}

/// The part of one `sketchybar --query <item>` result the popup watcher reads.
/// `bounding_rects` holds one rectangle per display, in the CoreGraphics global points that
/// `CGEvent` reports for the pointer.
struct SketchyBarItemFrame: Decodable {
  struct Popup: Decodable {
    let drawing: String
    let items: [String]
  }
  let rects: [CGRect]
  let popup: Popup?

  private struct Rect: Decodable {
    let origin: [Double]
    let size: [Double]
  }
  private enum CodingKeys: String, CodingKey {
    case rects = "bounding_rects"
    case popup
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    popup = try container.decodeIfPresent(Popup.self, forKey: .popup)
    let displays = try container.decodeIfPresent([String: Rect].self, forKey: .rects) ?? [:]
    rects = try displays.keys.sorted().compactMap { display in
      guard let rect = displays[display], rect.origin.count == 2, rect.size.count == 2 else {
        throw DecodingError.dataCorruptedError(
          forKey: .rects, in: container, debugDescription: "\(display) is not a rectangle")
      }
      let frame = CGRect(
        x: rect.origin[0], y: rect.origin[1], width: rect.size[0], height: rect.size[1])
      return frame.isEmpty ? nil : frame
    }
  }

  static func query(_ item: String, processRunner: ProcessRunner) throws -> Self {
    try JSONDecoder().decode(
      Self.self, from: Data(sketchyBar(["--query", item], processRunner: processRunner).utf8))
  }
}

/// Decides, one pointer sample at a time, whether a click-opened popup stays open, closes, or is
/// no longer the watcher's to manage.
struct PopupPointerWatch {
  enum Verdict: Equatable { case keepOpen, close, stop }

  /// Covers the gap between the bar and the popup and the popup's border.
  static let tolerance: CGFloat = 6
  static let closeDelay: TimeInterval = 0.3
  static let lifetime: TimeInterval = 600

  let started: TimeInterval
  private var outsideSince: TimeInterval?

  init(started: TimeInterval) { self.started = started }

  /// `owner` is where the popup's owner sits in the bar and `rows` are the popup's items, on any
  /// display. Until a row has been laid out, the popup's extent is unknown and it stays open.
  mutating func observe(
    drawn: Bool, pointer: CGPoint, owner: [CGRect], rows: [CGRect], at now: TimeInterval
  ) -> Verdict {
    guard drawn, now - started < Self.lifetime else { return .stop }
    let inside = (owner + rows).contains {
      $0.insetBy(dx: -Self.tolerance, dy: -Self.tolerance).contains(pointer)
    }
    if rows.isEmpty || inside {
      outsideSince = nil
      return .keepOpen
    }
    let since = outsideSince ?? now
    outsideSince = since
    return now - since >= Self.closeDelay ? .close : .keepOpen
  }
}

/// Opens or closes a click-opened popup. `alongside` arguments join the same SketchyBar call.
struct SketchyBarPopupToggle {
  let popup: BarPopup
  let processRunner: ProcessRunner
  /// Starts `macarchy` with these arguments without waiting for it.
  let launch: ([String]) throws -> Void

  func execute(alongside: [String] = []) throws {
    let drawing = try SketchyBarItemFrame.query(popup.rawValue, processRunner: processRunner)
      .popup?.drawing
    guard let drawing, ["on", "off"].contains(drawing) else {
      throw PopupWatchError(description: "SketchyBar \(popup.rawValue) has no popup")
    }
    let opening = drawing == "off"
    try sketchyBar(
      ["--set", popup.rawValue, "popup.drawing=\(opening ? "on" : "off")"] + alongside,
      processRunner: processRunner)
    if opening { try launch(popup.watchArguments) }
  }
}

/// Polls the pointer while a click-opened popup is drawn and closes the popup once the pointer
/// has stayed outside it for `PopupPointerWatch.closeDelay`.
struct SketchyBarPopupWatcher {
  static let interval: TimeInterval = 0.15
  /// Rows can change size while the popup is open, such as the battery's remaining time.
  static let rowRefresh: TimeInterval = 1
  /// A sample fails while SketchyBar reloads or a row is replaced, so the watcher gives up only
  /// after this many failed samples in a row.
  static let failureLimit = 5

  let popup: BarPopup
  let processRunner: ProcessRunner
  let pointer: () -> CGPoint?
  let uptime: () -> TimeInterval
  let sleep: (TimeInterval) -> Void

  private struct Rows {
    let items: [String]
    let owner: [CGRect]
    let rects: [CGRect]
    let queried: TimeInterval
  }

  func run() throws {
    var watch = PopupPointerWatch(started: uptime())
    var cached: Rows?
    var failures = 0
    while true {
      do {
        if try sample(&watch, cached: &cached) { return }
        failures = 0
      } catch {
        failures += 1
        guard failures < Self.failureLimit else { throw error }
      }
      sleep(Self.interval)
    }
  }

  /// Each sample queries the owner once. Rows are queried again when the popup's items or the
  /// owner's place in the bar change, every `rowRefresh`, and while a row has not been laid out.
  /// Returns true once the watcher is done.
  private func sample(_ watch: inout PopupPointerWatch, cached: inout Rows?) throws -> Bool {
    let now = uptime()
    let owner = try SketchyBarItemFrame.query(popup.rawValue, processRunner: processRunner)
    guard let state = owner.popup else {
      throw PopupWatchError(description: "SketchyBar \(popup.rawValue) has no popup")
    }
    let drawn = state.drawing == "on"
    var rows: [CGRect] = []
    if drawn {
      if let cached, cached.items == state.items, cached.owner == owner.rects,
        now - cached.queried < Self.rowRefresh
      {
        rows = cached.rects
      } else {
        let frames = try state.items.map {
          try SketchyBarItemFrame.query($0, processRunner: processRunner).rects
        }
        rows = frames.flatMap { $0 }
        cached =
          frames.allSatisfy { !$0.isEmpty }
          ? Rows(items: state.items, owner: owner.rects, rects: rows, queried: now) : nil
      }
    }
    guard let location = pointer() else {
      throw PopupWatchError(description: "cannot read the pointer location")
    }
    let verdict = watch.observe(
      drawn: drawn, pointer: location, owner: owner.rects, rows: rows, at: now)
    switch verdict {
    case .keepOpen:
      return false
    case .close:
      try sketchyBar(["--set", popup.rawValue, "popup.drawing=off"], processRunner: processRunner)
      return true
    case .stop:
      return true
    }
  }
}

/// Holds the one watcher slot for a popup, so repeated clicks never stack watchers. A watcher
/// started while an earlier one is still exiting waits for it and then reads the popup afresh, so
/// a quick close and reopen is still watched. The kernel releases the lock when the process exits,
/// so a crashed watcher never blocks the next one.
final class PopupWatchLock {
  private let descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { close(descriptor) }

  /// Waits while another watcher holds the slot.
  static func acquire(_ popup: BarPopup, in directory: URL) throws -> PopupWatchLock {
    let path = directory.appending(path: "macarchy-popup-watch-\(popup.rawValue).lock").path
    let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else {
      throw PopupWatchError(description: "cannot open \(path): errno \(errno)")
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      let error = errno
      close(descriptor)
      throw PopupWatchError(description: "cannot lock \(path): errno \(error)")
    }
    return PopupWatchLock(descriptor: descriptor)
  }
}

struct PopupWatchError: Error, CustomStringConvertible {
  let description: String
}

@discardableResult
private func sketchyBar(_ arguments: [String], processRunner: ProcessRunner) throws -> String {
  let result = try processRunner.run(
    .init(
      executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
  guard result.terminationStatus == 0 else {
    throw PopupWatchError(description: "SketchyBar \(arguments.joined(separator: " ")) failed")
  }
  return result.output
}

extension Desktop {
  struct PopupToggle: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_popup-toggle", shouldDisplay: false)
    @Option var popup: BarPopup

    mutating func run() throws {
      try SketchyBarPopupToggle(
        popup: popup, processRunner: .live, launch: SketchyBarCompanionToggle.launchMacarchy
      )
      .execute()
    }
  }

  struct PopupWatch: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_popup-watch", shouldDisplay: false)
    @Option var popup: BarPopup

    mutating func run() throws {
      let lock = try PopupWatchLock.acquire(popup, in: FileManager.default.temporaryDirectory)
      try withExtendedLifetime(lock) {
        try SketchyBarPopupWatcher(
          popup: popup, processRunner: .live, pointer: { CGEvent(source: nil)?.location },
          uptime: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:)
        )
        .run()
      }
    }
  }
}
