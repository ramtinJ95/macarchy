import ArgumentParser
import CoreGraphics
import Foundation
import ThemeCore

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

  func execute(sender: String, position: String, format: String) throws {
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
    try bar([
      "--set", "macarchy.clock", "position=\(actualPosition)",
      "padding_left=\(compact ? 6 : 8)", "padding_right=\(compact ? 2 : 8)",
      "label.padding_left=\(compact ? 1 : 3)", "label.padding_right=\(compact ? 1 : 3)",
      "label=\(label)",
    ])
  }

  private func previewDeadline() throws -> UInt64 {
    struct Item: Decodable {
      struct Label: Decodable { let value: String }
      let label: Label
    }
    let item = try JSONDecoder().decode(
      Item.self, from: Data(bar(["--query", Self.previewItem]).utf8))
    guard let value = UInt64(item.label.value), String(value) == item.label.value else {
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

    mutating func run() throws {
      try SketchyBarCalendar(
        processRunner: .live,
        hasExternalDisplay: SketchyBarCalendar.externalDisplayPresent,
        uptime: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:)
      )
      .execute(sender: sender, position: position, format: format)
    }
  }
}
