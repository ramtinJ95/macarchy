import Foundation

package struct DesktopShellSyntaxError: Error, CustomStringConvertible {
  package let source: URL
  package let reason: String
  package var description: String { "\(source.path): \(reason)" }
}

/// Parse only: never source personal code during planning or editing feedback.
package enum DesktopShellSyntax {
  package static func validate(_ text: String, source: URL) throws {
    guard !text.contains("\0"), !text.hasPrefix("\u{FEFF}") else {
      throw DesktopShellSyntaxError(
        source: source, reason: "shell input contains NUL or a UTF-8 BOM")
    }
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-n"]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
    } catch {
      try? input.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      throw DesktopShellSyntaxError(
        source: source, reason: "cannot validate /bin/sh syntax: \(error)")
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw DesktopShellSyntaxError(
        source: source, reason: "invalid /bin/sh syntax; saved input was not activated")
    }
  }
}
