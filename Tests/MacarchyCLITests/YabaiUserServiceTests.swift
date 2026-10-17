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
    #expect(!f.commands.state.withLock { $0.disabled })
  }

  @Test func failedAccessibilityRestoresAbsence() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.commands.state.withLock { $0.failStart = true }
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
    #expect(!f.commands.state.withLock { $0.disabled })
    f.commands.state.withLock { $0.failStart = false }
    #expect(try f.apply().succeeded)
  }

  @Test func failedEnabledStateRestorationRetainsRecoverableJournal() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    f.commands.state.withLock {
      $0.failStart = true
      $0.failEnable = true
    }
    let failed = try f.apply()
    #expect(!failed.succeeded)
    #expect(failed.output.contains("enabled state"))
    #expect(YabaiTransactionStore(stateRoot: f.stateRoot).exists)
    #expect(try f.service.registration(home: f.home) != nil)
    #expect(f.commands.state.withLock { $0.disabled })
    f.commands.state.withLock {
      $0.failStart = false
      $0.failEnable = false
    }
    #expect(try f.apply().succeeded)
    #expect(!f.commands.state.withLock { $0.disabled })
    #expect(!YabaiTransactionStore(stateRoot: f.stateRoot).exists)
  }

  @Test(arguments: [false, true])
  func deferredAggregateCanRollbackOrCommit(commit: Bool) async throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try activateCatppuccinMocha(stateRoot: f.stateRoot)
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
    f.commands.state.withLock {
      $0.running = running
      $0.loaded = running
    }
    let before = try f.service.registration(home: f.home)
    #expect(try f.apply().succeeded)
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false)
    #expect(try f.service.registration(home: f.home) == before)
    #expect(f.commands.state.withLock { $0.running } == running)
    #expect(!f.mutations.contains("--uninstall-service"))
  }

  @Test func deferredTeardownRollbackAndForwardRecovery() throws {
    let f = try YabaiNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try f.apply().succeeded)
    let registration = try #require(try f.service.registration(home: f.home))
    _ = try f.provider.teardownLocked(
      lifecycle: f.lifecycle, faultInjector: { _ in }, dryRun: false, deferFinalization: true)
    #expect(!f.commands.state.withLock { $0.running })
    #expect(try f.service.registration(home: f.home) == registration)
    try f.provider.rollbackDeferred(lifecycle: f.lifecycle)
    #expect(f.commands.state.withLock { $0.running })
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
    f.commands.state.withLock {
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
  let root: URL
  let home: URL
  let stateRoot: URL
  let profile: URL
  let commands: NativeServiceCommandFake<YabaiServicePolicy>
  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-yabai-service-\(UUID())")
    let home = root.appending(path: "home")
    let stateRoot = home.appending(path: ".config/macarchy")
    self.home = home
    self.stateRoot = stateRoot
    profile = stateRoot.appending(path: "profile.toml")
    commands = NativeServiceCommandFake(
      home: home, processID: 42, versionOutput: "yabai-v7.1.25",
      pendingService: { try YabaiTransactionStore(stateRoot: stateRoot).read().map(\.service) })
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try "schema_version = 1\n[top_bar]\nprovider = \"disabled\"\n".write(
      to: profile, atomically: true, encoding: .utf8)
  }
  var resources: URL { repositoryRoot.appending(path: "Desktop") }
  var mutations: [String] { commands.mutations }
  var service: YabaiUserService {
    YabaiUserService(
      runner: commands.runner,
      process: {
        self.commands.state.withLock { $0.running ? (42, "/opt/homebrew/bin/yabai") : nil }
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
      preflight: { self.commands.state.withLock { $0.running } },
      restart: {
        self.commands.state.withLock {
          $0.calls.append("--restart-service")
          $0.running = true
          $0.loaded = true
        }
      },
      stop: { throw YabaiDesktopError.lifecycle("unjournaled stop is not expected") },
      inspect: { composition in
        guard self.commands.state.withLock({ $0.running }) else { return .stopped }
        return YabaiRuntimeInspection(
          status: .converged, message: "verified", verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: true, processID: 42, executablePath: "/opt/homebrew/bin/yabai")
      },
      waitBetweenInspections: {}, service: service,
      verifyStarted: {
        if self.commands.state.withLock({ $0.failStart }) {
          throw YabaiDesktopError.lifecycle("manual Accessibility grant unavailable")
        }
      })
  }
  func createRegistration(extra: [String: Bool] = [:]) throws {
    try commands.createRegistration(extra: extra)
  }
}
