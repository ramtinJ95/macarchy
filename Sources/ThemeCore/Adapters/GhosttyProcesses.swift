import AppKit
import Darwin

/// A GUI registration alone is not executable identity; a matching executable alone may be
/// a short-lived CLI invocation. Require both, then recheck PID/start/path before signalling.
struct GhosttyProcesses: Sendable {
  struct Instance: Sendable {
    let identity: ProcessIdentity
    let isGUI: Bool
  }

  let list: @Sendable () throws -> [Instance]
  let observe: @Sendable (Int32) -> ProcessIdentity?
  let signal: @Sendable (Int32) throws -> Void

  enum Failure: Error, CustomStringConvertible {
    case enumeration
    case changed(Int32)
    case signal(Int32, Int32)

    var description: String {
      switch self {
      case .enumeration: "Cannot enumerate Ghostty processes within the PID bound"
      case .changed(let pid): "Ghostty process identity changed before reload (PID \(pid))"
      case .signal(let pid, let code): "Cannot reload Ghostty PID \(pid) (errno \(code))"
      }
    }
  }

  static let live = Self(
    list: {
      var pids = [pid_t](repeating: 0, count: 16_384)
      let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
      let bytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &pids, capacity)
      guard bytes > 0, bytes < capacity else { throw Failure.enumeration }
      return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).compactMap { pid in
        guard pid > 0, let identity = ProcessIdentity.observe(pid) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let isGUI =
          app?.bundleIdentifier == "com.mitchellh.ghostty"
          && app?.activationPolicy != .prohibited && app?.isTerminated == false
        return Instance(identity: identity, isGUI: isGUI)
      }
    },
    observe: ProcessIdentity.observe,
    signal: { pid in
      guard kill(pid, SIGUSR2) == 0 else { throw Failure.signal(pid, errno) }
    })

  func matching(executablePath: String) throws -> [ProcessIdentity] {
    try list().filter { $0.isGUI && $0.identity.executablePath == executablePath }.map(\.identity)
  }

  func reload(_ identity: ProcessIdentity) throws {
    guard observe(identity.pid) == identity else { throw Failure.changed(identity.pid) }
    try signal(identity.pid)
  }
}
