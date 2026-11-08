import Darwin
import Foundation
import ThemeCore

enum SketchyBarHookRunnerError: Error, CustomStringConvertible {
  case spawn(Int32)
  case wait(Int32)
  case timedOut
  case failed(Int32)

  var description: String {
    switch self {
    case .spawn(let code):
      "cannot start trusted SketchyBar hook: \(String(cString: strerror(code)))"
    case .wait(let code):
      "cannot wait for trusted SketchyBar hook: \(String(cString: strerror(code)))"
    case .timedOut:
      "trusted SketchyBar hook exceeded its execution limit"
    case .failed(let status):
      "trusted SketchyBar hook failed with status \(status)"
    }
  }
}

struct SketchyBarHookRunner {
  static let executionLimit: TimeInterval = 3

  let executionLimit: TimeInterval
  let pollInterval: TimeInterval

  init(
    executionLimit: TimeInterval = Self.executionLimit,
    pollInterval: TimeInterval = 0.01
  ) {
    self.executionLimit = executionLimit
    self.pollInterval = pollInterval
  }

  func execute(_ hook: URL) throws {
    let processID: pid_t
    let spawned = ChildProcess.spawn(
      "/bin/sh", arguments: [hook.path], flags: POSIX_SPAWN_SETPGROUP, processGroup: 0)
    switch spawned {
    case .success(let pid): processID = pid
    case .failure(.prepare(let code)), .failure(.spawn(let code)):
      throw SketchyBarHookRunnerError.spawn(code)
    case .failure(.allocateArguments): throw SketchyBarHookRunnerError.spawn(ENOMEM)
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(executionLimit))
    var status: Int32 = 0
    while clock.now < deadline {
      let result = waitpid(processID, &status, WNOHANG)
      if result == processID {
        terminateRemainingGroup(processID)
        return try requireSuccess(status)
      }
      if result == -1, errno != EINTR {
        terminateAndReap(processID)
        throw SketchyBarHookRunnerError.wait(errno)
      }
      Thread.sleep(forTimeInterval: pollInterval)
    }

    terminateAndReap(processID)
    throw SketchyBarHookRunnerError.timedOut
  }

  private func requireSuccess(_ status: Int32) throws {
    let code = ChildProcess.exitCode(waitStatus: status)
    guard code == 0 else { throw SketchyBarHookRunnerError.failed(code) }
  }

  private func terminateAndReap(_ processID: pid_t) {
    ChildProcess.killAndReap(processID, target: -processID)
  }

  private func terminateRemainingGroup(_ processID: pid_t) {
    if kill(-processID, 0) == 0 {
      _ = kill(-processID, SIGKILL)
    }
  }
}
