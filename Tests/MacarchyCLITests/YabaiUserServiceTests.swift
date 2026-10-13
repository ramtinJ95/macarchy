import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct YabaiUserServiceTests {
  @Test(arguments: [false, true])
  func startupProcessSettlingRemainsBounded(persistent: Bool) throws {
    var inspections = 0
    var waits = 0
    let inspect = {
      inspections += 1
      if persistent || inspections < 3 {
        throw YabaiDesktopError.lifecycle("expected one UID-scoped yabai process; found 2")
      }
      return (processID: Int32(42), executablePath: "/opt/homebrew/bin/yabai")
    }
    if persistent {
      #expect(throws: (any Error).self) {
        try YabaiLifecycleController.settledProcessEvidence(inspect: inspect, wait: { waits += 1 })
      }
      #expect(inspections == 20)
      #expect(waits == 19)
    } else {
      let observed = try YabaiLifecycleController.settledProcessEvidence(
        inspect: inspect, wait: { waits += 1 })
      #expect(observed?.processID == 42)
      #expect(inspections == 3)
      #expect(waits == 2)
    }
  }

  @Test func firstInstallPlansStartsVerifiesAndTearsDown() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let plan = try DesktopPlanCommandRunner(
      keybindings: nil, prerequisites: .assumed, service: f.service
    ).execute(
      resourcesRoot: f.resources, profileURL: f.profile, profileRequired: true,
      stateRoot: f.stateRoot, homeDirectory: f.home, json: true, scope: .yabaiOnly)
    #expect(plan.succeeded, "\(plan.output)")
    #expect(plan.output.contains("start_yabai_service"))
    #expect(f.mutations.isEmpty)
    let applied = try f.apply()
    #expect(applied.succeeded, "\(applied.output)")
    #expect(f.mutations == ["--install-service", "--start-service"])
    let ownership = try #require(try YabaiServiceOwnershipStore(stateRoot: f.stateRoot).read())
    #expect(ownership.original.registration == nil)
    #expect(!ownership.original.running)
    #expect(try f.apply().output.contains("no_change"))
    let status = try DesktopStatusCommandRunner(
      lifecycle: f.lifecycle, keybindings: nil, theme: nil
    ).execute(
      resourcesRoot: f.resources, profileURL: f.profile, profileRequired: true,
      stateRoot: f.stateRoot, homeDirectory: f.home, json: true)
    #expect(status.succeeded, "\(status.output)")
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false)
    #expect(
      f.mutations == [
        "--install-service", "--start-service", "--stop-service", "enable", "--uninstall-service",
      ])
    #expect(try f.service.registration(home: f.home) == nil)
    #expect(try YabaiServiceOwnershipStore(stateRoot: f.stateRoot).read() == nil)
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
    #expect(!f.state.withLock { $0.disabled })
  }

  @Test func failedAccessibilityRestoresAbsence() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.state.withLock { $0.failStart = true }
    let result = try f.apply()
    #expect(!result.succeeded)
    #expect(result.output.contains("Accessibility"))
    #expect(
      f.mutations == [
        "--install-service", "--start-service", "--stop-service", "enable", "--uninstall-service",
      ])
    #expect(try f.service.registration(home: f.home) == nil)
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
    #expect(try YabaiOwnershipStore(stateRoot: f.stateRoot).read() == nil)
    #expect(YabaiGenerationInspector(stateRoot: f.stateRoot).inspect().status == .missing)
    #expect(!f.state.withLock { $0.disabled })
    f.state.withLock { $0.failStart = false }
    #expect(try f.apply().succeeded)
  }

  @Test func failedEnabledStateRestorationRetainsRecoverableJournal() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.state.withLock {
      $0.failStart = true
      $0.failEnable = true
    }
    let failed = try f.apply()
    #expect(!failed.succeeded)
    #expect(failed.output.contains("enabled state"))
    #expect(YabaiTransactionStore(stateRoot: f.stateRoot).exists)
    #expect(try f.service.registration(home: f.home) != nil)
    #expect(f.state.withLock { $0.disabled })
    f.state.withLock {
      $0.failStart = false
      $0.failEnable = false
    }
    #expect(try f.apply().succeeded)
    #expect(!f.state.withLock { $0.disabled })
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
  }

  @Test(arguments: [false, true])
  func deferredAggregateCanRollbackOrCommit(commit: Bool) async throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let package = try ThemePackageLoader().load(
      packageURL: f.resources.deletingLastPathComponent().appending(path: "Themes/catppuccin-mocha")
    )
    _ = try ThemeActivator(root: f.stateRoot).activate(package: package)
    let result = try await f.runner.executeAggregate(
      resourcesRoot: f.resources, profileURL: f.profile, profileRequired: true,
      stateRoot: f.stateRoot, homeDirectory: f.home, consumerPaths: testConsumerPaths(),
      adopt: nil, keybindingsAdopt: nil, json: true, deferFinalization: true)
    #expect(result.succeeded, "\(result.output)")
    let pending = try #require(try YabaiTransactionStore(stateRoot: f.stateRoot).read())
    #expect(pending.schemaVersion == 2)
    #expect(pending.service?.installed != nil)
    #expect(try YabaiServiceOwnershipStore(stateRoot: f.stateRoot).read() == nil)
    #expect(
      try f.runner.finishDeferredAggregateApply(
        stateRoot: f.stateRoot, homeDirectory: f.home, commit: commit))
    if commit {
      #expect(try YabaiServiceOwnershipStore(stateRoot: f.stateRoot).read() != nil)
    } else {
      #expect(try f.service.registration(home: f.home) == nil)
    }
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
  }

  @Test(arguments: [false, true])
  func existingNativeServiceKeepsRegistration(running: Bool) throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.createRegistration()
    f.state.withLock {
      $0.running = running
      $0.loaded = running
    }
    let before = try f.service.registration(home: f.home)
    #expect(try f.apply().succeeded)
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false)
    #expect(try f.service.registration(home: f.home) == before)
    #expect(f.state.withLock { $0.running } == running)
    #expect(!f.mutations.contains("--uninstall-service"))
  }

  @Test func deferredTeardownRollbackAndForwardRecovery() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try f.apply().succeeded)
    let registration = try #require(try f.service.registration(home: f.home))
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false, deferFinalization: true)
    #expect(!f.state.withLock { $0.running })
    #expect(try f.service.registration(home: f.home) == registration)
    try f.provider.rollbackDeferred(lifecycle: f.lifecycle)
    #expect(f.state.withLock { $0.running })
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false, deferFinalization: true)
    // Crash after uninstall but before receipt/journal removal.
    try f.service.uninstall(home: f.home, expected: registration)
    try f.provider.commitDeferred(lifecycle: f.lifecycle)
    #expect(try YabaiServiceOwnershipStore(stateRoot: f.stateRoot).read() == nil)
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
  }

  @Test func driftBlocksStatusAndMutation() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try f.apply().succeeded)
    try f.createRegistration(extra: ["Disabled": true])
    let calls = f.mutations
    #expect(!((try f.apply()).succeeded))
    let status = try DesktopStatusCommandRunner(
      lifecycle: f.lifecycle, keybindings: nil, theme: nil
    ).execute(
      resourcesRoot: f.resources, profileURL: f.profile, profileRequired: true,
      stateRoot: f.stateRoot, homeDirectory: f.home, json: true)
    #expect(!status.succeeded)
    #expect(throws: (any Error).self) {
      try f.provider.teardownLocked(lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false)
    }
    #expect(f.mutations == calls)
  }

  @Test func interruptedUnclaimedInstallIsNotAdoptedOrDeleted() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var change = try f.service.prepare(home: f.home, stateRoot: f.stateRoot)
    change.installationAttempted = true
    try f.createRegistration()
    #expect(throws: (any Error).self) {
      try f.service.rollback(change, home: f.home, stateRoot: f.stateRoot)
    }
    #expect(f.mutations.isEmpty)
    #expect(try f.service.registration(home: f.home) != nil)
  }

  @Test(arguments: ["custom", "symlink", "disabled", "failed-job", "unknown-job"])
  func unsafeStatesNeverMutate(kind: String) throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.createRegistration(extra: kind == "custom" ? ["Disabled": true] : [:])
    if kind == "symlink" {
      let file = f.service.propertyList(f.home)
      let target = f.root.appending(path: "foreign.plist")
      try FileManager.default.moveItem(at: file, to: target)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    }
    f.state.withLock {
      $0.disabled = kind == "disabled"
      $0.loaded = kind == "failed-job"
      $0.jobError = kind == "unknown-job"
    }
    #expect(throws: (any Error).self) {
      try f.service.prepare(home: f.home, stateRoot: f.stateRoot)
    }
    #expect(f.mutations.isEmpty)
  }
}

private final class YabaiNativeFixture: Sendable {
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
  let root: URL
  let home: URL
  let stateRoot: URL
  let profile: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-yabai-service-\(UUID())")
    home = root.appending(path: "home")
    stateRoot = home.appending(path: ".config/macarchy")
    profile = stateRoot.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try "schema_version = 1\n[top_bar]\nprovider = \"disabled\"\n".write(
      to: profile, atomically: true, encoding: .utf8)
  }
  var resources: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Desktop")
  }
  var mutations: [String] { state.withLock { $0.calls } }
  var service: YabaiUserService {
    YabaiUserService(
      runner: ProcessRunner { try self.run($0) },
      process: {
        self.state.withLock { $0.running ? (42, "/opt/homebrew/bin/yabai") : nil }
      })
  }
  var provider: YabaiProviderTransaction {
    YabaiProviderTransaction(homeDirectory: home, stateRoot: stateRoot)
  }
  var runner: DesktopApplyCommandRunner {
    DesktopApplyCommandRunner(
      lifecycle: lifecycle, keybindings: nil, prerequisites: .assumed, theme: nil)
  }
  func apply() throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: resources, profileURL: profile, profileRequired: true,
      stateRoot: stateRoot, homeDirectory: home, adopt: nil, json: true, scope: .yabaiOnly)
  }
  var lifecycle: YabaiLifecycleController {
    YabaiLifecycleController(
      preflight: { self.state.withLock { $0.running } },
      restart: {
        self.state.withLock {
          $0.calls.append("--restart-service")
          $0.running = true
          $0.loaded = true
        }
      },
      stop: { throw YabaiDesktopError.lifecycle("unjournaled stop is not expected") },
      inspect: { composition in
        guard self.state.withLock({ $0.running }) else { return .stopped }
        return YabaiRuntimeInspection(
          status: .converged, message: "verified", verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: true, processID: 42, executablePath: "/opt/homebrew/bin/yabai")
      },
      waitBetweenInspections: {}, service: service,
      verifyStarted: {
        if self.state.withLock({ $0.failStart }) {
          throw YabaiDesktopError.lifecycle("manual Accessibility grant unavailable")
        }
      })
  }
  func createRegistration(extra: [String: Bool] = [:]) throws {
    let file = service.propertyList(home)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var plist: [String: Any] = [
      "Label": YabaiUserService.label, "ProgramArguments": [YabaiUserService.executable.path],
      "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
      "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false, "Crashed": true],
      "StandardOutPath": "/tmp/yabai_\(NSUserName()).out.log",
      "StandardErrorPath": "/tmp/yabai_\(NSUserName()).err.log",
      "ProcessType": "Interactive", "Nice": -20,
    ]
    for (key, value) in extra { plist[key] = value }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: file)
  }
  private func run(_ request: ProcessRequest) throws -> ProcessResult {
    let argument = try #require(request.arguments.first)
    if request.executableURL.path == "/bin/launchctl" {
      if argument == "enable" {
        #expect(request.arguments == ["enable", "gui/\(getuid())/\(YabaiUserService.label)"])
        #expect(try YabaiTransactionStore(stateRoot: stateRoot).read() != nil)
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
            $0.disabled ? "\"\(YabaiUserService.label)\" => disabled" : "disabled services = {}"
          })
      }
      let snapshot = state.withLock { $0 }
      if snapshot.jobError { return ProcessResult(terminationStatus: 5, output: "I/O failure") }
      return ProcessResult(
        terminationStatus: snapshot.loaded ? 0 : 113,
        output: snapshot.loaded
          ? "path = \(service.propertyList(home).path)\npid = 42" : "not found")
    }
    if argument == "--version" {
      return ProcessResult(terminationStatus: 0, output: "yabai-v7.1.25")
    }
    state.withLock { $0.calls.append(argument) }
    switch argument {
    case "--install-service":
      let pending = try #require(try YabaiTransactionStore(stateRoot: stateRoot).read())
      #expect(pending.service?.installationAttempted == true)
      try createRegistration()
    case "--start-service":
      let pending = try #require(try YabaiTransactionStore(stateRoot: stateRoot).read())
      #expect(pending.service?.expectedRegistration != nil)
      state.withLock {
        $0.loaded = true
        $0.running = !$0.failStart
      }
    case "--stop-service":
      state.withLock {
        $0.running = false
        $0.loaded = false
        $0.disabled = true
      }
    case "--uninstall-service":
      try FileManager.default.removeItem(at: service.propertyList(home))
    default: throw YabaiDesktopError.lifecycle("unexpected operation: \(argument)")
    }
    return ProcessResult(terminationStatus: 0, output: "")
  }
}
