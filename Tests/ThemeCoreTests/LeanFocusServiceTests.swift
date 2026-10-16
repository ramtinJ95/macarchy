import Darwin
import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct LeanFocusServiceTests {
  @Test func olderRuntimeRecordWithPublicationTimeStillDecodes() throws {
    let bytes = Data(
      """
      {"label":"io.github.ramtinj95.macarchy.focus-ring","stateRoot":"/fixture",
       "pid":123,"started":1000,"executablePath":"/fixture/macarchy-focus-ring",
       "generationID":"g-old","accent":"#abcdef","updated":10}
      """.utf8)
    let record = try JSONDecoder().decode(LeanFocusRuntime.self, from: bytes)
    #expect(record.generationID == "g-old" && record.started == 1000 && record.pid == 123)
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    #expect(encoded["updated"] == nil)
  }

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
      let executable = root.appending(path: "macarchy-focus-ring")
      try Data("helper fixture".utf8).write(to: executable)
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root.appending(path: "state"),
        executableURL: executable)
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
        #expect(try service.inspect(configuration: configuration).executableIsCurrent)
      } else if condition == "executable" {
        // The exact owned label launched this PID: an old/missing executable
        // is actionable drift. Unowned/extra/mismatched PIDs still refuse.
        #expect(try !service.inspect(configuration: configuration).executableIsCurrent)
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

  @Test func runtimeRequiresOwnedLabelRootCurrentPIDStartAndPaletteWithoutHeartbeat() throws {
    let path = try #require(processExecutablePath(getpid()))
    let started = try #require(LeanFocusRuntime.processStart(getpid()))
    let configuration = LeanFocusServiceConfiguration(
      stateRoot: URL(filePath: "/fixture"), executableURL: URL(filePath: path))
    let palette = BordersPalette(generationID: "g-current", themeID: "theme", accent: "#abcdef")
    let record = LeanFocusRuntime(
      label: LeanFocusService.label, stateRoot: configuration.stateRoot,
      pid: getpid(), started: started,
      executablePath: try #require(LeanFocusServiceConfiguration.physicalPath(path)),
      generationID: palette.generationID, accent: palette.accent)
    #expect(
      record.matches(configuration: configuration, processID: getpid(), palette: palette))
    #expect(
      !record.matches(
        configuration: configuration, processID: getpid() + 1, palette: palette))
    #expect(
      !record.matches(
        configuration: configuration, processID: getpid(),
        palette: .init(generationID: "g-other", themeID: "theme", accent: palette.accent)))
    let reused = LeanFocusRuntime(
      label: LeanFocusService.label, stateRoot: configuration.stateRoot,
      pid: getpid(), started: started + 1, executablePath: path,
      generationID: palette.generationID, accent: palette.accent)
    #expect(
      !reused.matches(configuration: configuration, processID: getpid(), palette: palette))
    let otherRoot = LeanFocusServiceConfiguration(
      stateRoot: URL(filePath: "/other"), executableURL: URL(filePath: path))
    #expect(!record.matches(configuration: otherRoot, processID: getpid(), palette: palette))
  }

  @Test func stablePathSurvivesUpgradeAndRestartsOnlyTheExactOwnedLabel() throws {
    #expect(
      LeanFocusServiceConfiguration(
        stateRoot: URL(filePath: "/state"),
        executableURL: URL(filePath: "/opt/homebrew/Cellar/macarchy/0.12.5/bin/macarchy-focus-ring")
      ).executablePath == "/opt/homebrew/bin/macarchy-focus-ring")
    try withTemporaryRoot(named: "lean-upgrade") { root in
      let old = root.appending(path: "v1/macarchy-focus-ring")
      let next = root.appending(path: "v2/macarchy-focus-ring")
      for url in [old, next] {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }
      let stable = root.appending(path: "macarchy-focus-ring")
      try FileManager.default.createSymbolicLink(at: stable, withDestinationURL: old)
      let configuration = LeanFocusServiceConfiguration(stateRoot: root, executableURL: stable)
      #expect(configuration.executablePath == stable.standardizedFileURL.path)
      let plist = root.appending(path: "Library/LaunchAgents/\(LeanFocusService.label).plist")
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      let bytes = try configuration.propertyList()
      try bytes.write(to: plist)
      try FileManager.default.removeItem(at: stable)
      try FileManager.default.createSymbolicLink(at: stable, withDestinationURL: next)
      let state = Mutex((restarted: false, calls: [[String]]()))
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { request in
          state.withLock { value in
            value.calls.append(request.arguments)
            if request.arguments.first == "kickstart" {
              #expect(request.timeout == 35)
              #expect(
                request.arguments == [
                  "kickstart", "-k", "gui/\(getuid())/\(LeanFocusService.label)",
                ])
              value.restarted = true
              return ProcessResult(terminationStatus: 0, output: "")
            }
            let pid = value.restarted ? 124 : 123
            if request.executableURL.lastPathComponent == "pgrep" {
              return ProcessResult(terminationStatus: 0, output: "\(pid)\n")
            }
            return ProcessResult(
              terminationStatus: 0,
              output: """
                path = \(plist.path)
                program = \(configuration.executablePath)
                state = running
                pid = \(pid)
                arguments = {
                \(configuration.arguments.joined(separator: "\n"))
                }
                """)
          }
        },
        processPath: { _ in state.withLock { $0.restarted ? next.path : old.path } },
        wait: {}, currentHomeDirectory: root)
      #expect(try !service.inspect(configuration: configuration).executableIsCurrent)
      try service.start(configuration)
      #expect(try service.inspect(configuration: configuration).processID == 124)
      #expect(try service.inspect(configuration: configuration).executableIsCurrent)
      #expect(try Data(contentsOf: plist) == bytes)
      #expect(state.withLock { $0.calls.filter { $0.first == "kickstart" }.count } == 1)
      #expect(
        LeanFocusServiceConfiguration.physicalPath(stable.path)
          == LeanFocusServiceConfiguration.physicalPath(next.path))
    }
  }

  @Test func ownedRuntimeSurvivesExecutableChangeButNotLabelOrRootChange() throws {
    try withTemporaryRoot(named: "lean-runtime") { root in
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root, executableURL: URL(filePath: try #require(processExecutablePath(getpid())))
      )
      try FileManager.default.createDirectory(
        at: configuration.runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let stale = LeanFocusRuntime(
        label: LeanFocusService.label, stateRoot: configuration.stateRoot,
        pid: 123, started: 1, executablePath: "/old/macarchy-focus-ring",
        generationID: "old", accent: "#abcdef")
      try JSONEncoder().encode(stale).write(to: configuration.runtimeURL)
      try LeanFocusRuntime.validateIfPresent(configuration: configuration)
      try LeanFocusRuntime.publish(
        configuration: configuration, generationID: "new", accent: "#123456")
      #expect(try LeanFocusRuntime.read(configuration: configuration).pid == getpid())
      for (label, stateRoot) in [
        ("foreign", configuration.stateRoot), (LeanFocusService.label, "/foreign"),
      ] {
        let foreign = LeanFocusRuntime(
          label: label, stateRoot: stateRoot, pid: 123, started: 1,
          executablePath: "/old/macarchy-focus-ring", generationID: "old", accent: "#abcdef")
        let bytes = try JSONEncoder().encode(foreign)
        try bytes.write(to: configuration.runtimeURL)
        #expect(throws: (any Error).self) {
          try LeanFocusRuntime.publish(
            configuration: configuration, generationID: "new", accent: "#123456")
        }
        #expect(throws: (any Error).self) {
          try LeanFocusRuntime.remove(configuration: configuration)
        }
        #expect(try Data(contentsOf: configuration.runtimeURL) == bytes)
      }
    }
  }

  @Test func unregisteredOwnedStopRemovesItsLeftoverRuntimeRecord() throws {
    try withTemporaryRoot(named: "lean-stopped") { root in
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root, executableURL: root.appending(path: "macarchy-focus-ring"))
      try FileManager.default.createDirectory(
        at: configuration.runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let stale = LeanFocusRuntime(
        label: LeanFocusService.label, stateRoot: configuration.stateRoot,
        pid: 123, started: 1, executablePath: "/removed/macarchy-focus-ring",
        generationID: "old", accent: "#abcdef")
      try JSONEncoder().encode(stale).write(to: configuration.runtimeURL)
      let service = LeanFocusService(
        homeDirectory: root,
        runner: ProcessRunner { request in
          #expect(request.arguments.first == "print" || request.arguments.first == "-a")
          return ProcessResult(
            terminationStatus: request.executableURL.lastPathComponent == "pgrep" ? 1 : 113,
            output: "")
        }, currentHomeDirectory: root)
      try service.stop(configuration)
      #expect(!FileManager.default.fileExists(atPath: configuration.runtimeURL.path))
    }
  }

  @Test func managedLogsAreBoundedAndDeterministicRefusalsDoNotLoop() throws {
    try withTemporaryRoot(named: "lean-logs") { root in
      let configuration = LeanFocusServiceConfiguration(
        stateRoot: root, executableURL: root.appending(path: "macarchy-focus-ring"))
      let plist = try #require(
        PropertyListSerialization.propertyList(from: configuration.propertyList(), format: nil)
          as? [String: Any])
      #expect(plist["KeepAlive"] as? [String: Bool] == ["Crashed": true])
      try FileManager.default.createDirectory(
        at: root.appending(path: "environment"), withIntermediateDirectories: true)
      let out = root.appending(path: "environment/lean-focus.stdout.log")
      let err = root.appending(path: "environment/lean-focus.stderr.log")
      for url in [out, err] { try Data(repeating: 65, count: 8192).write(to: url) }
      let stdout = open(out.path, O_WRONLY | O_NOFOLLOW)
      let stderr = open(err.path, O_WRONLY | O_NOFOLLOW)
      defer {
        close(stdout)
        close(stderr)
      }
      #expect(stdout >= 0 && stderr >= 0)
      try configuration.resetLogDescriptors(stdout: stdout, stderr: stderr)
      #expect(try Data(contentsOf: out).isEmpty && Data(contentsOf: err).isEmpty)
      #expect(throws: (any Error).self) {
        try configuration.resetLogDescriptors(stdout: stderr, stderr: stdout)
      }
    }
  }
}
