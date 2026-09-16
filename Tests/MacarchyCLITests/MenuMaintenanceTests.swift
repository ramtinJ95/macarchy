import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuMaintenanceTests {
  @Test(arguments: [
    (MaintenanceAction.plan, ["setup", "plan"]),
    (.status, ["setup", "status"]),
    (.doctor, ["setup", "doctor"]),
    (.updateCheck, ["update", "check"]),
  ])
  func routesOnlyToExistingReadOnlyCommands(action: MaintenanceAction, arguments: [String]) {
    #expect(action.arguments == arguments)
  }

  @Test(arguments: [("/usr/bin/true", Int32(0)), ("/usr/bin/false", Int32(1))])
  func resultRemainsVisibleUntilDismissal(executable: String, expectedStatus: Int32) {
    var output: [String] = []
    var dismissed = false
    let status = MenuMaintenance.runAndHold(
      .status, executableURL: URL(filePath: executable), write: { output.append($0) },
      dismiss: {
        #expect(output.contains(expectedStatus == 0 ? "\nSUCCESS (exit 0)" : "\nFAILED (exit 1)"))
        #expect(output.last == "Press Enter to close.")
        dismissed = true
      })
    #expect(status == expectedStatus)
    #expect(dismissed)
  }

  @Test func failedCommandLaunchIsVisibleAndHeld() {
    var output: [String] = []
    var dismissed = false
    let status = MenuMaintenance.runAndHold(
      .doctor,
      executableURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      write: { output.append($0) },
      dismiss: {
        #expect(output.contains { $0.contains("Could not launch command:") })
        dismissed = true
      })
    #expect(status == 1)
    #expect(dismissed)
  }

  @Test(arguments: MaintenanceAction.allCases)
  func terminalLaunchPreservesNativeAppearanceAndCanonicalColorsWithoutAShell(
    action: MaintenanceAction
  ) throws {
    let theme = try theme()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let yabai = root.appending(path: "yabai")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\n".write(
      to: yabai, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: yabai.path)
    let executable = URL(filePath: "/tmp/Macarchy test $HOME;literal/macarchy")
    let process = try MenuMaintenance.launch(
      action, theme: theme, executableURL: executable,
      kittyURL: URL(filePath: "/usr/bin/true"), yabaiURL: yabai)
    let ruleArguments = try String(contentsOfFile: yabai.path + ".arguments", encoding: .utf8)
      .split(separator: "\n").map(String.init)
    #expect(
      ruleArguments == [
        "-m", "rule", "--add", "label=macarchy-maintenance",
        "app=^kitty$", "title=^Macarchy Maintenance$", "manage=off", "grid=20:20:7:7:6:6",
      ])
    let arguments = try #require(process.arguments)
    #expect(arguments.prefix(2) == ["--title", "Macarchy Maintenance"])
    #expect(!arguments.contains("panel"))
    #expect(arguments.contains("startup_session=none"))
    #expect(arguments.contains("macos_quit_when_last_window_closed=yes"))
    #expect(arguments.suffix(3) == [executable.path, "_menu-maintenance", action.rawValue])
    #expect(arguments.contains("foreground=\(theme.terminal.foreground.rawValue)"))
    #expect(arguments.contains("background=\(theme.terminal.background.rawValue)"))
    for setting in [
      "hide_window_decorations", "window_border_width", "single_window_margin_width",
      "draw_window_borders_for_single_window", "active_border_color", "inactive_border_color",
    ] {
      #expect(!arguments.contains { $0.hasPrefix(setting + "=") })
    }
    for (index, color) in theme.terminal.ansi.enumerated() {
      #expect(arguments.contains("color\(index)=\(color.rawValue)"))
    }
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @MainActor
  @Test func missingKittyReportsLaunchFailureToTheMenu() throws {
    let theme = try theme()
    var reported = false
    #expect(throws: (any Error).self) {
      try ActionMenu.runSession(
        showMenu: { .maintenance(.status) },
        openViewer: { _ in
          _ = try MenuMaintenance.launch(
            .status, theme: theme, executableURL: URL(filePath: "/unused/macarchy"),
            kittyURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            yabaiURL: URL(filePath: "/usr/bin/true"))
        },
        showFailure: { action, _ in
          #expect(action == .maintenance(.status))
          reported = true
        })
    }
    #expect(reported)
  }

  @Test func failedFloatingRulePreventsTerminalLaunch() throws {
    let theme = try theme()
    #expect(throws: (any Error).self) {
      try MenuMaintenance.launch(
        .status, theme: theme, executableURL: URL(filePath: "/unused/macarchy"),
        kittyURL: URL(filePath: "/usr/bin/true"), yabaiURL: URL(filePath: "/usr/bin/false"))
    }
  }

  private func theme() throws -> NormalizedTheme {
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: root.appending(path: "Themes/catppuccin-mocha"))
    return NormalizedTheme(package: package, generationID: "maintenance-test")
  }
}
