import Foundation

struct SpicetifyAdapter: Sendable {
  static let id = "spicetify"

  let executableURL: URL
  let processRunner: ProcessRunner

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .optional) {
      let result = try processRunner.run(
        ProcessRequest(executableURL: executableURL, arguments: ["apply"])
      )
      guard result.terminationStatus == 0 else {
        return AdapterOutcome(
          status: .failed,
          message: result.output.isEmpty
            ? "Spicetify apply exited with status \(result.terminationStatus)"
            : result.output
        )
      }
      return AdapterOutcome(status: .applied)
    }
  }
}
