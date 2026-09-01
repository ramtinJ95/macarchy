import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct DesktopApplyCommandTests {
  @Test
  func publicCommandsConvergeReportAndTeardownSketchyBar() throws {
    let fixture = try SketchyBarPublicCommandFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let yabaiLifecycle = YabaiLifecycleFixture(running: false)
    let originalEntry = try fixture.installRegularEntry("personal bar\n")
    var original = stat()
    #expect(lstat(originalEntry.path, &original) == 0)
    let runner = DesktopApplyCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController
    )

    let apply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      adopt: nil,
      sketchyBarAdopt: try fixture.adoptionDigest(),
      json: true
    )
    #expect(apply.succeeded)
    #expect(fixture.lifecycle.isRunning)
    let applyReport = try #require(
      JSONSerialization.jsonObject(with: Data(apply.output.utf8)) as? [String: Any]
    )
    #expect(
      (applyReport["sketchybar"] as? [String: Any])?["generation_id"] as? String != nil
    )
    #expect(
      try fixture.linkTarget(fixture.home.appending(path: ".config/sketchybar/sketchybarrc"))
        == "../macarchy/desktop/sketchybar/current/sketchybarrc"
    )

    let repeatApply = try runner.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
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

    let status = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(status.succeeded)

    let driftedCore = SketchyBarCoreRuntimeInspection(
      status: .drifted,
      message: "injected item drift",
      themeGenerationID: fixture.core.themeGenerationID,
      barColor: fixture.core.barColor,
      items: Array(fixture.core.items.dropLast()),
      spaceIndices: fixture.core.spaceIndices,
      clockLabelPresent: fixture.core.clockLabelPresent
    )
    let driftedStatus = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: SketchyBarCoreRuntimeController(
        inspect: { _ in driftedCore },
        settle: { _ in driftedCore }
      )
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let driftedReport = try #require(
      JSONSerialization.jsonObject(with: Data(driftedStatus.output.utf8)) as? [String: Any]
    )
    #expect(!driftedStatus.succeeded)
    #expect(driftedReport["outcome"] as? String == "drifted")
    #expect(
      ((driftedReport["sketchybar"] as? [String: Any])?["core_runtime"]
        as? [String: Any])?["status"] as? String == "drifted"
    )

    let transaction = fixture.state.appending(path: "desktop/sketchybar/transaction.json")
    try Data("{}".utf8).write(to: transaction, options: .atomic)
    let corruptTransactionStatus = try DesktopStatusCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController
    ).execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true
    )
    let corruptReport = try #require(
      JSONSerialization.jsonObject(with: Data(corruptTransactionStatus.output.utf8))
        as? [String: Any]
    )
    #expect(!corruptTransactionStatus.succeeded)
    #expect(corruptReport["outcome"] as? String == "drifted")
    #expect((corruptReport["diagnostics"] as? [String])?.isEmpty == false)
    try FileManager.default.removeItem(at: transaction)

    let teardown = try DesktopTeardownCommandRunner(
      lifecycle: yabaiLifecycle.controller,
      sketchyBarLifecycle: fixture.lifecycle.controller,
      sketchyBarCoreRuntime: fixture.coreController
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: false,
      json: true
    )
    #expect(teardown.succeeded)
    #expect(!fixture.lifecycle.isRunning)
    var restored = stat()
    #expect(lstat(originalEntry.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(try String(contentsOf: originalEntry, encoding: .utf8) == "personal bar\n")
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

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
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let disablePlan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: true,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true,
      scope: .yabaiOnly
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

    let sketchyBarOwnership = fixture.state.appending(
      path: "desktop/sketchybar/ownership.json"
    )
    try FileManager.default.createDirectory(
      at: sketchyBarOwnership.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: sketchyBarOwnership)
    let plan = try DesktopPlanCommandRunner.live.execute(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      json: true,
      scope: .yabaiOnly
    )
    let planReport = try #require(
      JSONSerialization.jsonObject(with: Data(plan.output.utf8)) as? [String: Any]
    )
    #expect((planReport["actions"] as? [Any])?.isEmpty == true)
    #expect(planReport["sketchybar"] == nil)
    try FileManager.default.removeItem(at: sketchyBarOwnership)

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

  @Test
  func failedTeardownDryRunNeverReportsMutation() throws {
    let fixture = try DesktopApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transaction = fixture.state.appending(path: "desktop/yabai/transaction.json")
    try FileManager.default.createDirectory(
      at: transaction.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: transaction)

    let result = try DesktopTeardownCommandRunner(
      lifecycle: YabaiLifecycleFixture(running: false).controller
    ).execute(
      stateRoot: fixture.state,
      homeDirectory: fixture.home,
      dryRun: true,
      json: true
    )
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    )

    #expect(!result.succeeded)
    #expect(report["mutated"] as? Bool == false)
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
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: profile, atomically: true, encoding: .utf8)
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
      json: true,
      scope: .yabaiOnly
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

private struct SketchyBarPublicCommandFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let lifecycle: SketchyBarPublicLifecycleFixture
  let core: SketchyBarCoreRuntimeInspection

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-public-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = state.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try """
    schema_version = 1
    [desktop]
    provider = "disabled"
    """.write(to: profile, atomically: true, encoding: .utf8)
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    let generation = try ThemeActivator(root: state).activate(package: package)
    lifecycle = SketchyBarPublicLifecycleFixture()
    core = SketchyBarCoreRuntimeInspection(
      status: .converged,
      message: "converged",
      themeGenerationID: generation.generationID,
      barColor: "0xf01e1e2e",
      items: ["macarchy.clock", "macarchy.spaces.unavailable", "macarchy.theme.ready"],
      spaceIndices: [],
      clockLabelPresent: true
    )
  }

  var resources: URL { repositoryRoot.appending(path: "Desktop", directoryHint: .isDirectory) }

  var coreController: SketchyBarCoreRuntimeController {
    SketchyBarCoreRuntimeController(
      inspect: { _ in core },
      settle: { _ in core }
    )
  }

  func linkTarget(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  func installRegularEntry(_ contents: String) throws -> URL {
    let directory = home.appending(path: ".config/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entry = directory.appending(path: "sketchybarrc")
    try contents.write(to: entry, atomically: true, encoding: .utf8)
    return entry
  }

  func adoptionDigest() throws -> String {
    let generation = SketchyBarGenerationInspector(stateRoot: state).inspect()
    let provider = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: home,
      stateRoot: state,
      enabled: true,
      generation: generation
    )
    return try #require(provider.adoptionEvidenceDigest)
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private final class SketchyBarPublicLifecycleFixture: Sendable {
  private let running = Mutex(false)

  var isRunning: Bool { running.withLock { $0 } }

  var controller: SketchyBarLifecycleController {
    SketchyBarLifecycleController(
      inspect: { self.running.withLock { $0 } ? Self.runtime : .stopped },
      preflight: { self.running.withLock { $0 } },
      reload: { _ in Self.runtime },
      start: {
        self.running.withLock { $0 = true }
        return Self.runtime
      },
      stop: {
        self.running.withLock { $0 = false }
      }
    )
  }

  private static let runtime = SketchyBarRuntimeInspection(
    status: .running,
    message: "running",
    processID: 42,
    executablePath: "/opt/homebrew/Cellar/sketchybar/2.23.0/bin/sketchybar",
    serviceLabel: SketchyBarHomebrewService.serviceLabel
  )
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
