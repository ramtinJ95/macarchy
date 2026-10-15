import Darwin

/// The executable path of `pid`, or nil when the kernel cannot resolve it.
package func processExecutablePath(_ pid: Int32) -> String? {
  var buffer = [CChar](repeating: 0, count: 4_096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}
