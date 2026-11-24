import Darwin
import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct ReadOnlyThemeProbeTests {
  @Test func aRealDeadlineIsBoundedAndExplicitlyUnconverged() throws {
    let start = ContinuousClock.now
    let outcome = try ReadOnlyThemeProbe.verify(adapterID: "atuin") {
      _ = try ProcessRunner.live.run(
        .init(executableURL: URL(filePath: "/bin/sleep"), arguments: ["30"], timeout: 0.05))
      Issue.record("The slow probe must not complete")
      return .init(status: .applied)
    }
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(outcome.status == .verificationTimedOut)
    #expect(outcome.message?.contains("atuin is not yet converged") == true)
    #expect(outcome.message?.contains("macarchy reconcile atuin") == true)
  }

  @Test func errorsAndCancellationAreNeverReclassifiedAsTimeouts() {
    for error in [POSIXError(.ENOENT), POSIXError(.EIO)] {
      #expect(throws: POSIXError.self) {
        try ReadOnlyThemeProbe.verify(adapterID: "starship") { throw error }
      }
    }
    #expect(throws: CancellationError.self) {
      try ReadOnlyThemeProbe.verify(adapterID: "starship") { throw CancellationError() }
    }
    let error = ProcessRunnerError.exitedWithIncompleteOutput(URL(filePath: "/test/eza"), 1, 7)
    #expect(throws: error) {
      try ReadOnlyThemeProbe.verify(adapterID: "eza") { throw error }
    }
  }

  @Test func knownErrorExitCannotBecomeARetainableDeadline() throws {
    try withTemporaryRoot(named: "read-only-error-output") { root in
      let pidFile = root.appending(path: "child")
      defer {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          _ = kill(pid, SIGKILL)
        }
      }
      let executable = URL(filePath: "/bin/sh")
      #expect(throws: ProcessRunnerError.exitedWithIncompleteOutput(executable, 0.5, 7)) {
        try ReadOnlyThemeProbe.verify(adapterID: "eza") {
          _ = try ProcessRunner.live.run(
            .init(
              executableURL: executable,
              arguments: ["-c", "/bin/sleep 30 & echo $! > \"$1\"; exit 7", "probe", pidFile.path],
              timeout: 0.5))
          return .init(status: .applied)
        }
      }
    }
  }
}

extension AdapterContractTests {
  @Test(arguments: ["atuin", "eza"], ["deadline", "rejected", "unavailable", "bad-output"])
  func readOnlyProbeDeadlinesDoNotHideRejection(adapterID: String, mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(root: root, adapterIDs: [adapterID])
    let executable = URL(filePath: "/test/" + adapterID)
    let runner = ProcessRunner { request in
      #expect(request.timeout == 5)
      #expect(mode != "unavailable")
      if mode == "deadline" { throw ProcessRunnerError.timedOut(executable, 5) }
      return .init(terminationStatus: mode == "rejected" ? 7 : 0, output: "unexpected")
    }
    let adapter: AdapterReconciliation
    if adapterID == "atuin" {
      adapter = AtuinAdapter(
        root: root, configurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
        executableURL: executable, controlIsAvailable: { mode != "unavailable" },
        processRunner: runner
      ).reconciliation()
    } else {
      adapter = EzaAdapter(
        root: root, configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
        shellConfigurationURL: paths.shellConfigurationURL, executableURL: executable,
        controlIsAvailable: { mode != "unavailable" }, processRunner: runner
      ).reconciliation()
    }
    let outcome = try await adapter.run()
    #expect(
      outcome.status
        == (mode == "deadline"
          ? .verificationTimedOut
          : adapterID == "eza" && mode == "bad-output" ? .applied : .failed))
  }
}
