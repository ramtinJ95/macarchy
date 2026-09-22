import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarStartupTests {
  @Test(arguments: [0, 3, 40])
  func socketReadinessLoadsTheRestOfTheBar(failedAttempts: Int) throws {
    let result = try run(failedAttempts: failedAttempts)
    #expect(result.status == 0)
    #expect(result.attempts == failedAttempts + 1)
    #expect(result.sleeps == Array(repeating: "0.25", count: failedAttempts))
    #expect(result.output.contains("label=Waiting for Spaces"))
    #expect(result.output.contains("--remove macarchy.spaces.startup"))
    #expect(result.output.contains("--add space macarchy.space.1 left"))
    #expect(result.output.contains("--add space macarchy.space.2 left"))
    #expect(!result.output.contains("Spaces ERR"))
    let clock = try #require(result.output.range(of: "--add item macarchy.clock "))
    let ready = try #require(result.output.range(of: "--add item macarchy.theme.ready "))
    #expect(clock.lowerBound < ready.lowerBound)
    #expect(result.output.contains("waiting for yabai socket") == (failedAttempts > 0))
    #expect(result.output.contains("yabai socket ready; loading Spaces") == (failedAttempts > 0))
  }

  @Test
  func exhaustedSocketRetriesLeaveAnExplicitErrorWithoutReadiness() throws {
    let result = try run(failedAttempts: 41)
    #expect(result.attempts == 41)
    #expect(result.sleeps == Array(repeating: "0.25", count: 40))
    #expect(result.output.contains("yabai socket still unavailable after 41 attempts"))
    #expect(result.output.contains("reload SketchyBar after yabai is ready"))
    #expect(result.output.contains("yabai-msg: failed to connect to socket.."))
    expectFailedStartup(result)
  }

  @Test(arguments: ["rejected", "empty", "malformed"])
  func otherFailuresAreNotRetried(mode: String) throws {
    let result = try run(mode: mode)
    #expect(result.attempts == 1)
    #expect(result.sleeps.isEmpty)
    #expect(!result.output.contains("waiting for yabai socket"))
    #expect(result.output.contains(mode == "rejected" ? "query rejected" : "no inspectable Spaces"))
    expectFailedStartup(result)
  }

  @Test(arguments: ["disabled", "hidden"])
  func configurationsWithoutYabaiSpacesNeverWait(mode: String) throws {
    let result = try run(mode: mode, failedAttempts: 41)
    #expect(result.status == 0)
    #expect(result.attempts == 0)
    #expect(result.sleeps.isEmpty)
    #expect(!result.output.contains("macarchy.spaces.startup"))
    #expect(result.output.contains("macarchy.spaces.unavailable") == (mode == "disabled"))
    #expect(result.output.contains("--add item macarchy.clock "))
    #expect(result.output.contains("--add item macarchy.theme.ready "))
  }

  private struct Result {
    let status: Int32
    let output: String
    let attempts: Int
    let sleeps: [String]
  }

  private func expectFailedStartup(_ result: Result) {
    #expect(result.status != 0)
    #expect(
      result.output.contains("--set macarchy.spaces.startup label=Spaces ERR label.color=red"))
    #expect(!result.output.contains("--remove macarchy.spaces.startup"))
    #expect(!result.output.contains("--add space "))
    #expect(!result.output.contains("--add item macarchy.clock "))
    #expect(!result.output.contains("--add item macarchy.theme.ready "))
    #expect(!result.output.contains("--update"))
  }

  // Execute the actual generated entry and Space helper against fake providers.
  // Only executable paths are replaced; the retry policy and commands stay real.
  private func run(mode: String = "socket", failedAttempts: Int = 0) throws -> Result {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-startup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let count = root.appending(path: "attempts")
    let sleeps = root.appending(path: "sleeps")
    try "0".write(to: count, atomically: true, encoding: .utf8)
    try "".write(to: sleeps, atomically: true, encoding: .utf8)
    let executables = [
      "bar": "printf '%s\\n' \"$*\"",
      "sleep": "printf '%s\\n' \"$*\" >> \"$SLEEP_FILE\"",
      "yabai": """
      attempt=$(cat "$COUNT_FILE")
      attempt=$((attempt + 1))
      printf '%s' "$attempt" > "$COUNT_FILE"
      case "$MODE" in
        rejected) echo 'query rejected' >&2; exit 2 ;;
        empty) echo '[]'; exit 0 ;;
        malformed) echo 'not JSON'; exit 0 ;;
      esac
      if [ "$attempt" -le "$FAIL_UNTIL" ]; then
        echo 'yabai-msg: failed to connect to socket..' >&2
        exit 1
      fi
      echo '[{"index":1},{"index":2}]'
      """,
    ]
    for (name, body) in executables {
      try writeExecutable("#!/bin/sh\nset -eu\n" + body + "\n", to: root.appending(path: name))
    }
    let palette = root.appending(path: "current/generated/sketchybar.sh")
    try FileManager.default.createDirectory(
      at: palette.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    MACARCHY_BAR_COLOR=bar
    MACARCHY_TEXT_COLOR=text
    MACARCHY_MUTED_COLOR=muted
    MACARCHY_ACCENT_COLOR=accent
    MACARCHY_BATTERY_RED=red

    """.write(to: palette, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [desktop]
      provider = "\(mode == "disabled" ? "disabled" : "yabai-skhd")"
      [sketchybar]
      left = \(mode == "hidden" ? "[\"apple\"]" : "[\"apple\", \"spaces\"]")
      center = []
      right = ["clock"]
      """,
      source: root.appending(path: "profile.toml"))
    let defaults = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Desktop/sketchybar/defaults.toml")
    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaults, profile: profile, stateRoot: root)
    let provider = root.appending(path: "desktop/sketchybar/current")
    for artifact in composition.artifacts {
      let contents = artifact.contents
        .replacingOccurrences(
          of: "/opt/homebrew/bin/sketchybar", with: root.appending(path: "bar").path
        )
        .replacingOccurrences(
          of: "/opt/homebrew/bin/yabai", with: root.appending(path: "yabai").path
        )
        .replacingOccurrences(of: "/bin/sleep", with: root.appending(path: "sleep").path)
      try writeExecutable(contents, to: provider.appending(path: artifact.path))
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [provider.appending(path: "sketchybarrc").path]
    process.environment = [
      "PATH": "/usr/bin:/bin", "COUNT_FILE": count.path, "SLEEP_FILE": sleeps.path,
      "MODE": mode, "FAIL_UNTIL": String(failedAttempts),
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return Result(
      status: process.terminationStatus, output: text,
      attempts: try #require(Int(String(contentsOf: count, encoding: .utf8))),
      sleeps: try String(contentsOf: sleeps, encoding: .utf8).split(separator: "\n").map(
        String.init))
  }

  private func writeExecutable(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}
