import Foundation
import Synchronization
import ThemeCore

@testable import MacarchyCLI

/// launchctl for one job: `print` answers from `loaded`, bootstrap and bootout change it, and
/// kickstart runs a loaded job.
final class LaunchdFake: Sendable {
  struct State {
    var loaded = false
    /// Whether the job's process runs. A job whose process exited cleanly stays loaded.
    var running = false
    /// Overrides the status `print` answers with.
    var printStatus: Int32?
    var bootstrapStatus: Int32 = 0
    var bootoutStatus: Int32 = 0
    var requests: [ProcessRequest] = []
  }

  let state = Mutex(State())

  var requests: [ProcessRequest] { state.withLock { $0.requests } }
  var calls: [[String]] { requests.map(\.arguments) }
  var loaded: Bool { state.withLock { $0.loaded } }
  var running: Bool { state.withLock { $0.running } }

  var runner: ProcessRunner {
    ProcessRunner { request in
      self.state.withLock { state in
        state.requests.append(request)
        switch request.arguments.first {
        case "print":
          let status = state.printStatus ?? (state.loaded ? 0 : 113)
          return ProcessResult(terminationStatus: status, output: "")
        case "bootstrap":
          guard state.bootstrapStatus == 0 else {
            return ProcessResult(
              terminationStatus: state.bootstrapStatus,
              output: "Bootstrap failed: 5: Input/output error")
          }
          state.loaded = true
          state.running = true
          return ProcessResult(terminationStatus: 0, output: "")
        case "bootout":
          guard state.bootoutStatus == 0 else {
            return ProcessResult(
              terminationStatus: state.bootoutStatus,
              output: "Boot-out failed: 5: Input/output error")
          }
          state.loaded = false
          state.running = false
          return ProcessResult(terminationStatus: 0, output: "")
        case "kickstart":
          guard state.loaded else {
            return ProcessResult(terminationStatus: 113, output: "Could not find service")
          }
          state.running = true
          return ProcessResult(terminationStatus: 0, output: "")
        default:
          return ProcessResult(terminationStatus: 64, output: "unexpected launchctl call")
        }
      }
    }
  }
}
