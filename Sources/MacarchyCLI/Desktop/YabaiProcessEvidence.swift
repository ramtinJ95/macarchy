import Foundation
import ThemeCore

struct YabaiProcessSnapshot: Equatable, Sendable {
  let processID: Int32
  let executablePath: String
  let arguments: [String]

  /// An exited candidate no longer participates in the live daemon inventory.
  /// Unreadable live processes and identity changes remain errors, not exclusions.
  static func observe(_ processID: Int32) throws -> Self? {
    do {
      guard let identity = ProcessIdentity.observe(processID) else {
        throw YabaiDesktopError.lifecycle("cannot resolve yabai PID \(processID)")
      }
      let arguments = try processArguments(processID)
      guard ProcessIdentity.observe(processID) == identity else {
        throw YabaiDesktopError.lifecycle("yabai PID \(processID) changed during inspection")
      }
      return Self(
        processID: processID, executablePath: identity.executablePath, arguments: arguments)
    } catch {
      if processHasExited(processID) { return nil }
      throw error
    }
  }
}

enum YabaiProcessEvidence {
  static func inspect(
    processIDs: [Int32],
    expectedExecutable: String,
    snapshot: (Int32) throws -> YabaiProcessSnapshot?
  ) throws -> (processID: Int32, executablePath: String)? {
    guard processIDs.allSatisfy({ $0 > 0 }) else {
      throw YabaiDesktopError.lifecycle("invalid UID-scoped yabai process identity")
    }
    var daemons: [YabaiProcessSnapshot] = []
    for processID in processIDs {
      guard let process = try snapshot(processID) else { continue }
      guard process.processID == processID else {
        throw YabaiDesktopError.lifecycle("yabai PID \(processID) changed during inspection")
      }
      guard process.executablePath == expectedExecutable else {
        throw YabaiDesktopError.lifecycle(
          "yabai PID \(processID) uses unsupported executable \(process.executablePath)")
      }
      guard let name = process.arguments.first, !name.isEmpty else {
        throw YabaiDesktopError.lifecycle("cannot inspect arguments of yabai PID \(processID)")
      }
      // yabai 7.1.25 parse_arguments selects client mode ONLY at argv[1].
      // A flag used as a config value or in another position is not client proof.
      if process.arguments.dropFirst().first == "-m"
        || process.arguments.dropFirst().first == "--message"
      {
        continue
      }
      daemons.append(process)
    }
    if daemons.isEmpty { return nil }
    guard daemons.count == 1, let daemon = daemons.first else {
      throw YabaiDesktopError.lifecycle(
        "expected one UID-scoped yabai daemon; found \(daemons.count)")
    }
    return (daemon.processID, daemon.executablePath)
  }
}
