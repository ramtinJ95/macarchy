import ArgumentParser
import CoreGraphics
import Foundation
import ThemeCore

struct SketchyBarCalendar {
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
    sender: String, position: String, format: String, companions: [SketchyBarClockCompanion] = []
  ) throws {
    guard ["auto", "left", "center", "right"].contains(position), format.hasPrefix("+") else {
      throw CalendarError.invalidInvocation
    }
    if sender == "mouse.clicked" {
      let deadline = UInt64((uptime() + 4) * 1000)
      try bar([
        "--set", SketchyBarContract.clockPreviewItem, "label=\(deadline)",
        "--set", SketchyBarContract.clockItem, "label=Week \(try date("+%V"))",
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
      "--set", SketchyBarContract.clockItem, "position=\(actualPosition)",
      "padding_left=\(compact ? 6 : 8)", "padding_right=\(compact ? 2 : 8)",
      "label.padding_left=\(compact ? 1 : 3)", "label.padding_right=\(compact ? 1 : 3)",
      "label=\(label)",
    ]
    for companion in companions {
      // Right-side items are laid out in reverse order, so "before" there is visually right.
      let before = (companion.side == .right) == compact
      arguments += [
        "--set", companion.item, "position=\(actualPosition)",
        "--move", companion.item, before ? "before" : "after", SketchyBarContract.clockItem,
      ]
    }
    try bar(arguments)
  }

  private func previewDeadline() throws -> UInt64 {
    let label = try SketchyBarLabelQuery.value(
      from: bar(["--query", SketchyBarContract.clockPreviewItem]))
    guard let value = UInt64(label), String(value) == label else {
      throw CalendarError.invalidPreview
    }
    return value
  }

  private func date(_ format: String) throws -> String {
    try run("/bin/date", [format]).trimmingCharacters(in: .newlines)
  }

  private var bar: SketchyBarControl {
    SketchyBarControl(processRunner: processRunner) { _, _ in CalendarError.queryFailed }
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
    static let configuration = CommandConfiguration(
      commandName: SketchyBarContract.calendarCommand, shouldDisplay: false)
    @Option var sender = "forced"
    @Option var position: String
    @Option var format: String
    @Flag(name: .customLong(SketchyBarClockCompanion.update.calendarFlag))
    var updateIndicator = false
    @Flag(name: .customLong(SketchyBarClockCompanion.keepAwake.calendarFlag))
    var keepAwakeIndicator = false
    @Flag(name: .customLong(SketchyBarClockCompanion.microphone.calendarFlag))
    var microphoneIndicator = false
    @Flag(name: .customLong(SketchyBarClockCompanion.saverPaused.calendarFlag))
    var saverPausedIndicator = false

    var companions: [SketchyBarClockCompanion] {
      let requested: [(Bool, SketchyBarClockCompanion)] = [
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
