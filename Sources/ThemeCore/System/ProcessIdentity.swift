import Darwin

/// The executable path of `pid`, or nil when the kernel cannot resolve it.
package func processExecutablePath(_ pid: Int32) -> String? {
  var buffer = [CChar](repeating: 0, count: 4_096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

/// The start time of the current user's `pid` in microseconds, or nil when the kernel cannot
/// resolve it or another user owns it. Comparing it with a recorded value detects PID reuse.
package func processStartTime(_ pid: Int32) -> UInt64? {
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid()
  else { return nil }
  return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

/// A live process's PID, start time and executable path, read together. Each record that stores
/// these keeps its own type and keys; this is only the observation.
package struct ProcessIdentity: Equatable, Sendable {
  package let pid: Int32
  /// Microseconds, as `processStartTime` returns.
  package let started: UInt64
  package let executablePath: String

  package init(pid: Int32, started: UInt64, executablePath: String) {
    self.pid = pid
    self.started = started
    self.executablePath = executablePath
  }

  /// The identity of `pid`, or nil when the kernel cannot resolve its start time or path.
  /// The path is not read when the start time cannot be.
  package static func observe(_ pid: Int32) -> Self? {
    guard let started = processStartTime(pid), let path = processExecutablePath(pid) else {
      return nil
    }
    return Self(pid: pid, started: started, executablePath: path)
  }
}

/// Whether `pid` no longer exists. A zombie, or another user's process, still exists.
package func processHasExited(_ pid: Int32) -> Bool {
  kill(pid, 0) != 0 && errno == ESRCH
}

/// SIGTERMs `pid`, whose identity the caller just verified. One that already exited is not an
/// error; any other failure throws `failure` with its errno.
package func terminateVerifiedProcess(_ pid: Int32, orThrow failure: (Int32) -> any Error) throws {
  guard kill(pid, SIGTERM) != 0 else { return }
  let code = errno
  guard code == ESRCH else { throw failure(code) }
}
