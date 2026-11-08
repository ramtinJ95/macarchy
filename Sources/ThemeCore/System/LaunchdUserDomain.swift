import Darwin
import Foundation

/// What `launchctl print` reports for one service in a user's GUI domain. Each caller keeps
/// its own rules for matching the printed job and its own error text.
package enum LaunchdServiceState: Equatable, Sendable {
  /// `launchctl print` exits 113 when the domain has no service with this label.
  case notLoaded(output: String)
  case loaded(output: String)
  case failed(ProcessResult)

  /// The printed job when loaded and nil when not; any other status throws the caller's error.
  package func loadedOutput(orThrow failure: (ProcessResult) -> any Error) throws -> String? {
    switch self {
    case .loaded(let output): return output
    case .notLoaded: return nil
    case .failed(let result): throw failure(result)
    }
  }
}

/// A user's launchd GUI domain, `gui/<uid>`, and the service targets inside it.
package struct LaunchdUserDomain: Equatable, Sendable {
  package let userID: uid_t

  package init(userID: uid_t = getuid()) {
    self.userID = userID
  }

  package var target: String { "gui/\(userID)" }

  package func serviceTarget(_ label: String) -> String { "\(target)/\(label)" }

  package func printService(
    _ label: String, timeout: TimeInterval, runner: ProcessRunner
  ) throws -> LaunchdServiceState {
    let result = try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/launchctl"),
        arguments: ["print", serviceTarget(label)], timeout: timeout))
    switch result.terminationStatus {
    case 0: return .loaded(output: result.output)
    case 113: return .notLoaded(output: result.output)
    default: return .failed(result)
    }
  }
}
