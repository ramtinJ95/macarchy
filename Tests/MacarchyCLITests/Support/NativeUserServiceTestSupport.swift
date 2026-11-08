import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Scripted `launchctl` and native `--*-service` commands for one native user service.
final class NativeServiceCommandFake<Policy: NativeUserServicePolicy>: Sendable {
  struct State {
    var calls: [String] = []
    var running = false
    var loaded = false
    var failStart = false
    var failEnable = false
    var disabled = false
    var jobError = false
  }

  let state = Mutex(State())
  let home: URL
  private let processID: Int32
  private let versionOutput: String
  /// The owning journal's service change: nil without a pending transaction, `.some(nil)` when
  /// the pending transaction records no service change.
  private let pendingService: @Sendable () throws -> UserServiceChange??

  init(
    home: URL,
    processID: Int32,
    versionOutput: String,
    pendingService: @escaping @Sendable () throws -> UserServiceChange??
  ) {
    self.home = home
    self.processID = processID
    self.versionOutput = versionOutput
    self.pendingService = pendingService
  }

  var mutations: [String] { state.withLock { $0.calls } }
  var runner: ProcessRunner { ProcessRunner { try self.run($0) } }
  var propertyList: URL {
    NativeUserService<Policy>(runner: runner, observingProcess: { .notRunning })
      .propertyList(home)
  }

  func createRegistration(extra: [String: Bool] = [:]) throws {
    try FileManager.default.createDirectory(
      at: propertyList.deletingLastPathComponent(), withIntermediateDirectories: true)
    var plist: [String: Any] = [
      "Label": Policy.label,
      "ProgramArguments": [NativeUserService<Policy>.executable.path],
      "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
      "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false, "Crashed": true],
      "StandardOutPath": "/tmp/\(Policy.name)_\(NSUserName()).out.log",
      "StandardErrorPath": "/tmp/\(Policy.name)_\(NSUserName()).err.log",
      "ProcessType": "Interactive", "Nice": -20,
    ]
    for (key, value) in extra { plist[key] = value }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: propertyList)
  }

  private func run(_ request: ProcessRequest) throws -> ProcessResult {
    let argument = try #require(request.arguments.first)
    if request.executableURL.path == "/bin/launchctl" {
      if argument == "enable" {
        #expect(request.arguments == ["enable", "gui/\(getuid())/\(Policy.label)"])
        #expect(try pendingService() != nil)
        return state.withLock {
          $0.calls.append("enable")
          if $0.failEnable {
            return ProcessResult(terminationStatus: 5, output: "injected enable failure")
          }
          $0.disabled = false
          return ProcessResult(terminationStatus: 0, output: "")
        }
      }
      if argument == "print-disabled" {
        return ProcessResult(
          terminationStatus: 0,
          output: state.withLock {
            $0.disabled ? "\"\(Policy.label)\" => disabled" : "disabled services = {}"
          })
      }
      let snapshot = state.withLock { $0 }
      if snapshot.jobError { return ProcessResult(terminationStatus: 5, output: "I/O failure") }
      return ProcessResult(
        terminationStatus: snapshot.loaded ? 0 : 113,
        output: snapshot.loaded ? "path = \(propertyList.path)\npid = \(processID)" : "not found")
    }
    if argument == "--version" {
      return ProcessResult(terminationStatus: 0, output: versionOutput)
    }
    state.withLock { $0.calls.append(argument) }
    switch argument {
    case "--install-service":
      let pending = try #require(try pendingService())
      #expect(pending?.installationAttempted == true)
      try createRegistration()
    case "--start-service":
      let pending = try #require(try pendingService())
      #expect(pending?.expectedRegistration != nil)
      state.withLock {
        $0.loaded = true
        $0.running = !$0.failStart
      }
    case "--stop-service":
      state.withLock {
        $0.running = false
        $0.loaded = false
        if Policy.nativeStopDisablesJob { $0.disabled = true }
      }
    case "--uninstall-service":
      try FileManager.default.removeItem(at: propertyList)
    default: throw Policy.lifecycleError("unexpected native operation: \(argument)")
    }
    return ProcessResult(terminationStatus: 0, output: "")
  }
}
