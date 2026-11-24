import Foundation
import Testing

@testable import MacarchyCLI

struct YabaiProcessEvidenceTests {
  private let executable = "/opt/homebrew/Cellar/yabai/7.1.25/bin/yabai"

  @Test(arguments: ["-m", "--message"])
  func daemonAndConfigurationClientAreOneDaemon(clientFlag: String) throws {
    let daemon = process(42)
    let client = process(43, arguments: ["yabai", clientFlag, "config", "left_padding", "5"])
    let observed = try inspect([daemon, client])
    #expect(observed?.processID == daemon.processID)
    #expect(observed?.executablePath == executable)
    #expect(try inspect([client]) == nil)
  }

  @Test func twoDaemonsStillFailWithAClientPresent() {
    #expect(throws: (any Error).self) {
      try inspect([
        process(42), process(43, arguments: ["yabai", "--verbose"]),
        process(44, arguments: ["yabai", "-m", "query", "--windows"]),
      ])
    }
  }

  @Test(arguments: [
    ["yabai", "-c", "-m"], ["yabai", "--verbose", "-m"],
    ["yabai", "--message=message"], ["yabai", "-mquery"],
  ])
  func messageFlagOutsideActualClientModeDoesNotHideADaemon(arguments: [String]) {
    #expect(throws: (any Error).self) {
      try inspect([process(42), process(43, arguments: arguments)])
    }
  }

  @Test(arguments: [false, true])
  func foreignExecutableNeverDisappearsAsAClient(client: Bool) {
    let foreign = YabaiProcessSnapshot(
      processID: 43, executablePath: "/tmp/foreign/yabai",
      arguments: client ? ["yabai", "-m", "config", "layout", "bsp"] : ["yabai"])
    #expect(throws: (any Error).self) { try inspect([process(42), foreign]) }
  }

  @Test func unreadableOrChangedLiveIdentityFailsExplicitly() {
    #expect(throws: (any Error).self) { try inspect([process(42), process(43, arguments: [])]) }
    #expect(throws: (any Error).self) {
      try YabaiProcessEvidence.inspect(processIDs: [42], expectedExecutable: executable) { _ in
        process(43)
      }
    }
    #expect(throws: (any Error).self) {
      try YabaiProcessEvidence.inspect(processIDs: [42, 43], expectedExecutable: executable) {
        pid in
        if pid == 43 { throw CocoaError(.fileReadNoPermission) }
        return process(pid)
      }
    }
    #expect(throws: (any Error).self) {
      try YabaiProcessEvidence.inspect(processIDs: [0], expectedExecutable: executable) { _ in nil }
    }
  }

  @Test func definitivelyExitedCandidateIsNotALiveDaemon() throws {
    let observed = try YabaiProcessEvidence.inspect(
      processIDs: [42, 43], expectedExecutable: executable
    ) { pid in
      pid == 43 ? nil : process(pid)
    }
    #expect(observed?.processID == 42)
    #expect(
      try YabaiProcessEvidence.inspect(
        processIDs: [43], expectedExecutable: executable, snapshot: { _ in nil }) == nil)
  }

  @Test func liveObservationAuthenticatesIdentityAndArguments() throws {
    let observed = try #require(
      try YabaiProcessSnapshot.observe(ProcessInfo.processInfo.processIdentifier))
    #expect(observed.arguments == CommandLine.arguments)
    #expect(!observed.executablePath.isEmpty)
    #expect(try YabaiProcessSnapshot.observe(Int32.max) == nil)
  }

  private func process(_ pid: Int32, arguments: [String] = ["yabai"]) -> YabaiProcessSnapshot {
    .init(processID: pid, executablePath: executable, arguments: arguments)
  }

  private func inspect(_ processes: [YabaiProcessSnapshot]) throws -> (
    processID: Int32, executablePath: String
  )? {
    try YabaiProcessEvidence.inspect(
      processIDs: processes.map(\.processID), expectedExecutable: executable
    ) { pid in processes.first { $0.processID == pid } }
  }
}
