import Darwin
import Foundation
import ThemeCore

/// The mutator must not start before its process identity is durable. An orphaned installer can continue
/// changing packages after the CLI exits.
enum HomebrewPackageInstallProcess {
  static func sessionExists(_ session: Int32) throws -> Bool {
    try !sessionProcesses(session).isEmpty
  }

  private static func sessionProcesses(_ session: Int32) throws -> [pid_t] {
    guard session > 1 else { throw SetupPackageAdoptionError("Invalid installation session.") }
    var pids = [pid_t](repeating: 0, count: 16_384)
    let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &pids, capacity)
    guard bytes > 0, bytes < capacity else {
      throw SetupPackageAdoptionError(
        "Cannot enumerate installation processes within the PID bound.")
    }
    return try pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { pid in
      guard pid > 0 else { return false }
      let current = getsid(pid)
      guard current >= 0 || errno == ESRCH else {
        throw SetupPackageAdoptionError("Cannot inspect process session (errno \(errno)).")
      }
      return current == session
    }
  }

  private static func terminateSession(_ session: Int32) throws {
    // Homebrew's SystemCommand uses pgroup: true. Its children remain in this
    // session even though signalling the outer process group cannot reach them.
    for _ in 0..<20 {
      let pids = try sessionProcesses(session)
      if pids.isEmpty { return }
      for pid in pids where getsid(pid) == session {
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
          throw SetupPackageAdoptionError("Cannot terminate installation child (errno \(errno)).")
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw SetupPackageAdoptionError(
      "Installation session still has processes; recovery remains blocked.")
  }

  static func run(_ request: ProcessRequest, recordProcess: @Sendable (Int32) throws -> Void) throws
    -> Int32
  {
    guard request.environmentOverrides.isEmpty, request.environmentRemovals.isEmpty,
      let timeout = request.timeout, timeout > 0
    else {
      throw SetupPackageAdoptionError("Installation requires a bounded explicit env command.")
    }
    let pid: pid_t
    let spawned = ChildProcess.spawn(
      request.executableURL.path, arguments: request.arguments,
      flags: POSIX_SPAWN_SETSID | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
    switch spawned {
    case .success(let child):
      pid = child
    case .failure(.prepare(let code)), .failure(.spawn(let code)):
      throw SetupPackageAdoptionError("Installation process operation failed (errno \(code)).")
    case .failure(.allocateArguments):
      throw SetupPackageAdoptionError("Cannot allocate installation arguments.")
    }
    var reaped = false
    do {
      try recordProcess(pid)
      try Task.checkCancellation()
      guard kill(pid, SIGCONT) == 0 else {
        throw SetupPackageAdoptionError(
          "Cannot resume recorded installation process (errno \(errno)).")
      }
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(timeout))
      while clock.now < deadline {
        try Task.checkCancellation()
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
          reaped = true
          guard try !sessionExists(pid) else {
            throw SetupPackageAdoptionError(
              "Native installer left running descendants; success is unverified.")
          }
          return ChildProcess.exitCode(waitStatus: status)
        }
        if result == -1, errno != EINTR {
          throw SetupPackageAdoptionError("Cannot wait for installation process (errno \(errno)).")
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
      throw SetupPackageAdoptionError(
        "Native installation exceeded its execution limit; use --recover for observed partial state."
      )
    } catch {
      if !reaped { ChildProcess.killAndReap(pid, target: pid) }
      do { try terminateSession(pid) } catch let cleanup {
        throw SetupPackageAdoptionError("\(error); installation session cleanup failed: \(cleanup)")
      }
      throw error
    }
  }
}
