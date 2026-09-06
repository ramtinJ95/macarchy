import Darwin
import Foundation
import ThemeCore

/// The mutator must not start before its process identity is durable. Unlike
/// metadata subprocesses, an orphaned installer can continue changing packages.
enum HomebrewFormulaInstallProcess {
  static func groupExists(_ group: Int32) throws -> Bool {
    guard group > 1 else { throw SetupPackageAdoptionError("Invalid installation process group.") }
    if kill(-group, 0) == 0 || errno == EPERM { return true }
    guard errno == ESRCH else {
      throw SetupPackageAdoptionError("Cannot inspect installation process group (errno \(errno)).")
    }
    return false
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
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    try require(posix_spawnattr_setpgroup(&attributes, 0))
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
    defer {
      if !reaped {
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      }
    }
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
        if try groupExists(pid) {
          _ = kill(-pid, SIGKILL)
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
      "Native installation exceeded its execution limit; its process group was terminated. Use --recover for observed partial state."
    )
  }
}
