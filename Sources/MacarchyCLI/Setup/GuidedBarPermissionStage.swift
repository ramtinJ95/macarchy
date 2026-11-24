import Foundation

enum GuidedPermissionVerdict: String, Sendable {
  case verified
  case notGranted = "not_granted"
  case failed
  case couldNotVerify = "could_not_verify"
}

/// Transient, token-correlated evidence from one actual bar-launched subprocess.
/// This is not persisted consent or a substitute for the current generation/service.
struct GuidedBarPermissionStage: Equatable, Sendable {
  enum Phase: String { case pending, running, complete, timeout }
  let phase: Phase
  let started: Double
  let finished: Double
  let exitStatus: Int32

  static func decode(_ marker: String, token: String) -> Self? {
    let fields = marker.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 7, fields[0] == "permission", fields[1] == "v2",
      fields[2] == token, let phase = Phase(rawValue: String(fields[3])),
      let start = Double(fields[4]), start.isFinite, start >= 0,
      let end = Double(fields[5]), end.isFinite, end >= 0,
      let status = Int32(fields[6])
    else { return nil }
    switch phase {
    case .pending: guard start == 0, end == 0, status == -1 else { return nil }
    case .running: guard start > 0, end == 0, status == -1 else { return nil }
    case .complete:
      guard start > 0, end >= start, (0...255).contains(status) else { return nil }
    case .timeout: guard end >= start, end > 0, status == -1 else { return nil }
    }
    return .init(phase: phase, started: start, finished: end, exitStatus: status)
  }

  func verdict(automation: Bool) -> GuidedPermissionVerdict {
    guard phase == .complete else { return .couldNotVerify }
    if exitStatus == 0 { return .verified }
    return automation && exitStatus == 77 ? .notGranted : .failed
  }

  func diagnostic(name: String) -> String {
    "\(name) stage: \(phase.rawValue); start=\(started), end=\(finished), exit=\(exitStatus)"
      + (phase == .complete ? String(format: "; elapsed=%.3f s", finished - started) : "")
  }
}
