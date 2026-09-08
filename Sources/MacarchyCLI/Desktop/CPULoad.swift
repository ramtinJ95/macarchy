import Darwin
import Foundation

struct CPUTicks: Equatable {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32

  func utilization(since previous: Self) throws -> Int {
    let busy =
      UInt64(user &- previous.user) + UInt64(system &- previous.system)
      + UInt64(nice &- previous.nice)
    let total = busy + UInt64(idle &- previous.idle)
    guard total > 0 else { throw CPULoadError.noElapsedTicks }
    return Int(busy * 100 / total)
  }

  static func read() throws -> Self {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { throw CPULoadError.queryFailed(result) }
    return Self(
      user: info.cpu_ticks.0, system: info.cpu_ticks.1,
      idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
  }
}

enum CPULoadError: Error {
  case queryFailed(kern_return_t)
  case noElapsedTicks
}
