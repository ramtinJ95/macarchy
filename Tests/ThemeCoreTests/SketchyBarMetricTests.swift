import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarMetricTests {
  @Test(arguments: [0, 9, 29, 30, 49, 50, 59, 60, 69, 70, 79, 80, 84, 85, 100])
  func rendersPaddedMetricsAndCanonicalThresholds(level: Int) throws {
    for module in [SketchyBarModule.cpu, .memory] {
      let cpu = module == .cpu
      let raw =
        cpu
        ? "\(level)\n"
        : "System-wide memory free percentage: \(100 - level)%\n"
      let result = try run(raw, module: module)
      #expect(result.status == 0, Comment(rawValue: result.output))
      #expect(
        result.output.contains("label=\(cpu ? "cpu" : "mem") \(String(format: "%02d%%", level))\n"))
      let color =
        level >= (cpu ? 80 : 85)
        ? "red" : level >= (cpu ? 60 : 70) ? "orange" : level >= (cpu ? 30 : 50) ? "yellow" : "blue"
      #expect(result.output.contains("label.color=\(color)\n"))
    }
  }

  @Test(arguments: [
    "", "garbage", "System-wide memory free percentage: 101%",
    "System-wide memory free percentage: -1%", "System-wide memory free percentage: 9.5%",
    "System-wide memory free percentage: 50%\nSystem-wide memory free percentage: 50%",
    "-1", "101", "9.5", "9\n9",
  ])
  func rejectsInvalidOrIncompleteSamples(raw: String) throws {
    for module in [SketchyBarModule.cpu, .memory] {
      let result = try run(raw, module: module)
      #expect(result.status != 0)
      #expect(result.output.contains("ERR\n"))
      #expect(result.output.contains("label.color=red\n"))
    }
  }

  private func run(_ raw: String, module: SketchyBarModule) throws -> (
    status: Int32, output: String
  ) {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-metric-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let palette = root.appending(path: "palette.sh")
    try
      "MACARCHY_ACCENT_COLOR=blue\nMACARCHY_WARNING_COLOR=yellow\nMACARCHY_BATTERY_ORANGE=orange\nMACARCHY_BATTERY_RED=red\n"
      .write(to: palette, atomically: true, encoding: .utf8)
    let input = root.appending(path: "sample.txt")
    try raw.write(to: input, atomically: true, encoding: .utf8)
    let bar = root.appending(path: "sketchybar")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: bar, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bar.path)
    let entry = root.appending(path: "metric.sh")
    let script = SketchyBarMetricScript.render(
      module: module, palettePath: palette.path,
      macarchyExecutablePath: "/mock/macarchy"
    )
    .replacingOccurrences(of: "'/mock/macarchy' desktop _cpu-load", with: "/bin/cat \(input.path)")
    .replacingOccurrences(of: "/usr/bin/memory_pressure", with: "/bin/cat \(input.path)")
    .replacingOccurrences(of: "/opt/homebrew/bin/sketchybar", with: bar.path)
    try script.write(to: entry, atomically: true, encoding: .utf8)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [entry.path]
    process.environment = ["PATH": "/usr/bin:/bin", "NAME": "macarchy.\(module.rawValue)"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
  }
}
