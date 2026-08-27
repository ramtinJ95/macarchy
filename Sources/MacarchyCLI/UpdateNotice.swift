import Darwin
import Foundation

struct UpdateNoticeRunner: Sendable {
  let isInteractive: @Sendable () -> Bool
  let automaticChecksEnabled: @Sendable () -> Bool
  let checkIfDue: @Sendable (URL) -> UpdateCheckExecution
  let installedVersion: @Sendable () throws -> String
  let write: @Sendable (String) throws -> Void

  static let live = UpdateNoticeRunner(
    isInteractive: {
      isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1
    },
    automaticChecksEnabled: {
      ProcessInfo.processInfo.environment["MACARCHY_DISABLE_UPDATE_CHECKS"] != "1"
    },
    checkIfDue: { root in
      UpdateChecker(root: root, httpClient: .live, now: Date.init)
        .check(ifStaleOnly: true)
    },
    installedVersion: { try RuntimeEnvironment.live.buildInformation().version },
    write: {
      try FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8))
    }
  )

  func run(stateRoot: URL) {
    guard isInteractive(),
      automaticChecksEnabled(),
      let installed = try? installedVersion(),
      let installedVersion = StableVersion(installed)
    else {
      return
    }
    let execution = checkIfDue(stateRoot)
    guard execution.refreshed,
      execution.cache.lastAttempt.outcome == .success,
      let release = execution.cache.lastSuccess?.release,
      let availableVersion = StableVersion(release.version),
      availableVersion > installedVersion
    else {
      return
    }
    try? write(
      "Macarchy \(release.version) is available upstream; run macarchy update status."
    )
  }
}
