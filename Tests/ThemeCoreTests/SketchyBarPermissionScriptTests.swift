import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct SketchyBarPermissionScriptTests {
  @Test(arguments: [true, false])
  func actualScriptPublishesEachResultBeforeTheOtherStageFinishes(slowAX: Bool) throws {
    try withTemporaryRoot(named: "bar-permission-script") { root in
      let log = root.appending(path: "events")
      let helper = root.appending(path: "macarchy-menu")
      let cli = root.appending(path: "macarchy")
      let bar = root.appending(path: "sketchybar")
      let palette = root.appending(path: "palette.sh")
      try "MACARCHY_TEXT_COLOR=0xffffffff\nMACARCHY_BATTERY_RED=0xffff0000\n".write(
        to: palette, atomically: true, encoding: .utf8)
      for (path, body) in [
        (
          helper,
          "#!/bin/sh\n[ \"$1\" = --check ] || exit 64\n"
            + (slowAX ? "sleep 0.3\n" : "") + "exit 0\n"
        ),
        (
          cli,
          "#!/bin/sh\n[ \"$*\" = 'setup check-appearance --json' ] || exit 64\n"
            + (slowAX ? "" : "sleep 0.3\n") + "exit 77\n"
        ),
        (bar, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + DesktopShellSyntax.literal(log.path) + "\n"),
      ] {
        try body.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
      }
      let script = root.appending(path: "apple.sh")
      // Replace only IPC with a guest-local recorder; no installed bar is touched.
      try SketchyBarAppleScript.render(palettePath: palette.path, helperPath: helper.path)
        .replacingOccurrences(
          of: "/opt/homebrew/bin/sketchybar", with: DesktopShellSyntax.literal(bar.path)
        )
        .write(to: script, atomically: true, encoding: .utf8)
      let token = "a0000000-0000-0000-0000-000000000000"
      let result = try ProcessRunner.live.run(
        .init(
          executableURL: URL(filePath: "/bin/zsh"), arguments: ["-f", script.path], timeout: 3,
          environmentOverrides: [
            "NAME": "macarchy.apple", "SENDER": "macarchy_permission_check",
            "MACARCHY_PERMISSION_TOKEN": token,
          ]))
      #expect(result.terminationStatus == 0)
      let events = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
      let completions = events.filter { $0.contains(":complete:") }
      #expect(completions.count == 2)
      #expect(
        completions.first?.contains(slowAX ? "icon=permission:" : "label=permission:") == true)
      #expect(
        completions.contains { $0.contains("label=permission:v2:" + token) && $0.hasSuffix(":0") })
      #expect(
        completions.contains { $0.contains("icon=permission:v2:" + token) && $0.hasSuffix(":77") })
      #expect(result.output.contains("stage=ax"))
      #expect(result.output.contains("stage=automation"))
      #expect(!result.output.contains("--request-accessibility"))
    }
  }
}
