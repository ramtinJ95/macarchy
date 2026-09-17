import ArgumentParser
import Foundation
import ThemeCore

enum MenuTerminal {
  enum Kind {
    case maintenance
    case profile
  }

  static func launch(
    _ kind: Kind, arguments: [String], theme: NormalizedTheme, executableURL: URL,
    kittyApplicationURL: URL = URL(filePath: "/Applications/kitty.app"),
    yabaiURL: URL = URL(filePath: "/opt/homebrew/bin/yabai"),
    launcherURL: URL = URL(filePath: "/usr/bin/open")
  ) throws -> Process {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: kittyApplicationURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ValidationError("Kitty application is unavailable: \(kittyApplicationURL.path)")
    }
    if kind == .maintenance {
      // Only maintenance floats. Editors retain ordinary native titles and
      // tiling; opening one must not require or change the window manager.
      let rule = Process()
      rule.executableURL = yabaiURL
      rule.arguments = [
        "-m", "rule", "--add", "label=macarchy-maintenance",
        "app=^kitty$", "title=^Macarchy Maintenance$", "manage=off", "grid=20:20:7:7:6:6",
      ]
      let output = Pipe()
      rule.standardOutput = output
      rule.standardError = output
      try rule.run()
      let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
      rule.waitUntilExit()
      guard rule.terminationReason == .exit, rule.terminationStatus == 0 else {
        throw ValidationError(
          "Could not float the menu terminal (yabai \(rule.terminationStatus)): "
            + String(decoding: diagnostics, as: UTF8.self))
      }
    }
    let terminal = theme.terminal
    var colors = [
      "foreground=\(terminal.foreground.rawValue)",
      "background=\(terminal.background.rawValue)",
      "cursor=\(terminal.cursor.rawValue)",
      "cursor_text_color=\(terminal.background.rawValue)",
      "selection_foreground=\(terminal.selectionForeground.rawValue)",
      "selection_background=\(terminal.selectionBackground.rawValue)",
    ]
    colors += terminal.ansi.enumerated().map { "color\($0.offset)=\($0.element.rawValue)" }
    let process = Process()
    // Kitty documents LaunchServices, not --detach, on macOS. A direct child
    // can die with the invoking terminal after this short-lived menu exits.
    process.executableURL = launcherURL
    process.arguments =
      ["-n", "-a", kittyApplicationURL.path, "--args"]
      + (kind == .maintenance ? ["--title", "Macarchy Maintenance"] : [])
      + [
        "--override", "startup_session=none",
        "--override", "macos_quit_when_last_window_closed=yes",
      ] + colors.flatMap { ["--override", $0] }
      + [executableURL.path] + arguments
    let launchOutput = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = launchOutput
    process.standardError = launchOutput
    try process.run()
    let launchDiagnostics = launchOutput.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw ValidationError(
        "Could not open the menu terminal (open \(process.terminationStatus)): "
          + String(decoding: launchDiagnostics, as: UTF8.self))
    }
    return process
  }

}
