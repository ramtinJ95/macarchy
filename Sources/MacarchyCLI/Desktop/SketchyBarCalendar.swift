import ArgumentParser
import CoreGraphics
import Foundation
import ThemeCore

/// An optional item the generated clock module keeps beside the clock (ADR-0256). Older
/// generations lack some companions, so their clock scripts request only what they generated.
struct ClockCompanion: Sendable {
  enum Side: Sendable { case left, right }

  let item: String
  let detailItem: String
  /// Visual side of the clock.
  let side: Side
  let plugin: String
  let updateFrequency: Int
  let events: [String]

  private static let hoverEvents = [
    "mouse.clicked", "mouse.entered", "mouse.exited", "mouse.exited.global", "system_woke",
  ]
  static let update = Self(
    item: SketchyBarUpdateIndicator.item, detailItem: SketchyBarUpdateIndicator.detailItem,
    side: .right, plugin: "update", updateFrequency: 60, events: hoverEvents)
  static let keepAwake = Self(
    item: SketchyBarKeepAwakeIndicator.item, detailItem: SketchyBarKeepAwakeIndicator.detailItem,
    side: .left, plugin: "keep-awake", updateFrequency: 30,
    events: hoverEvents + [KeepAwake.barEvent])
  static let microphone = Self(
    item: SketchyBarMicrophoneIndicator.item,
    detailItem: SketchyBarMicrophoneIndicator.detailItem, side: .left, plugin: "microphone",
    updateFrequency: 30, events: hoverEvents + [Microphone.barEvent])
  static let saverPaused = Self(
    item: SketchyBarSaverPausedIndicator.item,
    detailItem: SketchyBarSaverPausedIndicator.detailItem, side: .left, plugin: "saver-paused",
    updateFrequency: 30, events: hoverEvents + [SaverIdle.barEvent])
  static let all = [update, keepAwake, microphone, saverPaused]

  /// Asks a running bar to refresh a companion now. Its 30-second timer is the backstop, so a
  /// failed hint only warns and the owning state stays authoritative.
  static func hintBar(
    event: String, processRunner: ProcessRunner, installed: Bool, warn: (String) -> Void
  ) {
    guard installed else { return }
    let result = try? processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL,
        arguments: ["--trigger", event], timeout: 1))
    if result?.terminationStatus == 0 { return }
    warn("SketchyBar was not notified of \(event); the indicator refreshes within 30 seconds.")
  }

  static func hintRunningBar(event: String) {
    hintBar(
      event: event, processRunner: .live,
      installed: FileManager.default.isExecutableFile(
        atPath: SketchyBarCoreRuntimeVerifier.controlURL.path),
      warn: { try? FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
  }
}

struct SketchyBarCalendar {
  static let previewItem = "macarchy.clock.preview"
  let processRunner: ProcessRunner
  let hasExternalDisplay: () throws -> Bool
  let uptime: () -> TimeInterval
  let sleep: (TimeInterval) -> Void

  static func externalDisplayPresent() throws -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
      throw CalendarError.displayQuery
    }
    guard count > 0 else { return false }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success,
      count <= displays.count
    else { throw CalendarError.displayQuery }
    return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
  }

  func execute(
    sender: String, position: String, format: String, companions: [ClockCompanion] = []
  ) throws {
    guard ["auto", "left", "center", "right"].contains(position), format.hasPrefix("+") else {
      throw CalendarError.invalidInvocation
    }
    if sender == "mouse.clicked" {
      let deadline = UInt64((uptime() + 4) * 1000)
      try bar([
        "--set", Self.previewItem, "label=\(deadline)",
        "--set", "macarchy.clock", "label=Week \(try date("+%V"))",
      ])
      sleep(4)
      // A later click owns its own four-second interval. The older process must
      // not restore the clock underneath it, including after configuration reload.
      guard try previewDeadline() == deadline, uptime() * 1000 >= Double(deadline) else { return }
    }
    let actualPosition =
      position == "auto" ? (try hasExternalDisplay() ? "center" : "right") : position
    let compact = actualPosition == "right"
    let label =
      try Double(previewDeadline()) > uptime() * 1000
      ? "Week \(date("+%V"))"
      : date(compact ? format.replacingOccurrences(of: "  %H", with: " %H") : format)
    var arguments = [
      "--set", "macarchy.clock", "position=\(actualPosition)",
      "padding_left=\(compact ? 6 : 8)", "padding_right=\(compact ? 2 : 8)",
      "label.padding_left=\(compact ? 1 : 3)", "label.padding_right=\(compact ? 1 : 3)",
      "label=\(label)",
    ]
    for companion in companions {
      // Right-side items are laid out in reverse order, so "before" there is visually right.
      let before = (companion.side == .right) == compact
      arguments += [
        "--set", companion.item, "position=\(actualPosition)",
        "--move", companion.item, before ? "before" : "after", "macarchy.clock",
      ]
    }
    try bar(arguments)
  }

  private func previewDeadline() throws -> UInt64 {
    let label = try SketchyBarLabelQuery.value(from: bar(["--query", Self.previewItem]))
    guard let value = UInt64(label), String(value) == label else {
      throw CalendarError.invalidPreview
    }
    return value
  }

  private func date(_ format: String) throws -> String {
    try run("/bin/date", [format]).trimmingCharacters(in: .newlines)
  }

  @discardableResult private func bar(_ arguments: [String]) throws -> String {
    try run("/opt/homebrew/bin/sketchybar", arguments)
  }

  private func run(_ path: String, _ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(executableURL: URL(filePath: path), arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else { throw CalendarError.queryFailed }
    return result.output
  }
}

enum CalendarError: Error { case displayQuery, invalidInvocation, invalidPreview, queryFailed }

extension Desktop {
  struct Calendar: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_calendar", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var position: String
    @Option var format: String
    @Flag var updateIndicator = false
    @Flag var keepAwakeIndicator = false
    @Flag var microphoneIndicator = false
    @Flag var saverPausedIndicator = false

    var companions: [ClockCompanion] {
      let requested: [(Bool, ClockCompanion)] = [
        (updateIndicator, .update), (keepAwakeIndicator, .keepAwake),
        (microphoneIndicator, .microphone), (saverPausedIndicator, .saverPaused),
      ]
      return requested.filter { $0.0 }.map { $0.1 }
    }

    mutating func run() throws {
      try SketchyBarCalendar(
        processRunner: .live,
        hasExternalDisplay: SketchyBarCalendar.externalDisplayPresent,
        uptime: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:)
      )
      .execute(sender: sender, position: position, format: format, companions: companions)
    }
  }
}
