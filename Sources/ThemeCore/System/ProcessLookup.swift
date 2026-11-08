import Darwin
import Foundation

/// Which owner `pgrep` restricts matches to. Callers differ by history; each keeps its own flag
/// and argument order.
package enum ProcessLookupOwner: Sendable {
  /// No owner flag: `-x <pattern>`.
  case anyUser
  /// Effective user ID: `-u <uid> -x <pattern>`.
  case effectiveUser
  /// Real user ID: `-x -U <uid> <pattern>`.
  case realUser
}

extension ProcessRequest {
  /// `/usr/bin/pgrep` for processes whose whole `p_comm` matches `pattern`, restricted to this
  /// process's real UID as `owner` says. `includeAncestors` prepends `-a`. pgrep exits 0 with
  /// one PID per line, or 1 when nothing matches.
  package static func processLookup(
    _ pattern: String,
    owner: ProcessLookupOwner,
    includeAncestors: Bool = false,
    timeout: TimeInterval
  ) -> ProcessRequest {
    let uid = String(getuid())
    let selection: [String] =
      switch owner {
      case .anyUser: ["-x", pattern]
      case .effectiveUser: ["-u", uid, "-x", pattern]
      case .realUser: ["-x", "-U", uid, pattern]
      }
    return ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/pgrep"),
      arguments: (includeAncestors ? ["-a"] : []) + selection,
      timeout: timeout)
  }
}
