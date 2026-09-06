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
    func require(_ code: Int32) throws {
      guard code == 0 else {
        throw SetupPackageAdoptionError("Installation process operation failed (errno \(code)).")
      }
    }
    var attributes: posix_spawnattr_t?
    try require(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try require(
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    let arguments = [request.executableURL.path] + request.arguments
    let storage = arguments.compactMap { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    guard storage.count == arguments.count else {
      throw SetupPackageAdoptionError("Cannot allocate installation arguments.")
    }
    var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 } + [nil]
    var pid: pid_t = 0
    try require(posix_spawn(&pid, request.executableURL.path, nil, &attributes, &pointers, environ))
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
          let signal = status & 0x7f
          return signal == 0 ? (status >> 8) & 0xff : 128 + signal
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
      if !reaped {
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      }
      do { try terminateSession(pid) } catch let cleanup {
        throw SetupPackageAdoptionError("\(error); installation session cleanup failed: \(cleanup)")
      }
      throw error
    }
  }
}
