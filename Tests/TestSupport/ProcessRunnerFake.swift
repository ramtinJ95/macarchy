import Foundation
import Synchronization
import ThemeCore

/// A `ProcessRunner` that answers from a script and records every request it receives.
///
/// A request gets the first reply whose executable and arguments match (an omitted field
/// matches anything), otherwise the default result. Fakes that change state, inspect requests
/// as they arrive or throw are clearer written inline.
package final class ProcessRunnerFake: Sendable {
  package struct Reply: Sendable {
    let executableURL: URL?
    let arguments: [String]?
    let result: ProcessResult

    package init(
      executableURL: URL? = nil,
      arguments: [String]? = nil,
      status: Int32 = 0,
      output: String = ""
    ) {
      self.executableURL = executableURL
      self.arguments = arguments
      result = ProcessResult(terminationStatus: status, output: output)
    }

    func matches(_ request: ProcessRequest) -> Bool {
      (executableURL.map { $0 == request.executableURL } ?? true)
        && (arguments.map { $0 == request.arguments } ?? true)
    }
  }

  private let replies: [Reply]
  private let fallback: ProcessResult
  private let recorded = Mutex<[ProcessRequest]>([])

  /// Answers `replies` where they match and `status`/`output` otherwise.
  package init(status: Int32 = 0, output: String = "", replies: [Reply] = []) {
    self.replies = replies
    fallback = ProcessResult(terminationStatus: status, output: output)
  }

  /// Every request run so far, in order.
  package var requests: [ProcessRequest] { recorded.withLock { $0 } }

  package var runner: ProcessRunner {
    ProcessRunner { request in
      self.recorded.withLock { $0.append(request) }
      return self.replies.first { $0.matches(request) }?.result ?? self.fallback
    }
  }
}
