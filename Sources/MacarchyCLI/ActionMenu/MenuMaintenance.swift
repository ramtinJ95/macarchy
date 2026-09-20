import ArgumentParser
import Foundation
import ThemeCore

enum MaintenanceAction: String, CaseIterable, ExpressibleByArgument, Sendable {
  case plan
  case apply
  case status
  case doctor
  case updateCheck = "update-check"
  case update

  var title: String {
    switch self {
    case .plan: "Preview setup changes"
    case .apply: "Review & apply configuration"
    case .status: "Setup status"
    case .doctor: "Setup doctor"
    case .updateCheck: "Check for updates"
    case .update: "Review & update Macarchy"
    }
  }

  var arguments: [String] {
    switch self {
    case .plan, .status, .doctor: ["setup", rawValue]
    case .apply: ["setup", "apply", "--review"]
    case .updateCheck: ["update", "check"]
    case .update: ["update", "--review"]
    }
  }
}

struct MenuMaintenance: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-maintenance", shouldDisplay: false)

  @Argument var action: MaintenanceAction
  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    let status = Self.runAndHold(
      action, executableURL: RuntimeEnvironment.live.executableURL,
      profileArguments: profiles.menuArguments,
      write: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
      dismiss: { _ = readLine() })
    if status != 0 { throw ExitCode(status) }
  }

  static func launch(
    _ action: MaintenanceAction, theme: NormalizedTheme, executableURL: URL,
    profileArguments: [String] = [],
    kittyApplicationURL: URL = URL(filePath: "/Applications/kitty.app"),
    yabaiURL: URL = URL(filePath: "/opt/homebrew/bin/yabai"),
    launcherURL: URL = URL(filePath: "/usr/bin/open")
  ) throws -> Process {
    try MenuTerminal.launch(
      .maintenance, arguments: ["_menu-maintenance", action.rawValue] + profileArguments,
      theme: theme, executableURL: executableURL, kittyApplicationURL: kittyApplicationURL,
      yabaiURL: yabaiURL,
      launcherURL: launcherURL)
  }

  static func runAndHold(
    _ action: MaintenanceAction, executableURL: URL,
    profileArguments: [String] = [],
    write: (String) -> Void, dismiss: () -> Void
  ) -> Int32 {
    let arguments =
      action.arguments + (action == .updateCheck || action == .update ? [] : profileArguments)
    write(action.title)
    write("macarchy " + arguments.joined(separator: " "))
    switch action {
    case .apply, .update:
      write("Review first; mutation requires explicit confirmation.\n")
    case .updateCheck:
      write("Refreshes the local update-check cache; does not install updates.\n")
    default:
      write("Inspection only; no apply or install.\n")
    }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let status: Int32
    do {
      try MenuTerminal.runForeground(process)
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
