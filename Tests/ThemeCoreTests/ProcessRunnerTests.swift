import Darwin
import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct ProcessRunnerTests {
  @Test(arguments: [false, true])
  func processRunnerDrainsOutputWhileTimedCommandsAreRunning(isolated: Bool) throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/jot"),
        arguments: ["-b", "macarchy-output", "8192"], timeout: 2,
        isolatedProcessGroup: isolated)
    )
    #expect(result.terminationStatus == 0)
    #expect(result.output.split(separator: "\n").count == 8192)
  }

  @Test(arguments: [false, true])
  func inheritedOutputDoesNotExtendTimeout(isolated: Bool) throws {
    try withTemporaryRoot(named: "process-output-descendant") { directory in
      let childFile = directory.appending(path: "child")
      defer {
        if let text = try? String(contentsOf: childFile, encoding: .utf8),
          let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          _ = kill(child, SIGKILL)
        }
      }
      let executable = URL(filePath: "/bin/sh")
      let started = ContinuousClock.now
      #expect(throws: ProcessRunnerError.timedOut(executable, 0.5)) {
        try ProcessRunner.live.run(
          .init(
            executableURL: executable,
            arguments: [
              "-c", "trap '' TERM; /bin/sleep 30 & echo $! > \"$1\"; wait", "cli", childFile.path,
            ],
            timeout: 0.5, isolatedProcessGroup: isolated))
      }
      #expect(ContinuousClock.now - started < .seconds(3))
      let child = try #require(
        Int32(
          try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)))
      if isolated {
        try expectStopped(child)
      } else {
        // Proves EOF was still withheld on the shared path.
        #expect(kill(child, 0) == 0)
      }
    }
  }

  @Test func isolatedWrapperExitStopsDescendantsAndPreservesOutputStatusAndEnvironment() throws {
    try withTemporaryRoot(named: "process-group-exit") { directory in
      let childFile = directory.appending(path: "child")
      let result = try ProcessRunner.live.run(
        .init(
          executableURL: URL(filePath: "/bin/sh"),
          arguments: [
            "-c",
            "/bin/sleep 30 & echo $! > \"$1\"; echo \"$MACARCHY_PROCESS_TEST\"; echo stderr >&2; exit 7",
            "cli", childFile.path,
          ],
          timeout: 2, environmentOverrides: ["MACARCHY_PROCESS_TEST": "isolated"],
          environmentRemovals: ["VSCODE_EXTENSIONS"], isolatedProcessGroup: true))
      #expect(result.terminationStatus == 7)
      #expect(result.output == "isolated\nstderr")
      let child = try #require(
        Int32(
          try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)))
      defer { _ = kill(child, SIGKILL) }
      try expectStopped(child)
    }
  }

  private func expectStopped(_ pid: pid_t) throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
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
