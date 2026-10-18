import ArgumentParser
import Darwin
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

/// A temporary folder stands in for the home folder and a scripted runner for launchctl. No test
/// reaches launchd, the real ~/Library, a symbolic link or a special file.
struct ClipboardAutoClearAgentTests {
  private static let label = "io.github.ramtinj95.macarchy.clipboard-auto-clear"
  private static let job = "gui/501/\(label)"

  @Test func thePlistRunsTheHiddenCommandHourlyInTheLoginSession() throws {
    try withAgent { agent, _, state throws in
      let plist = try #require(
        try PropertyListSerialization.propertyList(from: agent.propertyList(), format: nil)
          as? [String: Any])
      let keys: Set<String> = [
        "Label", "ProgramArguments", "StartInterval", "RunAtLoad", "AbandonProcessGroup",
        "LimitLoadToSessionType", "ProcessType", "StandardOutPath", "StandardErrorPath",
      ]
      #expect(Set(plist.keys) == keys)
      #expect(plist["Label"] as? String == Self.label)
      let arguments = try #require(plist["ProgramArguments"] as? [String])
      let expected = [
        "/opt/homebrew/bin/macarchy", "clipboard", "_auto-clear", "--state-root", state.path,
      ]
      #expect(arguments == expected)
      #expect(plist["StartInterval"] as? Int == 3_600)
      #expect(plist["RunAtLoad"] as? Bool == true)
      #expect(plist["AbandonProcessGroup"] as? Bool == true)
      #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
      #expect(plist["ProcessType"] as? String == "Background")
      let logs = state.appending(path: "run")
      #expect(
        plist["StandardOutPath"] as? String
          == logs.appending(path: "clipboard-auto-clear.stdout.log").path)
      #expect(
        plist["StandardErrorPath"] as? String
          == logs.appending(path: "clipboard-auto-clear.stderr.log").path)

      let command = try Macarchy.parseAsRoot(Array(arguments.dropFirst()))
      let run = try #require(command as? ClipboardCommand.RunAutoClear)
      #expect(run.options.stateRoot == state.path)
      #expect(run.alert == nil)
    }
  }

  @Test func installWritesThePlistOnceAndAdoptsAnIdenticalOne() throws {
    try withAgent { agent, launchd, _ throws in
      #expect(try agent.file() == .absent)
      #expect(try agent.install())
      #expect(try agent.file() == .owned)
      #expect(try Data(contentsOf: agent.plistURL) == agent.propertyList())
      let attributes = try FileManager.default.attributesOfItem(atPath: agent.plistURL.path)
      #expect(attributes[.posixPermissions] as? Int == 0o600)
      #expect(try agent.install() == false)

      try FileManager.default.removeItem(at: agent.plistURL)
      try agent.propertyList().write(to: agent.plistURL)
      #expect(try agent.file() == .owned)
      #expect(try agent.install() == false)
      let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: agent.plistURL.deletingLastPathComponent().path)
      #expect(leftovers == [agent.plistURL.lastPathComponent])
      #expect(launchd.calls.isEmpty)
    }
  }

  @Test(arguments: ["different content", "another state root", "a directory"])
  func anyOtherFileIsAConflictMacarchyNeverReplacesOrRemoves(kind: String) throws {
    try withAgent { agent, launchd, state throws in
      let agents = agent.plistURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      switch kind {
      case "a directory":
        try FileManager.default.createDirectory(
          at: agent.plistURL, withIntermediateDirectories: false)
      case "another state root":
        let other = ClipboardAutoClearAgent(
          home: agent.home, stateRoot: state.appending(path: "other"),
          executable: agent.executable, userID: agent.userID, runner: agent.runner)
        try other.propertyList().write(to: agent.plistURL)
      default:
        try Data("custom".utf8).write(to: agent.plistURL)
      }
      let before = try? Data(contentsOf: agent.plistURL)

      #expect(try agent.file() == .conflict(agent.plistURL))
      let operations: [() throws -> Void] = [
        { _ = try agent.install() }, { _ = try agent.remove() },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description.contains("is not the launch agent this Macarchy") == true)
      }
      #expect((try? Data(contentsOf: agent.plistURL)) == before)
      #expect(FileManager.default.fileExists(atPath: agent.plistURL.path))
      #expect(launchd.calls.isEmpty)
    }
  }

  @Test func removeDeletesOnlyTheOwnedPlist() throws {
    try withAgent { agent, _, _ throws in
      #expect(try agent.remove() == false)
      #expect(try agent.install())
      #expect(try agent.remove())
      #expect(try agent.file() == .absent)
      #expect(
        FileManager.default.fileExists(atPath: agent.plistURL.deletingLastPathComponent().path))
      #expect(try agent.remove() == false)
    }
  }

  @Test func loadAndUnloadChangeOnlyWhatLaunchdLacks() throws {
    try withAgent { agent, launchd, _ throws in
      #expect(try agent.isLoaded() == false)
      #expect(try agent.load())
      #expect(try agent.isLoaded())
      #expect(try agent.load() == false)
      #expect(try agent.unload())
      #expect(try agent.unload() == false)
      let expected: [[String]] = [
        ["print", Self.job],
        ["print", Self.job], ["bootstrap", "gui/501", agent.plistURL.path],
        ["print", Self.job],
        ["print", Self.job],
        ["print", Self.job], ["bootout", Self.job],
        ["print", Self.job],
      ]
      #expect(launchd.calls == expected)
      let requests = launchd.requests
      #expect(requests.allSatisfy { $0.executableURL.path == "/bin/launchctl" })
      #expect(requests.allSatisfy { $0.timeout == 10 })
    }
  }

  @Test func launchctlFailuresAreReported() throws {
    try withAgent { agent, launchd, _ throws in
      launchd.state.withLock { $0.bootstrapStatus = 5 }
      let load = #expect(throws: ClipboardHistoryError.self) { try agent.load() }
      #expect(load?.description.contains("Bootstrap failed: 5") == true)

      launchd.state.withLock {
        $0.loaded = true
        $0.bootoutStatus = 5
      }
      let unload = #expect(throws: ClipboardHistoryError.self) { try agent.unload() }
      #expect(unload?.description.contains("Boot-out failed: 5") == true)

      launchd.state.withLock { $0.printStatus = 64 }
      #expect(throws: ClipboardHistoryError.self) { try agent.isLoaded() }
    }
  }

  private func withAgent(
    _ body: (ClipboardAutoClearAgent, ClipboardLaunchdFake, URL) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-auto-clear-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: "Library"), withIntermediateDirectories: true)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let launchd = ClipboardLaunchdFake()
    let agent = ClipboardAutoClearAgent(
      home: home, stateRoot: state, executable: URL(filePath: "/opt/homebrew/bin/macarchy"),
      userID: 501, runner: launchd.runner)
    try body(agent, launchd, state)
  }
}

/// launchctl for one job: `print` answers from `loaded`, and bootstrap and bootout change it.
final class ClipboardLaunchdFake: Sendable {
  struct State {
    var loaded = false
    /// Overrides the status `print` answers with.
    var printStatus: Int32?
    var bootstrapStatus: Int32 = 0
    var bootoutStatus: Int32 = 0
    var requests: [ProcessRequest] = []
  }

  let state = Mutex(State())

  var requests: [ProcessRequest] { state.withLock { $0.requests } }
  var calls: [[String]] { requests.map(\.arguments) }
  var loaded: Bool { state.withLock { $0.loaded } }

  var runner: ProcessRunner {
    ProcessRunner { request in
      self.state.withLock { state in
        state.requests.append(request)
        switch request.arguments.first {
        case "print":
          let status = state.printStatus ?? (state.loaded ? 0 : 113)
          return ProcessResult(terminationStatus: status, output: "")
        case "bootstrap":
          guard state.bootstrapStatus == 0 else {
            return ProcessResult(
              terminationStatus: state.bootstrapStatus,
              output: "Bootstrap failed: 5: Input/output error")
          }
          state.loaded = true
          return ProcessResult(terminationStatus: 0, output: "")
        case "bootout":
          guard state.bootoutStatus == 0 else {
            return ProcessResult(
              terminationStatus: state.bootoutStatus,
              output: "Boot-out failed: 5: Input/output error")
          }
          state.loaded = false
          return ProcessResult(terminationStatus: 0, output: "")
        default:
          return ProcessResult(terminationStatus: 64, output: "unexpected launchctl call")
        }
      }
    }
  }
}
