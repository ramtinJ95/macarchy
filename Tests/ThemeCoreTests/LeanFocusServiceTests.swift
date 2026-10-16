import Darwin
import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct LeanFocusServiceTests {
  @Test func absentInspectionDoesNotMutateOrAuthorizeAnUnownedPlist() throws {
    try withTemporaryRoot(named: "lean-service") { root in
      let calls = Mutex<[String]>([])
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { request in
          calls.withLock { $0.append(request.arguments.first ?? "") }
          return ProcessResult(
            terminationStatus: request.executableURL.lastPathComponent == "pgrep" ? 1 : 113,
            output: "")
        })
      #expect(try service.inspect(configuration: nil) == .absent)
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root.appending(path: ".config/macarchy"),
        executableURL: URL(filePath: "/fixture/macarchy-focus-ring"))
      try FileManager.default.createDirectory(
        at: service.propertyListURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try configuration.propertyList().write(to: service.propertyListURL)
      #expect(throws: (any Error).self) { try service.inspect(configuration: nil) }
      #expect(
        try service.inspect(configuration: configuration)
          == LeanFocusServiceInspection(registered: true, loaded: false, processID: nil))
      #expect(calls.withLock { $0.allSatisfy { $0 == "print" || $0 == "-a" } })
    }
  }

  @Test(arguments: ["valid", "arguments", "path", "pid", "executable", "extra-process", "plist"])
  func loadedJobRequiresExactOwnedFileArgumentsAndProcess(condition: String) throws {
    try withTemporaryRoot(named: "lean-service") { root in
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root.appending(path: "state"),
        executableURL: URL(filePath: "/fixture/macarchy-focus-ring"))
      let plist = root.appending(path: "Library/LaunchAgents/\(LeanFocusService.label).plist")
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (condition == "plist" ? Data("foreign".utf8) : configuration.propertyList()).write(
        to: plist)
      let output = """
        path = \(condition == "path" ? "/foreign" : plist.path)
        program = \(configuration.executablePath)
        state = running
        pid = \(condition == "pid" ? 222 : 123)
        arguments = {
        \(configuration.arguments.joined(separator: "\n"))
        \(condition == "arguments" ? "--json\n" : "")}
        """
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { request in
          if request.executableURL.lastPathComponent == "pgrep" {
            #expect(request.arguments.contains("-a"))
          }
          return ProcessResult(
            terminationStatus: 0,
            output: request.executableURL.lastPathComponent == "pgrep"
              ? (condition == "extra-process" ? "123\n124\n" : "123\n") : output)
        },
        processPath: { _ in condition == "executable" ? "/foreign" : configuration.executablePath })
      if condition == "valid" {
        #expect(try service.inspect(configuration: configuration).processID == 123)
      } else {
        #expect(throws: (any Error).self) { try service.inspect(configuration: configuration) }
      }
    }
  }

  @Test func helperWithoutJobIsUnownedEvenIfItsExecutableMatches() throws {
    try withTemporaryRoot(named: "lean-service") { root in
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { request in
          ProcessResult(
            terminationStatus: request.executableURL.lastPathComponent == "pgrep" ? 0 : 113,
            output: request.executableURL.lastPathComponent == "pgrep" ? "123\n" : "")
        })
      #expect(throws: (any Error).self) { try service.inspect(configuration: nil) }
    }
  }

  @Test func foreignHomeCannotMutateAnyService() throws {
    try withTemporaryRoot(named: "lean-service") { root in
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { _ in
          Issue.record("a foreign HOME reached native control")
          return ProcessResult(terminationStatus: 0, output: "")
        })
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root, executableURL: URL(filePath: "/fixture/macarchy-focus-ring"))
      #expect(throws: (any Error).self) { try service.start(configuration) }
      #expect(throws: (any Error).self) { try service.stop(configuration) }
    }
  }

  @Test func runtimeRequiresCurrentPIDStartPaletteAndFreshRunloop() throws {
    let path = try #require(processExecutablePath(getpid()))
    let started = try #require(LeanFocusRuntime.processStart(getpid()))
    let configuration = LeanFocusServiceConfiguration(
      stateRoot: URL(filePath: "/fixture"), executableURL: URL(filePath: path))
    let palette = BordersPalette(generationID: "g-current", themeID: "theme", accent: "#abcdef")
    let record = LeanFocusRuntime(
      pid: getpid(), started: started, executablePath: path,
      generationID: palette.generationID, accent: palette.accent, updated: 10)
    #expect(
      record.matches(configuration: configuration, processID: getpid(), palette: palette, now: 11))
    #expect(
      !record.matches(configuration: configuration, processID: getpid(), palette: palette, now: 14))
    #expect(
      !record.matches(configuration: configuration, processID: getpid(), palette: palette, now: 9))
    #expect(
      !record.matches(
        configuration: configuration, processID: getpid() + 1, palette: palette, now: 11))
    #expect(
      !record.matches(
        configuration: configuration, processID: getpid(),
        palette: .init(generationID: "g-other", themeID: "theme", accent: palette.accent), now: 11))
    let reused = LeanFocusRuntime(
      pid: getpid(), started: started + 1, executablePath: path,
      generationID: palette.generationID, accent: palette.accent, updated: 10)
    #expect(
      !reused.matches(configuration: configuration, processID: getpid(), palette: palette, now: 11))
  }
}
