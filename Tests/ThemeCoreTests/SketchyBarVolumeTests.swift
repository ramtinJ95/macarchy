import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarVolumeTests {
  @Test(arguments: [0, 1, 9, 10, 11, 30, 31, 60, 61, 100])
  func rendersLevelIconsAndSlider(level: Int) throws {
    let result = try run(environment: ["SENDER": "volume_change", "INFO": String(level)])
    #expect(result.status == 0)
    #expect(result.output.contains("label=\(String(format: "%02d%%", level))\n"))
    #expect(result.output.contains("slider.percentage=\(level)\n"))
    let icon = level > 60 ? "􀊩" : level > 30 ? "􀊧" : level > 10 ? "􀊥" : level > 0 ? "􀊡" : "􀊣"
    #expect(result.output.contains("macarchy.volume.icon\nlabel=\(icon)\n"))
    #expect(!result.output.contains("osascript:"))
  }

  @Test(arguments: ["", "101", "-1", "1.2", "2\n3", "1; touch /tmp/unsafe"])
  func rejectsMalformedEventsWithoutControl(value: String) throws {
    for sender in ["volume_change", "macarchy.slider", "mouse.scrolled"] {
      let result = try run(environment: [
        "SENDER": sender, "INFO": value, "PERCENTAGE": value,
        "SCROLL_DELTA": value == "101" ? "1001" : value == "-1" ? "-1001" : value,
      ])
      #expect(result.status != 0)
      #expect(result.output.contains("label=ERR\n"))
      #expect(!result.output.contains("set volume output"))
    }
  }

  @Test
  func clampsScrollUsesControlModifierAndValidatesSlider() throws {
    for (delta, modifier, expected) in [
      ("1", "", 52), ("1", "ctrl", 43), ("100", "", 100), ("-100", "", 0),
    ] {
      let result = try run(environment: [
        "SENDER": "mouse.scrolled", "SCROLL_DELTA": delta, "MODIFIER": modifier,
      ])
      #expect(result.status == 0)
      #expect(result.output.contains("osascript:set volume output volume \(expected)\n"))
    }
    let slider = try run(environment: [
      "SENDER": "macarchy.slider", "PERCENTAGE": "08", "NAME": "macarchy.volume.slider",
    ])
    #expect(slider.status == 0)
    #expect(slider.output.contains("osascript:set volume output volume 8\n"))
  }

  @Test
  func popupSettingsAndQueryFailuresAreObservable() throws {
    for (sender, button, expected) in [
      ("mouse.clicked", "left", "--action\ntoggle"),
      ("mouse.exited.global", "", "--action\nclose"),
      ("mouse.clicked", "right", "open:/System/Library/PreferencePanes/Sound.prefpane"),
    ] {
      let result = try run(environment: ["SENDER": sender, "BUTTON": button])
      #expect(result.status == 0)
      #expect(result.output.contains(expected))
      #expect(!result.output.contains("osascript:"))
    }
    let failed = try run(environment: ["SENDER": "routine", "FAIL_QUERY": "1"])
    #expect(failed.status != 0)
    #expect(failed.output.contains("label=ERR\n"))
  }

  private func run(environment: [String: String]) throws -> (status: Int32, output: String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-volume-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let palette = root.appending(path: "palette.sh")
    try "MACARCHY_TEXT_COLOR=text\nMACARCHY_BATTERY_RED=red\nMACARCHY_MUTED_COLOR=muted\n".write(
      to: palette, atomically: true, encoding: .utf8)
    for (name, body) in [
      ("bar", "printf '%s\\n' \"$@\""),
      ("macarchy", "printf '%s\\n' \"$@\""),
      (
        "osascript",
        "echo \"osascript:$2\" >&2\ncase \"$2\" in output*) if [ \"${FAIL_QUERY-}\" = 1 ]; then exit 19; fi; echo 42 ;; esac"
      ),
      ("open", "echo \"open:$1\""),
    ] {
      let path = root.appending(path: name)
      try ("#!/bin/sh\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    let script = SketchyBarVolumeScript.render(
      palettePath: palette.path, macarchyExecutablePath: root.appending(path: "macarchy").path
    )
    .replacingOccurrences(
      of: "/opt/homebrew/bin/sketchybar", with: root.appending(path: "bar").path
    )
    .replacingOccurrences(of: "/usr/bin/osascript", with: root.appending(path: "osascript").path)
    .replacingOccurrences(of: "/usr/bin/open", with: root.appending(path: "open").path)
    let entry = root.appending(path: "volume.sh")
    try script.write(to: entry, atomically: true, encoding: .utf8)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [entry.path]
    process.environment = ["PATH": "/usr/bin:/bin", "NAME": "macarchy.volume"].merging(environment)
    { _, new in new }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, result)
  }
}
