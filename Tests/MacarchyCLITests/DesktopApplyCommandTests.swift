import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI

struct DesktopApplyCommandTests {
  @Test
  func cleanInstallAndRoleDisableRoundTripCreatedProviderState() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = YabaiLifecycleFixture(running: false)
    let runner = DesktopApplyCommandRunner(lifecycle: lifecycle.controller)

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let entry = fixture.home.appending(path: ".config/yabai/yabairc")
    #expect(apply.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)

    try """
    schema_version = 1
    [desktop]
    provider = "disabled"
    [yabai]
    hook = "unused-while-disabled.sh"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let disablePlan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let disablePlanReport = try #require(
      JSONSerialization.jsonObject(with: Data(disablePlan.output.utf8)) as? [String: Any]
    )
    let disableActions = try #require(disablePlanReport["actions"] as? [[String: Any]])
    #expect(disableActions.compactMap { $0["id"] as? String } == ["teardown_yabai_provider"])
    let disable = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    #expect(disable.succeeded)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/yabai").path
      )
    )
    #expect(lifecycle.calls.withLock { $0 }.contains("stop"))
    let disabledStatus = try DesktopStatusCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(disabledStatus.succeeded)
  }

  @Test
  func adoptsRegularEntryVerifiesStatusAndRestoresExactInode() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("original yabai\n")
    var originalMetadata = stat()
    #expect(lstat(entry.path, &originalMetadata) == 0)
    let lifecycle = YabaiLifecycleFixture(running: true)
    let runner = DesktopApplyCommandRunner(lifecycle: lifecycle.controller)
    let digest = try fixture.adoptionDigest()

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)

    let repeatApply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      json: true
    )
    let repeatReport = try #require(
      JSONSerialization.jsonObject(with: Data(repeatApply.output.utf8)) as? [String: Any]
    )
    #expect(repeatApply.succeeded)
    #expect(repeatReport["outcome"] as? String == "no_change")
    #expect(repeatReport["mutated"] as? Bool == false)

    let plan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let planReport = try #require(
      JSONSerialization.jsonObject(with: Data(plan.output.utf8)) as? [String: Any]
    )
    #expect((planReport["actions"] as? [Any])?.isEmpty == true)

    let status = try DesktopStatusCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(status.succeeded)

    let teardown = try DesktopTeardownCommandRunner(lifecycle: lifecycle.controller).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    var restoredMetadata = stat()
    #expect(lstat(entry.path, &restoredMetadata) == 0)
    #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "original yabai\n")
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try YabaiOwnershipStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func adoptsAndRestoresOneFileDirectorySymlinkWithoutTouchingSource() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "dotfiles/yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceEntry = source.appending(path: "yabairc")
    try "dotfiles yabai\n".write(to: sourceEntry, atomically: true, encoding: .utf8)
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    let directory = configuration.appending(path: "yabai", directoryHint: .isDirectory)
    let originalTarget = "../../dotfiles/yabai"
    try FileManager.default.createSymbolicLink(
      atPath: directory.path,
      withDestinationPath: originalTarget
    )
    var originalMetadata = stat()
    #expect(lstat(directory.path, &originalMetadata) == 0)
    let lifecycle = YabaiLifecycleFixture(running: false)
    let digest = try fixture.adoptionDigest()

    let apply = try DesktopApplyCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    #expect(try String(contentsOf: sourceEntry, encoding: .utf8) == "dotfiles yabai\n")

    let teardown = try DesktopTeardownCommandRunner(lifecycle: lifecycle.controller).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    #expect(try fixture.linkTarget(directory) == originalTarget)
    var restoredMetadata = stat()
    #expect(lstat(directory.path, &restoredMetadata) == 0)
    #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
  }

  @Test
  func interruptedProviderReplacementRecoversBeforeRetry() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("recover me\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let interrupted = DesktopApplyCommandRunner(
      lifecycle: lifecycle.controller,
      faultInjector: { checkpoint in
        if checkpoint == .providerChanged { throw YabaiInterruptionError.injected }
      }
    )
    let digest = try fixture.adoptionDigest()

    #expect(throws: YabaiInterruptionError.self) {
      _ = try interrupted.execute(
        resourcesRoot: fixture.resources,
        profileURL: fixture.profile,
        profileRequired: false,
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        adopt: digest,
        json: true
      )
    }
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)

    let retry = try DesktopApplyCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(retry.succeeded)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)
  }

  @Test
  func interruptedTeardownResumesForwardFromRestoredOriginal() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("restore after interruption\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let digest = try fixture.adoptionDigest()
    let apply = try DesktopApplyCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    let interrupted = DesktopTeardownCommandRunner(
      lifecycle: lifecycle.controller,
      faultInjector: { checkpoint in
        if checkpoint == .providerRestored { throw YabaiInterruptionError.injected }
      }
    )

    #expect(throws: YabaiInterruptionError.self) {
      _ = try interrupted.execute(
        stateRoot: fixture.state,
        homeDirectory: fixture.home,
        dryRun: false,
        json: true
      )
    }
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      try String(contentsOf: entry, encoding: .utf8) == "restore after interruption\n"
    )

    let resumed = try DesktopTeardownCommandRunner(lifecycle: lifecycle.controller).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(resumed.succeeded)
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      try String(contentsOf: entry, encoding: .utf8) == "restore after interruption\n"
    )
  }

  @Test
  func failedRuntimeVerificationRollsBackProviderAndServiceState() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("working original\n")
    let lifecycle = YabaiLifecycleFixture(running: true, runtimeStatus: .drifted)
    let digest = try fixture.adoptionDigest()

    let apply = try DesktopApplyCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(!apply.succeeded)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "working original\n")
    #expect(!YabaiTransactionStore(stateRoot: fixture.state).exists)
    #expect(lifecycle.calls.withLock { $0 }.filter { $0 == "restart" }.count == 2)
  }

  @Test
  func retainedOriginalDriftBlocksStatusAndTeardownWithoutRemovingManagedEntry() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularConfiguration("retained original\n")
    let lifecycle = YabaiLifecycleFixture(running: true)
    let digest = try fixture.adoptionDigest()
    let apply = try DesktopApplyCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: digest,
      json: true
    )
    #expect(apply.succeeded)
    let storedOwnership = try YabaiOwnershipStore(stateRoot: fixture.state).read()
    let ownership = try #require(storedOwnership)
    let retained = try #require(ownership.retainedOriginalPath)
    try Data("drifted original\n".utf8).write(to: URL(filePath: retained))

    let status = try DesktopStatusCommandRunner(lifecycle: lifecycle.controller).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(!status.succeeded)
    let teardown = try DesktopTeardownCommandRunner(lifecycle: lifecycle.controller).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(!teardown.succeeded)
    #expect(try fixture.linkTarget(entry) == fixture.managedTarget)
    #expect(YabaiTransactionStore(stateRoot: fixture.state).exists)
  }
}

private struct DesktopApplyFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-desktop-apply-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = state.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  var resources: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Desktop", directoryHint: .isDirectory)
  }

  var managedTarget: String { "../macarchy/desktop/yabai/current/yabairc" }

  func installRegularConfiguration(_ text: String) throws -> URL {
    let directory = home.appending(path: ".config/yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entry = directory.appending(path: "yabairc")
    try text.write(to: entry, atomically: true, encoding: .utf8)
    return entry
  }

  func adoptionDigest() throws -> String {
    let execution = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: false,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(execution.output.utf8)) as? [String: Any]
    )
    let provider = try #require(object["provider"] as? [String: Any])
    return try #require(provider["adoption_evidence_digest"] as? String)
  }

  func linkTarget(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }
}

private final class YabaiLifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])
  private let running: Mutex<Bool>
  private let runtimeStatus: YabaiRuntimeStatus

  init(running: Bool, runtimeStatus: YabaiRuntimeStatus = .converged) {
    self.running = Mutex(running)
    self.runtimeStatus = runtimeStatus
  }

  var controller: YabaiLifecycleController {
    YabaiLifecycleController(
      preflight: {
        self.calls.withLock { $0.append("preflight") }
        return self.running.withLock { $0 }
      },
      restart: {
        self.calls.withLock { $0.append("restart") }
        self.running.withLock { $0 = true }
      },
      stop: {
        self.calls.withLock { $0.append("stop") }
        self.running.withLock { $0 = false }
      },
      inspect: { composition in
        self.calls.withLock { $0.append("inspect") }
        return YabaiRuntimeInspection(
          status: self.runtimeStatus,
          message: self.runtimeStatus == .drifted ? "injected runtime drift" : "verified",
          verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: self.runtimeStatus != .drifted,
          processID: 42,
          executablePath: "/opt/homebrew/bin/yabai"
        )
      }
    )
  }
}
