import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarBatteryTests {
  @Test(arguments: [100, 81, 80, 61, 60, 41, 40, 21, 20, 9, 0])
  func generatedBatteryScriptRendersCanonicalSeverityAndEstimate(level: Int) throws {
    let result = try run(
      "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t\(level)%; discharging; 2:34 remaining present: true\n"
    )
    #expect(result.status == 0, Comment(rawValue: result.output))
    #expect(result.output.contains("label=\(String(format: "%02d%%", level))\n"))
    #expect(result.output.contains("label=2:34h\n"))
    #expect(
      result.output.contains(
        "icon.color=\(level <= 20 ? "red" : level <= 40 ? "orange" : "green")\n"))
    let icon = level > 80 ? "􀛨" : level > 60 ? "􀺸" : level > 40 ? "􀺶" : level > 20 ? "􀛩" : "􀛪"
    #expect(result.output.contains("icon=\(icon)\n"))
  }

  @Test(arguments: ["-1", "1.5", "unknown"])
  func rejectsNonIntegerPercentages(value: String) throws {
    let result = try run(
      "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t\(value)%; discharging; 2:34 remaining present: true\n"
    )
    #expect(result.status != 0)
    #expect(result.output.contains("label=ERR\n"))
  }

  @Test
  func acAndDesktopStatesRemainExplicit() throws {
    let charging = try run(
      "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t9%; charging; (no estimate) present: true\n"
    )
    #expect(charging.status == 0)
    #expect(charging.output.contains("icon=􀢋\n"))
    #expect(charging.output.contains("label=No estimate\n"))
    let desktop = try run("Now drawing from 'AC Power'\n")
    #expect(desktop.status == 0)
    #expect(desktop.output.contains("label=No battery\n"))
    #expect(desktop.output.contains("icon.color=muted\n"))
  }

  @Test(arguments: [
    "", "garbage", "Now drawing from 'Battery Power'\n", "Now drawing from 'AC Power'\n unexpected",
    "Now drawing from 'AC Power'\n -InternalBattery-0\t101%; charged;",
    "Now drawing from 'AC Power'\n -InternalBattery-0\tunknown;",
    "Now drawing from 'AC Power'\n -InternalBattery-0\t50%; charged;\n -InternalBattery-1\t50%; charged;",
  ])
  func malformedQueriesReplaceStaleSuccessWithVisibleError(raw: String) throws {
    let result = try run(raw)
    #expect(result.status != 0)
    #expect(result.output.contains("label=ERR\n"))
    #expect(result.output.contains("label=Battery query failed\n"))
  }

  @Test(arguments: ["mouse.clicked", "mouse.exited.global"])
  func popupEventsDoNotPollBattery(sender: String) throws {
    let result = try run("invalid", sender: sender)
    #expect(result.status == 0)
    #expect(
      result.output.contains("popup.drawing=\(sender == "mouse.clicked" ? "toggle" : "off")\n"))
    #expect(!result.output.contains("label="))
  }

  private func run(_ raw: String, sender: String = "routine") throws -> (
    status: Int32, output: String
  ) {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-battery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let palette = root.appending(path: "palette.sh")
    try
      "MACARCHY_BATTERY_GREEN=green\nMACARCHY_BATTERY_ORANGE=orange\nMACARCHY_BATTERY_RED=red\nMACARCHY_MUTED_COLOR=muted\n"
      .write(to: palette, atomically: true, encoding: .utf8)
    let input = root.appending(path: "battery.txt")
    try raw.write(to: input, atomically: true, encoding: .utf8)
    let mockBar = root.appending(path: "sketchybar")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: mockBar, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockBar.path)
    let entry = root.appending(path: "battery.sh")
    let script = SketchyBarBatteryScript.render(palettePath: palette.path)
      .replacingOccurrences(of: "/usr/bin/pmset -g batt", with: "/bin/cat \(input.path)")
      .replacingOccurrences(of: "/opt/homebrew/bin/sketchybar", with: mockBar.path)
    try script.write(to: entry, atomically: true, encoding: .utf8)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [entry.path]
    process.environment = ["PATH": "/usr/bin:/bin", "NAME": "macarchy.battery", "SENDER": sender]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
  }
}
