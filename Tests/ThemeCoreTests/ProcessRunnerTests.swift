import Foundation
import Testing

@testable import ThemeCore

struct ProcessRunnerTests {
  @Test
  func processRunnerDrainsOutputWhileTimedCommandsAreRunning() throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/jot"),
        arguments: ["-b", "macarchy-output", "8192"], timeout: 2)
    )
    #expect(result.terminationStatus == 0)
    #expect(result.output.split(separator: "\n").count == 8192)
  }

  @Test
  func processRunnerTerminatesTimedOutCommands() throws {
    let executable = URL(filePath: "/bin/sleep")
    do {
      _ = try ProcessRunner.live.run(
        ProcessRequest(executableURL: executable, arguments: ["10"], timeout: 0.05)
      )
      Issue.record("Expected the process to time out")
    } catch let error as ProcessRunnerError {
      #expect(error == .timedOut(executable, 0.05))
    }
  }

  /// Runs untimed, the only test of the untimed path, and checks trailing-newline trimming.
  @Test
  func processRunnerAppliesEnvironmentOverridesAndRemovals() throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/env"),
        arguments: [],
        environmentOverrides: ["MACARCHY_PROCESS_TEST": "expected-value"],
        environmentRemovals: ["HOME"]
      )
    )

    let lines = result.output.split(separator: "\n")
    #expect(result.terminationStatus == 0)
    #expect(result.output.last?.isNewline == false)
    #expect(lines.contains("MACARCHY_PROCESS_TEST=expected-value"))
    #expect(!lines.contains { $0.hasPrefix("HOME=") })
  }
}
