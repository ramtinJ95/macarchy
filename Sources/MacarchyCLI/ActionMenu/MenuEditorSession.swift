import ArgumentParser
import Foundation
import ThemeCore

/// One menu editor command in its menu terminal. Neovim runs in the terminal foreground,
/// and a failure stays on screen until dismissed so the terminal does not close over it.
enum MenuEditorSession {
  /// Runs `body`; a failure prints `summary`, the error and any `note`, waits for Enter,
  /// then exits with failure.
  static func run(failure summary: String, note: String? = nil, _ body: () throws -> Void) throws {
    do {
      try body()
    } catch {
      print("\(summary): \(error)\n" + (note.map { $0 + "\n" } ?? "") + "Press Enter to close.")
      _ = readLine()
      throw ExitCode.failure
    }
  }

  /// The menu's Neovim, refused up front when `name` is not executable.
  static func neovim(named name: String) throws -> URL {
    let neovim = NeovimAdapter.liveExecutableURL
    guard FileManager.default.isExecutableFile(atPath: neovim.path) else {
      throw ValidationError("\(name) is not executable: \(neovim.path)")
    }
    return neovim
  }

  /// Gives `body` a private directory for this session's files and removes it afterwards.
  static func withPrivateDirectory<Value>(
    prefix: String, _ body: (URL) throws -> Value
  ) throws -> Value {
    let temporary = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    return try body(temporary)
  }

  /// Runs `neovim` in the terminal foreground; any exit but a clean one throws `exitFailure`.
  static func edit(
    _ neovim: URL, arguments: [String], directory: URL?, exitFailure: (Process) -> String
  ) throws {
    let editor = Process()
    editor.executableURL = neovim
    if let directory { editor.currentDirectoryURL = directory }
    editor.arguments = arguments
    try MenuTerminal.runForeground(editor)
    guard editor.terminationReason == .exit, editor.terminationStatus == 0 else {
      throw ValidationError(exitFailure(editor))
    }
  }
}
