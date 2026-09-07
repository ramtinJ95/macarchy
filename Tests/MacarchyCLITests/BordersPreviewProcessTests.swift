import Darwin
import Foundation
import Testing

@testable import MacarchyCLI

struct BordersPreviewProcessTests {
  @Test(arguments: ["closed", "stalled", "hup", "int", "term"])
  func commandCleansUpBeforeOutputOrSignalExit(scenario: String) throws {
    let fixture = try PreviewSubprocess(scenario: scenario)
    defer { fixture.remove() }
    try fixture.launch()
    try requireEventually { FileManager.default.fileExists(atPath: fixture.ready.path) }
    let childID: Int32 = try #require(Int32(String(contentsOf: fixture.ready, encoding: .utf8)))
    fixture.childID = childID
    #expect(Darwin.kill(childID, 0) == 0)

    switch scenario {
    case "closed":
      try fixture.output.fileHandleForReading.close()
    case "stalled":
      // Fill the actual stdout pipe while the preview child is gated. Restore
      // blocking mode before releasing it; the real emitter must then block.
      let fd = fixture.output.fileHandleForWriting.fileDescriptor
      let flags = fcntl(fd, F_GETFL)
      try #require(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
      defer { _ = fcntl(fd, F_SETFL, flags) }
      let byte: [UInt8] = [0x78]
      while Darwin.write(fd, byte, 1) == 1 {}
      try #require(errno == EAGAIN)
    default:
      break
    }
    try fixture.output.fileHandleForWriting.close()
    try Data().write(to: fixture.go)

    let signal: Int32? = ["hup": SIGHUP, "int": SIGINT, "term": SIGTERM][scenario]
    if let signal {
      try #require(Darwin.kill(fixture.command.processIdentifier, signal) == 0)
    }
    try requireEventually { FileManager.default.fileExists(atPath: fixture.stopped.path) }
    try #require(Darwin.kill(childID, 0) == -1 && errno == ESRCH)
    fixture.childID = nil

    if scenario == "stalled" {
      // The child is gone even though lifecycle output cannot progress. The
      // original SIGTERM action must be restored so this writer can be killed.
      Thread.sleep(forTimeInterval: 0.1)
      #expect(fixture.command.isRunning)
      try #require(Darwin.kill(fixture.command.processIdentifier, SIGTERM) == 0)
    }
    try requireEventually { !fixture.command.isRunning }
    fixture.command.waitUntilExit()
    if scenario == "closed" || scenario == "stalled" {
      #expect(fixture.command.terminationReason == .uncaughtSignal)
      #expect(fixture.command.terminationStatus == (scenario == "closed" ? SIGPIPE : SIGTERM))
    } else {
      #expect(fixture.command.terminationReason == .exit)
      #expect(fixture.command.terminationStatus == 0)
      let output = String(
        decoding: fixture.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      #expect(output.contains("\"event\":\"planned\""))
      #expect(output.contains("\"event\":\"running\""))
      #expect(output.contains("\"event\":\"stopped\""))
    }
  }

  // Re-execute only this case through the active SwiftPM test helper.
  // No test-only product, public CLI flag, provider installation or runtime
  // environment override is added to Macarchy itself.
  @Test
  func subprocessEntry() throws {
    guard let directory = ProcessInfo.processInfo.environment["MACARCHY_BORDERS_TEST_DIRECTORY"]
    else { return }
    let root = URL(filePath: directory)
    let scenario = ProcessInfo.processInfo.environment["MACARCHY_BORDERS_TEST_SCENARIO"]!
    for number in [SIGPIPE, SIGINT, SIGTERM, SIGHUP] { Darwin.signal(number, SIG_DFL) }
    let palette = BordersPalette(generationID: "g-fixture", themeID: "fixture", accent: "#abcdef")
    let runner = BordersPreviewRunner(
      preflight: { palette },
      pointer: { "generations/\(palette.generationID)" },
      palette: { palette },
      start: { _ in
        let child = try BordersPreviewProcess.start(
          executableURL: URL(filePath: "/bin/sleep"), arguments: ["30"])
        do {
          try Data(String(child.processID).utf8).write(
            to: root.appending(path: "ready"), options: .atomic)
          try requireEventually {
            FileManager.default.fileExists(atPath: root.appending(path: "go").path)
          }
        } catch {
          child.stop()
          throw error
        }
        return BordersPreviewProcess(
          processID: child.processID, isRunning: child.isRunning,
          terminationStatus: child.terminationStatus,
          stop: {
            child.stop()
            // A failed marker write must fail the subprocess, not masquerade
            // as successful cleanup evidence in its parent.
            do { try Data().write(to: root.appending(path: "stopped")) } catch { exit(2) }
          }
        )
      },
      update: { _ in Issue.record("Unexpected palette update") },
      now: { ProcessInfo.processInfo.systemUptime },
      wait: { Thread.sleep(forTimeInterval: 0.025) }
    )
    let command = try Borders.Preview.parse([
      "--seconds", ["closed", "stalled"].contains(scenario) ? "1" : "30", "--json",
    ])
    try command.run(runner: runner)
  }
}

private func requireEventually(_ condition: () -> Bool) throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.01)
  }
  try #require(condition(), "Subprocess handshake or termination exceeded five seconds")
}

private final class PreviewSubprocess {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-borders-process-\(UUID())")
  let output = Pipe()
  let command = Process()
  var childID: Int32?
  var ready: URL { directory.appending(path: "ready") }
  var go: URL { directory.appending(path: "go") }
  var stopped: URL { directory.appending(path: "stopped") }

  init(scenario: String) throws {
    // The supported CLT runner loads a Mach-O test bundle through this helper,
    // not a directly executable xctest binary. Reuse its actual bundle path;
    // fail explicitly if the toolchain changes this launch contract.
    let arguments = CommandLine.arguments
    let bundleFlag = try #require(arguments.firstIndex(of: "--test-bundle-path"))
    try #require(arguments.indices.contains(bundleFlag + 1))
    command.executableURL = URL(filePath: CommandLine.arguments[0])
    command.arguments = [
      "--test-bundle-path", arguments[bundleFlag + 1],
      "--testing-library", "swift-testing", "--filter",
      "BordersPreviewProcessTests/subprocessEntry",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["MACARCHY_BORDERS_TEST_DIRECTORY"] = directory.path
    environment["MACARCHY_BORDERS_TEST_SCENARIO"] = scenario
    command.environment = environment
    command.standardInput = FileHandle.nullDevice
    // Pass the handle rather than Pipe so Foundation does not close the
    // parent's writer: the stalled-consumer case fills it deliberately.
    command.standardOutput = output.fileHandleForWriting
    command.standardError = FileHandle.standardError
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func launch() throws { try command.run() }

  func remove() {
    if command.isRunning {
      Darwin.kill(command.processIdentifier, SIGKILL)
      command.waitUntilExit()
    }
    // On an assertion failure, also reclaim the exact inert child. Its natural
    // 30-second bound is a final backstop, never a provider-wide kill by name.
    let unconfirmedChild =
      FileManager.default.fileExists(atPath: stopped.path)
      ? nil : (try? String(contentsOf: ready, encoding: .utf8)).flatMap(Int32.init)
    if let pid = childID ?? unconfirmedChild {
      Darwin.kill(pid, SIGKILL)
    }
    try? output.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? FileManager.default.removeItem(at: directory)
  }
}
