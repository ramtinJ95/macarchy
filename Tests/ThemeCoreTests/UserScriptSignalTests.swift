import Darwin
import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct UserScriptSignalTests {
  // Concurrent helpers expose the worker-thread re-raise failure that isolated runs miss.
  @Test(arguments: [SIGINT, SIGTERM, SIGHUP], 0..<8)
  func interruptionStopsTheScriptGroupBeforeTheCallerExits(signal: Int32, repetition: Int) throws {
    let directory = try makeTrustedScriptDirectory()
    defer { removeTemporaryRoot(directory) }
    let ready = directory.appending(path: "ready")
    let script = directory.appending(path: "script")
    try """
    #!/bin/sh
    /bin/sleep 30 &
    printf '%s %s' $$ $! > "$(dirname "$0")/ready"
    wait

    """.write(to: script, atomically: false, encoding: .utf8)
    chmod(script.path, 0o700)
    let command = Process()
    // Reuse the active SwiftPM helper, as BordersPreviewProcessTests does.
    let arguments = CommandLine.arguments
    let flag = try #require(arguments.firstIndex(of: "--test-bundle-path"))
    try #require(arguments.indices.contains(flag + 1))
    command.executableURL = URL(filePath: arguments[0])
    command.arguments = [
      "--test-bundle-path", arguments[flag + 1], "--testing-library", "swift-testing",
      "--filter", "UserScriptSignalTests/subprocessEntry",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["MACARCHY_SCRIPT_SIGNAL_TEST"] = script.path
    command.environment = environment
    command.standardInput = FileHandle.nullDevice
    command.standardOutput = FileHandle.nullDevice
    command.standardError = FileHandle.standardError
    var children: [pid_t] = []
    defer {
      if command.isRunning {
        kill(command.processIdentifier, SIGKILL)
        command.waitUntilExit()
      }
      for child in children { kill(child, SIGKILL) }
    }
    try command.run()
    try eventually {
      guard let text = try? String(contentsOf: ready, encoding: .utf8) else { return false }
      children = text.split(separator: " ").compactMap { pid_t($0) }
      return children.count == 2
    }
    try #require(kill(command.processIdentifier, signal) == 0)
    try eventually { !command.isRunning }
    command.waitUntilExit()
    #expect(command.terminationReason == .uncaughtSignal)
    #expect(command.terminationStatus == signal)
    try eventually { children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    children = []
  }

  @Test func subprocessEntry() throws {
    guard let path = ProcessInfo.processInfo.environment["MACARCHY_SCRIPT_SIGNAL_TEST"] else {
      return
    }
    var blocked: sigset_t = 0
    sigemptyset(&blocked)
    for number in [SIGINT, SIGTERM, SIGHUP] {
      Darwin.signal(number, SIG_DFL)
      sigaddset(&blocked, number)
    }
    // The original process-directed signal can reach the source on another thread.
    // The final default action must also terminate when this worker starts blocked.
    try #require(pthread_sigmask(SIG_BLOCK, &blocked, nil) == 0)
    let outcome = UserScriptRunner().run(URL(filePath: path), environment: [:])
    Issue.record("Signal should have ended this subprocess after cleaning up: \(outcome)")
  }
}

private func eventually(_ condition: () -> Bool) throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition(), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
  try #require(condition(), "Script subprocess exceeded the five-second handshake/cleanup bound")
}
