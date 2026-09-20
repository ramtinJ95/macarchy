import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuMaintenanceTests {
  @Test(arguments: [
    (MaintenanceAction.plan, ["setup", "plan"], Int32(0)),
    (.status, ["setup", "status"], Int32(1)),
    (.doctor, ["setup", "doctor"], Int32(0)),
    (.updateCheck, ["update", "check"], Int32(1)),
    (.apply, ["setup", "apply", "--review"], Int32(0)),
    (.update, ["update", "--review"], Int32(1)),
  ])
  func delegatesCommandAndHoldsItsResult(
    action: MaintenanceAction, arguments: [String], expectedStatus: Int32
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "macarchy")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\nexit \(expectedStatus)\n".write(
      to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var output: [String] = []
    var dismissed = false
    let profileArguments = [
      "--profile", "/tmp/custom profile.toml", "--machine-profile", "/tmp/machine.toml",
    ]
    let status = MenuMaintenance.runAndHold(
      action, executableURL: executable, profileArguments: profileArguments,
      write: { output.append($0) },
      dismiss: {
        #expect(output.contains(expectedStatus == 0 ? "\nSUCCESS (exit 0)" : "\nFAILED (exit 1)"))
        #expect(output.last == "Press Enter to close.")
        dismissed = true
      })
    #expect(status == expectedStatus)
    #expect(dismissed)
    let delegated = try String(contentsOfFile: executable.path + ".arguments", encoding: .utf8)
      .split(separator: "\n").map(String.init)
    #expect(
      delegated == arguments + (action == .updateCheck || action == .update ? [] : profileArguments)
    )
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

  @Test(arguments: [MenuTerminal.Kind.maintenance, .profile])
  func terminalLaunchPreservesNativeAppearanceAndCanonicalColorsWithoutAShell(
    kind: MenuTerminal.Kind
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
    let childArguments =
      kind == .maintenance ? ["_menu-maintenance", "plan"] : ["_menu-profile-edit", "keybindings"]
    let process = try MenuTerminal.launch(
      kind, arguments: childArguments, theme: theme, executableURL: executable,
      kittyApplicationURL: root, yabaiURL: yabai,
      launcherURL: URL(filePath: "/usr/bin/true"))
    if kind == .maintenance {
      let ruleArguments = try String(contentsOfFile: yabai.path + ".arguments", encoding: .utf8)
        .split(separator: "\n").map(String.init)
      #expect(
        ruleArguments == [
          "-m", "rule", "--add", "label=macarchy-maintenance",
          "app=^kitty$", "title=^Macarchy Maintenance$", "manage=off", "grid=20:20:7:7:6:6",
        ])
    } else {
      #expect(!FileManager.default.fileExists(atPath: yabai.path + ".arguments"))
    }
    let arguments = try #require(process.arguments)
    #expect(arguments.prefix(4) == ["-n", "-a", root.path, "--args"])
    #expect(arguments.contains("--title") == (kind == .maintenance))
    if kind == .maintenance { #expect(arguments.contains("Macarchy Maintenance")) }
    #expect(!arguments.contains("panel"))
    #expect(arguments.contains("startup_session=none"))
    #expect(arguments.contains("macos_quit_when_last_window_closed=yes"))
    #expect(arguments.suffix(3) == [executable.path] + childArguments)
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
            kittyApplicationURL: FileManager.default.temporaryDirectory.appending(
              path: UUID().uuidString),
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
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let kitty = root.appending(path: "kitty")
    try "#!/bin/sh\nprintf launched > \"$0.launched\"\n".write(
      to: kitty, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kitty.path)
    do {
      _ = try MenuMaintenance.launch(
        .status, theme: theme, executableURL: URL(filePath: "/unused/macarchy"),
        kittyApplicationURL: root, yabaiURL: URL(filePath: "/usr/bin/false"), launcherURL: kitty)
      Issue.record("Floating-rule failure was swallowed")
    } catch {
      #expect(
        String(describing: error).contains("Could not float the menu terminal (yabai 1)"))
    }
    #expect(!FileManager.default.fileExists(atPath: kitty.path + ".launched"))
  }

  @Test func launchServicesFailureIsNotReportedAsASuccessfulHandoff() throws {
    #expect(throws: (any Error).self) {
      try MenuTerminal.launch(
        .profile, arguments: ["_menu-profile-edit", "keybindings"], theme: theme(),
        executableURL: URL(filePath: "/unused/macarchy"),
        kittyApplicationURL: FileManager.default.temporaryDirectory,
        yabaiURL: URL(filePath: "/usr/bin/true"),
        launcherURL: URL(filePath: "/usr/bin/false"))
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
