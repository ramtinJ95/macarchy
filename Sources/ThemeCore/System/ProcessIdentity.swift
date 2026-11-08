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
