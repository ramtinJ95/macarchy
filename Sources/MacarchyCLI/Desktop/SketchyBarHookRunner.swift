import Darwin
import Foundation

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
    var attributes: posix_spawnattr_t?
    let initializationStatus = posix_spawnattr_init(&attributes)
    guard initializationStatus == 0 else {
      throw SketchyBarHookRunnerError.spawn(initializationStatus)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    let flagsStatus = posix_spawnattr_setflags(&attributes, flags)
    guard flagsStatus == 0 else {
      throw SketchyBarHookRunnerError.spawn(flagsStatus)
    }
    let groupStatus = posix_spawnattr_setpgroup(&attributes, 0)
    guard groupStatus == 0 else {
      throw SketchyBarHookRunnerError.spawn(groupStatus)
    }

    let arguments = ["/bin/sh", hook.path]
    let storage = arguments.compactMap { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    guard storage.count == arguments.count else {
      throw SketchyBarHookRunnerError.spawn(ENOMEM)
    }
    var argumentPointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 }
    argumentPointers.append(nil)
    var processID: pid_t = 0
    let spawnStatus = posix_spawn(
      &processID,
      "/bin/sh",
      nil,
      &attributes,
      &argumentPointers,
      environ
    )
    guard spawnStatus == 0 else {
      throw SketchyBarHookRunnerError.spawn(spawnStatus)
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
    let signal = status & 0x7f
    guard signal == 0 else { throw SketchyBarHookRunnerError.failed(128 + signal) }
    let exitStatus = (status >> 8) & 0xff
    guard exitStatus == 0 else { throw SketchyBarHookRunnerError.failed(exitStatus) }
  }

  private func terminateAndReap(_ processID: pid_t) {
    _ = kill(-processID, SIGKILL)
    var status: Int32 = 0
    while waitpid(processID, &status, 0) == -1, errno == EINTR {}
  }

  private func terminateRemainingGroup(_ processID: pid_t) {
    if kill(-processID, 0) == 0 {
      _ = kill(-processID, SIGKILL)
    }
  }
}
