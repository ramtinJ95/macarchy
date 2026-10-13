import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SkhdUserServiceTests {
  @Test func firstInstallPlansStartsVerifiesAndTearsDown() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.home.appending(path: ".config/skhd"))
    let native = SkhdNativeFixture(fixture: fixture)
    let runner = KeybindingsApplyCommandRunner(lifecycle: native.lifecycle)
    let preview = try runner.preview(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: false,
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home, json: true)
    #expect(preview.succeeded)
    #expect(preview.output.contains("register the user service"))
    #expect(native.mutations.isEmpty)
    let applied = try fixture.execute(runner: runner, json: true)
    #expect(applied.succeeded, "\(applied.output)")
    #expect(native.mutations == ["--install-service", "--start-service"])
    let ownership = try #require(try SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot).read())
    #expect(ownership.original.registration == nil)
    #expect(!ownership.original.running)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(try fixture.execute(runner: runner, json: true).output.contains("no_change"))
    let teardown = try runner.teardownLocked(
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home, dryRun: false)
    #expect(teardown.lifecycle == .stop)
    #expect(
      native.mutations == [
        "--install-service", "--start-service", "--stop-service", "--uninstall-service",
      ])
    #expect(try native.service.registration(home: fixture.home) == nil)
    #expect(try SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test func failedFirstStartRestoresAbsenceWithoutRestarting() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    native.state.withLock { $0.failStart = true }
    let result = try fixture.execute(
      runner: KeybindingsApplyCommandRunner(lifecycle: native.lifecycle), json: true)
    #expect(!result.succeeded)
    #expect(result.output.contains("was rolled back"), "\(result.output)")
    #expect(
      native.mutations == [
        "--install-service", "--start-service", "--stop-service", "--uninstall-service",
      ])
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(try native.service.registration(home: fixture.home) == nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing)
  }

  @Test(arguments: [false, true])
  func deferredFirstApplyCanRollbackOrCommit(commit: Bool) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    let runner = KeybindingsApplyCommandRunner(lifecycle: native.lifecycle)
    _ = try runner.applyIntegrationLocked(
      resourcesRoot: fixture.resources, profileURL: fixture.profile, profileRequired: false,
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home, adopt: nil, deferFinalization: true
    )
    let pending = try #require(
      try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read())
    #expect(pending.schemaVersion == 2)
    #expect(pending.service?.installed != nil)
    #expect(try SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot).read() == nil)
    if commit {
      try runner.commitDeferredLocked(stateRoot: fixture.stateRoot, homeDirectory: fixture.home)
      #expect(try SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot).read() != nil)
    } else {
      try runner.rollbackDeferredLocked(stateRoot: fixture.stateRoot, homeDirectory: fixture.home)
      #expect(try native.service.registration(home: fixture.home) == nil)
    }
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test func preexistingStoppedRegistrationIsNeverClaimedOrDeleted() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    try native.createRegistration()
    let original = try native.service.registration(home: fixture.home)
    let runner = KeybindingsApplyCommandRunner(lifecycle: native.lifecycle)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    _ = try runner.teardownLocked(
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home, dryRun: false)
    #expect(native.mutations == ["--start-service", "--stop-service"])
    #expect(try native.service.registration(home: fixture.home) == original)
  }

  @Test func deferredTeardownRollbackRestartsOwnedService() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    let runner = KeybindingsApplyCommandRunner(lifecycle: native.lifecycle)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    _ = try runner.teardownLocked(
      stateRoot: fixture.stateRoot, homeDirectory: fixture.home,
      dryRun: false, deferFinalization: true)
    #expect(!native.state.withLock { $0.running })
    try runner.rollbackDeferredLocked(stateRoot: fixture.stateRoot, homeDirectory: fixture.home)
    #expect(native.state.withLock { $0.running })
    #expect(try SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot).read() != nil)
    #expect(try fixture.execute(runner: runner, json: true).output.contains("no_change"))
  }

  @Test func changedRegistrationBlocksTeardownBeforeMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    let runner = KeybindingsApplyCommandRunner(lifecycle: native.lifecycle)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    try native.createRegistration(extra: ["Disabled": true])
    let before = native.mutations
    #expect(throws: (any Error).self) {
      try runner.teardownLocked(
        stateRoot: fixture.stateRoot, homeDirectory: fixture.home, dryRun: false)
    }
    #expect(native.mutations == before)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test func installationWithoutSavedEvidenceRemainsExplicitRecovery() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    var change = try native.service.prepare(home: fixture.home, stateRoot: fixture.stateRoot)
    change.installationAttempted = true
    try native.createRegistration()
    #expect(throws: (any Error).self) {
      try native.service.rollback(change, home: fixture.home, stateRoot: fixture.stateRoot)
    }
    #expect(native.mutations.isEmpty)
    #expect(try native.service.registration(home: fixture.home) != nil)
  }

  @Test(arguments: ["custom", "symlink", "disabled", "loaded-stopped", "unknown-job-error"])
  func unsafePriorStateBlocksWithoutMutation(kind: String) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let native = SkhdNativeFixture(fixture: fixture)
    switch kind {
    case "custom": try native.createRegistration(extra: ["Disabled": true])
    case "symlink":
      try native.createRegistration()
      let file = native.service.propertyList(fixture.home)
      let other = fixture.root.appending(path: "custom.plist")
      try FileManager.default.moveItem(at: file, to: other)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
    case "disabled": native.state.withLock { $0.disabled = true }
    case "loaded-stopped":
      try native.createRegistration()
      native.state.withLock { $0.loaded = true }
    default: native.state.withLock { $0.jobError = true }
    }
    #expect(throws: (any Error).self) {
      try native.service.prepare(home: fixture.home, stateRoot: fixture.stateRoot)
    }
    #expect(native.mutations.isEmpty)
  }
}

private final class SkhdNativeFixture: Sendable {
  struct State {
    var calls: [String] = []
    var running = false
    var loaded = false
    var failStart = false
    var disabled = false
    var jobError = false
  }
  let state = Mutex(State())
  let fixture: KeybindingsApplyFixture
  init(fixture: KeybindingsApplyFixture) { self.fixture = fixture }
  var mutations: [String] { state.withLock { $0.calls } }
  var process: KeybindingProcessInspector {
    KeybindingProcessInspector { self.state.withLock { $0.running ? .testRunning : .notRunning } }
  }
  var service: SkhdUserService {
    SkhdUserService(runner: ProcessRunner { try self.run($0) }, process: process)
  }
  var lifecycle: KeybindingLifecycleController {
    KeybindingLifecycleController(
      preflight: { try self.verify() },
      restart: {
        self.state.withLock {
          $0.calls.append("--restart-service")
          $0.running = true
          $0.loaded = true
        }
      },
      reload: { self.state.withLock { $0.calls.append("--reload") } },
      verifyProcess: { try self.verify() }, inspectProcess: process.inspect, service: service)
  }
  private func verify() throws {
    guard state.withLock({ $0.running }) else {
      throw KeybindingsApplyError.lifecycle("manual Accessibility grant unavailable")
    }
  }
  func createRegistration(extra: [String: Bool] = [:]) throws {
    let file = service.propertyList(fixture.home)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var plist: [String: Any] = [
      "Label": SkhdUserService.label, "ProgramArguments": [SkhdUserService.executable.path],
      "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
      "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false, "Crashed": true],
      "StandardOutPath": "/tmp/skhd_\(NSUserName()).out.log",
      "StandardErrorPath": "/tmp/skhd_\(NSUserName()).err.log",
      "ProcessType": "Interactive", "Nice": -20,
    ]
    for (key, value) in extra { plist[key] = value }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: file)
  }
  private func run(_ request: ProcessRequest) throws -> ProcessResult {
    let argument = try #require(request.arguments.first)
    if request.executableURL.path == "/bin/launchctl" {
      if argument == "print-disabled" {
        return ProcessResult(
          terminationStatus: 0,
          output: state.withLock {
            $0.disabled ? "\"\(SkhdUserService.label)\" => disabled" : "disabled services = {}"
          })
      }
      let snapshot = state.withLock { $0 }
      if snapshot.jobError { return ProcessResult(terminationStatus: 5, output: "I/O failure") }
      return ProcessResult(
        terminationStatus: snapshot.loaded ? 0 : 113,
        output: snapshot.loaded
          ? "path = \(service.propertyList(fixture.home).path)\npid = \(KeybindingProcessInspection.testRunning.processID!)"
          : "not found")
    }
    if argument == "--version" { return ProcessResult(terminationStatus: 0, output: "skhd-v0.3.9") }
    state.withLock { $0.calls.append(argument) }
    switch argument {
    case "--install-service":
      let pending = try #require(
        try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read())
      #expect(pending.service?.installationAttempted == true)
      try createRegistration()
    case "--start-service":
      let pending = try #require(
        try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read())
      #expect(pending.service?.expectedRegistration != nil)
      state.withLock {
        $0.loaded = true
        $0.running = !$0.failStart
      }
    case "--stop-service":
      state.withLock {
        $0.running = false
        $0.loaded = false
      }
    case "--uninstall-service":
      try FileManager.default.removeItem(at: service.propertyList(fixture.home))
    default: throw KeybindingsApplyError.lifecycle("unexpected native operation: \(argument)")
    }
    return ProcessResult(terminationStatus: 0, output: "")
  }
}
