import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HomebrewInstallationExecutionTests {
  @Test
  func processCannotRunBeforeIdentityPublicationAndFailedPublicationKillsIt() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let output = fixture.root.appending(path: "started")
    let script = fixture.root.appending(path: "command.sh")
    try fixture.write("#!/bin/sh\nprintf started > \"$1\"\nexit 7\n", at: script)
    let request = ProcessRequest(
      executableURL: URL(filePath: "/bin/sh"), arguments: [script.path, output.path], timeout: 2)
    let group = Mutex<Int32?>(nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewPackageInstallProcess.run(request) { pid in
        group.withLock { $0 = pid }
        #expect(try HomebrewPackageInstallProcess.sessionExists(pid))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        throw SetupPackageAdoptionError("publication failed")
      }
    }
    #expect(try !HomebrewPackageInstallProcess.sessionExists(#require(group.withLock { $0 })))
    #expect(!FileManager.default.fileExists(atPath: output.path))
    let status = try HomebrewPackageInstallProcess.run(request) { pid in
      #expect(!FileManager.default.fileExists(atPath: output.path))
      group.withLock { $0 = pid }
    }
    #expect(status == 7)
    #expect(try String(contentsOf: output, encoding: .utf8) == "started")
    #expect(try !HomebrewPackageInstallProcess.sessionExists(#require(group.withLock { $0 })))
  }

  @Test
  func timeoutTerminatesTheNativeSession() throws {
    let group = Mutex<Int32?>(nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewPackageInstallProcess.run(
        .init(
          executableURL: URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
      ) { pid in group.withLock { $0 = pid } }
    }
    #expect(try !HomebrewPackageInstallProcess.sessionExists(#require(group.withLock { $0 })))
  }

  @Test(arguments: [false, true])
  func childrenInSeparateProcessGroupsCannotOutliveTheInstallation(earlyExit: Bool) throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let script = fixture.root.appending(path: "child-group.rb")
    let evidence = fixture.root.appending(path: "child.txt")
    try fixture.write(
      """
      child = Process.spawn("/bin/sleep", "10", pgroup: true)
      File.write(ARGV.fetch(0), [child, Process.getpgrp, Process.getpgid(child), Process.getsid(child)].join(" "))
      Process.wait(child) unless ARGV.fetch(1) == "exit"
      """, at: script)
    let session = Mutex<Int32?>(nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewPackageInstallProcess.run(
        .init(
          executableURL: URL(filePath: "/usr/bin/ruby"),
          arguments: [script.path, evidence.path, earlyExit ? "exit" : "wait"], timeout: 2)
      ) { pid in session.withLock { $0 = pid } }
    }
    let values = try String(contentsOf: evidence, encoding: .utf8).split(separator: " ").compactMap
    { Int32($0) }
    try #require(values.count == 4)
    #expect(values[1] != values[2])
    #expect(values[3] == session.withLock { $0 })
    #expect(try !HomebrewPackageInstallProcess.sessionExists(#require(session.withLock { $0 })))
    #expect(kill(values[0], 0) == -1 && errno == ESRCH)
  }

}
