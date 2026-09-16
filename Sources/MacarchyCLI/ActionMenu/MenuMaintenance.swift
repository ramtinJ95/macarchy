import ArgumentParser
import Foundation
import ThemeCore

enum MaintenanceAction: String, CaseIterable, ExpressibleByArgument, Sendable {
  case plan
  case status
  case doctor
  case updateCheck = "update-check"

  var title: String {
    switch self {
    case .plan: "Preview setup changes"
    case .status: "Setup status"
    case .doctor: "Setup doctor"
    case .updateCheck: "Check for updates"
    }
  }

  var arguments: [String] {
    switch self {
    case .plan, .status, .doctor: ["setup", rawValue]
    case .updateCheck: ["update", "check"]
    }
  }
}

struct MenuMaintenance: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-maintenance", shouldDisplay: false)

  @Argument var action: MaintenanceAction

  mutating func run() throws {
    let status = Self.runAndHold(
      action, executableURL: RuntimeEnvironment.live.executableURL,
      write: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
      dismiss: { _ = readLine() })
    if status != 0 { throw ExitCode(status) }
  }

  static func launch(
    _ action: MaintenanceAction, theme: NormalizedTheme, executableURL: URL,
    kittyURL: URL = URL(filePath: "/opt/homebrew/bin/kitty"),
    yabaiURL: URL = URL(filePath: "/opt/homebrew/bin/yabai")
  ) throws -> Process {
    guard FileManager.default.isExecutableFile(atPath: kittyURL.path) else {
      throw ValidationError("Maintenance terminal is not executable: \(kittyURL.path)")
    }
    // Replacing our labelled runtime rule is idempotent and affects only future
    // maintenance windows. Native configuration and existing windows stay intact.
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
        "Could not float the maintenance terminal (yabai \(rule.terminationStatus)): "
          + String(decoding: diagnostics, as: UTF8.self))
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
    process.executableURL = kittyURL
    process.arguments =
      [
        "--title", "Macarchy Maintenance",
        "--override", "startup_session=none",
        "--override", "macos_quit_when_last_window_closed=yes",
      ] + colors.flatMap { ["--override", $0] }
      + [executableURL.path, "_menu-maintenance", action.rawValue]
    try process.run()
    return process
  }

  static func runAndHold(
    _ action: MaintenanceAction, executableURL: URL,
    write: (String) -> Void, dismiss: () -> Void
  ) -> Int32 {
    write(action.title)
    write("macarchy " + action.arguments.joined(separator: " "))
    write(
      action == .updateCheck
        ? "Refreshes the local update-check cache; does not install updates.\n"
        : "Inspection only; no apply or install.\n")
    let process = Process()
    process.executableURL = executableURL
    process.arguments = action.arguments
    let status: Int32
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationReason == .uncaughtSignal {
        status = 128 + process.terminationStatus
        write("\nTERMINATED by signal \(process.terminationStatus)")
      } else {
        status = process.terminationStatus
        write(status == 0 ? "\nSUCCESS (exit 0)" : "\nFAILED (exit \(status))")
      }
    } catch {
      status = 1
      write("\nCould not launch command: \(error)")
    }
    write("Press Enter to close.")
    dismiss()
    return status
  }
}
