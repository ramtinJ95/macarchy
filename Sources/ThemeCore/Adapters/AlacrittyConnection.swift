import Darwin
import Foundation

/// The first completed import/bridge publication, not the last theme switch.
/// A process predating this instant may never have watched the new imported file.
struct AlacrittyConnection: Codable, Sendable {
  let adoptedAt: UInt64

  enum CodingKeys: String, CodingKey {
    case adoptedAt = "adopted_at_microseconds"
  }

  enum Failure: Error, CustomStringConvertible {
    case invalid
    case observation(String)
    var description: String {
      switch self {
      case .invalid: "Invalid Alacritty adoption timestamp; restore the owned connection state."
      case .observation(let detail): "Cannot determine Alacritty process start times: \(detail)"
      }
    }
  }

  static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000) }

  static func read(root: URL) throws -> Self? {
    let data: Data
    do {
      data = try PinnedFilesystem.readRegularFile(
        at: root.appending(path: AlacrittyAdapter.connectionPath)
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.adoptedAt > 0 else { throw Failure.invalid }
    return value
  }

  /// Current-user Alacritty processes, including directly launched app executables.
  /// pgrep only enumerates PIDs; the shared kernel observation supplies start identity.
  static func runningProcessStarts() throws -> [UInt64] {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-u", String(getuid()), "-x", "alacritty"], timeout: 5))
    if result.terminationStatus == 1
      && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return []
    }
    guard result.terminationStatus == 0 else { throw Failure.observation(result.output) }
    let pids = result.output.split(whereSeparator: \.isWhitespace)
    guard !pids.isEmpty else { throw Failure.observation("empty successful process listing") }
    return try pids.compactMap { value in
      guard let pid = Int32(value), pid > 0 else {
        throw Failure.observation("invalid PID \(value)")
      }
      if let started = processStartTime(pid) { return started }
      guard processHasExited(pid) else { throw Failure.observation("unreadable live PID \(pid)") }
      return nil
    }
  }
}
