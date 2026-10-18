import ArgumentParser
import Darwin
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

/// Every launch agent Macarchy owns, built for a temporary home and state folder.
enum OwnedAgentKind: CaseIterable, Sendable {
  case clipboardAutoClear
  case saverIdle

  static let executable = URL(filePath: "/opt/homebrew/bin/macarchy")

  func agent(home: URL, stateRoot: URL, runner: ProcessRunner) -> OwnedLaunchAgent {
    switch self {
    case .clipboardAutoClear:
      .clipboardAutoClear(
        home: home, stateRoot: stateRoot, executable: Self.executable, userID: 501,
        runner: runner)
    case .saverIdle:
      .saverIdle(
        home: home, stateRoot: stateRoot, executable: Self.executable, userID: 501,
        runner: runner)
    }
  }
}

/// A temporary folder stands in for the home folder and a scripted runner for launchctl. No test
/// reaches launchd, the real ~/Library, a symbolic link or a special file.
struct OwnedLaunchAgentTests {
  @Test func theClipboardPlistRunsTheHiddenCommandHourlyInTheLoginSession() throws {
    try withAgent(.clipboardAutoClear) { agent, _, state throws in
      let plist = try #require(
        try PropertyListSerialization.propertyList(from: agent.propertyList(), format: nil)
          as? [String: Any])
      let keys: Set<String> = [
        "Label", "ProgramArguments", "StartInterval", "RunAtLoad", "AbandonProcessGroup",
        "LimitLoadToSessionType", "ProcessType", "StandardOutPath", "StandardErrorPath",
      ]
      #expect(Set(plist.keys) == keys)
      #expect(plist["Label"] as? String == "io.github.ramtinj95.macarchy.clipboard-auto-clear")
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

  @Test func theIdlePlistKeepsTheObserverRunningInTheLoginSessionUntilItExitsCleanly() throws {
    try withAgent(.saverIdle) { agent, _, state throws in
      let plist = try #require(
        try PropertyListSerialization.propertyList(from: agent.propertyList(), format: nil)
          as? [String: Any])
      let keys: Set<String> = [
        "Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "LimitLoadToSessionType",
        "ProcessType", "StandardOutPath", "StandardErrorPath",
      ]
      #expect(Set(plist.keys) == keys)
      #expect(plist["Label"] as? String == "io.github.ramtinj95.macarchy.saver-idle")
      let arguments = try #require(plist["ProgramArguments"] as? [String])
      let expected = ["/opt/homebrew/bin/macarchy", "saver", "_idle", "--state-root", state.path]
      #expect(arguments == expected)
      #expect(plist["RunAtLoad"] as? Bool == true)
      let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
      #expect(keepAlive.count == 1)
      #expect(keepAlive["SuccessfulExit"] as? Bool == false)
      #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
      #expect(plist["ProcessType"] as? String == "Interactive")
      let logs = state.appending(path: "run")
      #expect(
        plist["StandardOutPath"] as? String == logs.appending(path: "saver-idle.stdout.log").path)
      #expect(
        plist["StandardErrorPath"] as? String == logs.appending(path: "saver-idle.stderr.log").path)

      let command = try Macarchy.parseAsRoot(Array(arguments.dropFirst()))
      let observe = try #require(command as? SaverCommand.Observe)
      #expect(observe.stateRoot == state.path)
      #expect(observe.alert == nil)
    }
  }

  /// Installs from earlier releases stay owned only while these bytes never change.
  @Test func theClipboardPlistKeepsTheBytesEarlierReleasesInstalled() throws {
    try withAgent(.clipboardAutoClear) { agent, _, state throws in
      let root = state.path
      let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>AbandonProcessGroup</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>io.github.ramtinj95.macarchy.clipboard-auto-clear</string>
        \t<key>LimitLoadToSessionType</key>
        \t<string>Aqua</string>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/opt/homebrew/bin/macarchy</string>
        \t\t<string>clipboard</string>
        \t\t<string>_auto-clear</string>
        \t\t<string>--state-root</string>
        \t\t<string>\(root)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StandardErrorPath</key>
        \t<string>\(root)/run/clipboard-auto-clear.stderr.log</string>
        \t<key>StandardOutPath</key>
        \t<string>\(root)/run/clipboard-auto-clear.stdout.log</string>
        \t<key>StartInterval</key>
        \t<integer>3600</integer>
        </dict>
        </plist>

        """
      #expect(String(decoding: try agent.propertyList(), as: UTF8.self) == expected)
    }
  }

  @Test(arguments: OwnedAgentKind.allCases)
  func installWritesThePlistOnceAndAdoptsAnIdenticalOne(kind: OwnedAgentKind) throws {
    try withAgent(kind) { agent, launchd, _ throws in
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

  @Test(
    arguments: OwnedAgentKind.allCases, ["different content", "another state root", "a directory"])
  func anyOtherFileIsAConflictMacarchyNeverReplacesOrRemoves(
    kind: OwnedAgentKind, conflict: String
  ) throws {
    try withAgent(kind) { agent, launchd, state throws in
      let agents = agent.plistURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      switch conflict {
      case "a directory":
        try FileManager.default.createDirectory(
          at: agent.plistURL, withIntermediateDirectories: false)
      case "another state root":
        let other = kind.agent(
          home: agent.home, stateRoot: state.appending(path: "other"), runner: agent.runner)
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
        let error = #expect(throws: OwnedLaunchAgentError.self) { try operation() }
        #expect(error?.description.contains("is not the launch agent this Macarchy") == true)
      }
      #expect((try? Data(contentsOf: agent.plistURL)) == before)
      #expect(FileManager.default.fileExists(atPath: agent.plistURL.path))
      #expect(launchd.calls.isEmpty)
    }
  }

  @Test(arguments: OwnedAgentKind.allCases)
  func removeDeletesOnlyTheOwnedPlist(kind: OwnedAgentKind) throws {
    try withAgent(kind) { agent, _, _ throws in
      #expect(try agent.remove() == false)
      #expect(try agent.install())
      #expect(try agent.remove())
      #expect(try agent.file() == .absent)
      #expect(
        FileManager.default.fileExists(atPath: agent.plistURL.deletingLastPathComponent().path))
      #expect(try agent.remove() == false)
    }
  }

  @Test(arguments: OwnedAgentKind.allCases)
  func loadAndUnloadChangeOnlyWhatLaunchdLacks(kind: OwnedAgentKind) throws {
    try withAgent(kind) { agent, launchd, _ throws in
      let job = "gui/501/\(agent.label)"
      #expect(try agent.isLoaded() == false)
      #expect(try agent.load())
      #expect(try agent.isLoaded())
      #expect(try agent.load() == false)
      #expect(try agent.unload())
      #expect(try agent.unload() == false)
      let expected: [[String]] = [
        ["print", job],
        ["print", job], ["bootstrap", "gui/501", agent.plistURL.path],
        ["print", job],
        ["print", job],
        ["print", job], ["bootout", job],
        ["print", job],
      ]
      #expect(launchd.calls == expected)
      let requests = launchd.requests
      #expect(requests.allSatisfy { $0.executableURL.path == "/bin/launchctl" })
      #expect(requests.allSatisfy { $0.timeout == 10 })
    }
  }

  @Test(arguments: OwnedAgentKind.allCases)
  func launchctlFailuresAreReported(kind: OwnedAgentKind) throws {
    try withAgent(kind) { agent, launchd, _ throws in
      launchd.state.withLock { $0.bootstrapStatus = 5 }
      let load = #expect(throws: OwnedLaunchAgentError.self) { try agent.load() }
      #expect(load?.description.contains("Bootstrap failed: 5") == true)

      launchd.state.withLock {
        $0.loaded = true
        $0.bootoutStatus = 5
      }
      let unload = #expect(throws: OwnedLaunchAgentError.self) { try agent.unload() }
      #expect(unload?.description.contains("Boot-out failed: 5") == true)

      launchd.state.withLock { $0.printStatus = 64 }
      #expect(throws: OwnedLaunchAgentError.self) { try agent.isLoaded() }
    }
  }

  @Test(arguments: OwnedAgentKind.allCases)
  func kickstartRunsAStoppedLoadedJobWithoutRestartingARunningOne(kind: OwnedAgentKind) throws {
    try withAgent(kind) { agent, launchd, _ throws in
      let unloaded = #expect(throws: OwnedLaunchAgentError.self) { try agent.kickstart() }
      #expect(unloaded?.description.contains("Could not find service") == true)

      launchd.state.withLock { $0.loaded = true }
      try agent.kickstart()
      #expect(launchd.running)
      try agent.kickstart()
      #expect(launchd.running)
      let kickstart = ["kickstart", "gui/501/\(agent.label)"]
      #expect(launchd.calls.count == 3)
      #expect(launchd.calls.allSatisfy { $0 == kickstart })
      #expect(launchd.requests.allSatisfy { $0.timeout == 35 })
    }
  }

  private func withAgent(
    _ kind: OwnedAgentKind, _ body: (OwnedLaunchAgent, LaunchdFake, URL) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-launch-agent-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: "Library"), withIntermediateDirectories: true)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let launchd = LaunchdFake()
    try body(kind.agent(home: home, stateRoot: state, runner: launchd.runner), launchd, state)
  }
}

/// launchctl for one job: `print` answers from `loaded`, bootstrap and bootout change it, and
/// kickstart runs a loaded job.
final class LaunchdFake: Sendable {
  struct State {
    var loaded = false
    /// Whether the job's process runs. A job whose process exited cleanly stays loaded.
    var running = false
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
  var running: Bool { state.withLock { $0.running } }

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
          state.running = true
          return ProcessResult(terminationStatus: 0, output: "")
        case "bootout":
          guard state.bootoutStatus == 0 else {
            return ProcessResult(
              terminationStatus: state.bootoutStatus,
              output: "Boot-out failed: 5: Input/output error")
          }
          state.loaded = false
          state.running = false
          return ProcessResult(terminationStatus: 0, output: "")
        case "kickstart":
          guard state.loaded else {
            return ProcessResult(terminationStatus: 113, output: "Could not find service")
          }
          state.running = true
          return ProcessResult(terminationStatus: 0, output: "")
        default:
          return ProcessResult(terminationStatus: 64, output: "unexpected launchctl call")
        }
      }
    }
  }
}
