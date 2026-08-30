import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsApplyCommandTests {
  @Test
  func cleanEntryApplyRestartsVerifiesAndBecomesIdempotent() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)

    let first = try fixture.execute(runner: runner, json: true)
    let firstReport = try jsonObject(first.output)

    #expect(first.succeeded)
    #expect(firstReport["outcome"] as? String == "applied")
    #expect(firstReport["lifecycle"] as? String == "restart")
    #expect(lifecycle.calls.withLock { $0 } == ["preflight", "restart", "verify"])
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .current)
    let provider = KeybindingProviderInspector().inspect(
      homeDirectory: fixture.home,
      stateRoot: fixture.stateRoot,
      generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
    )
    #expect(provider.status == .managed)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(throws: SetupOwnershipError.self) {
      _ = try SetupOwnershipManager().teardown(
        homeDirectory: fixture.home,
        dryRun: true
      )
    }

    let second = try fixture.execute(runner: runner, json: true)
    let secondReport = try jsonObject(second.output)
    #expect(second.succeeded)
    #expect(secondReport["outcome"] as? String == "no_change")
    #expect(secondReport["mutated"] as? Bool == false)
    #expect(
      lifecycle.calls.withLock { $0 }
        == ["preflight", "restart", "verify", "preflight", "verify"]
    )
  }

  @Test
  func existingConfigurationRemainsBlockedAndUnchanged() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try "alt - x : external\n".write(to: entry, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: entry)
    let lifecycle = LifecycleFixture()

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle.controller),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(try Data(contentsOf: entry) == before)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing)
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
  }

  @Test
  func applyPreviewUsesApplyEligibilityWithoutMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try "alt - x : external\n".write(to: entry, atomically: true, encoding: .utf8)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)

    let execution = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
  }

  @Test
  func lifecyclePreflightFailureBlocksBeforeGenerationMutation() throws {
    enum Injected: Error { case preflight }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = KeybindingLifecycleController(
      preflight: { throw Injected.preflight },
      restart: {},
      reload: {},
      verifyProcess: {}
    )

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing)
  }

  @Test
  func restartFailureRestoresEntryPointerOwnershipAndGeneration() throws {
    enum Injected: Error { case restart }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let restartCount = Mutex(0)
    let lifecycle = KeybindingLifecycleController(
      restart: {
        let count = restartCount.withLock { value -> Int in
          value += 1
          return value
        }
        if count == 1 { throw Injected.restart }
      },
      reload: {},
      verifyProcess: {}
    )

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "failed")
    #expect(restartCount.withLock { $0 } == 2)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path))
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    let records = try SetupOwnershipManager().readRecords(
      context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
    )
    #expect(!records.contains { $0.id == KeybindingProviderInspector.ownershipID })
  }

  @Test
  func rollbackLifecycleFailureLeavesRecoveryEvidence() throws {
    enum Injected: Error { case restart }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = KeybindingLifecycleController(
      restart: { throw Injected.restart },
      reload: {},
      verifyProcess: {}
    )

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "recovery_required")
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() != nil)
  }

  @Test
  func changedManagedGenerationUsesReloadRatherThanRestart() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }
    try "alt - j : changed command\n".write(
      to: fixture.resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )

    let execution = try fixture.execute(runner: runner, json: true)
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["lifecycle"] as? String == "reload")
    #expect(lifecycle.calls.withLock { $0 } == ["preflight", "reload", "verify"])

    try "alt - j : third command\n".write(
      to: fixture.resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    let generations = try FileManager.default.contentsOfDirectory(
      atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
    )
    #expect(generations.count == 2)
  }

  @Test
  func interruptedActivatingInstallRollsBackBeforeAFreshApply() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preparation = try KeybindingsPlanCommandRunner.live.prepare(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home
    )
    let composition = try #require(preparation.composition)
    let activator = KeybindingGenerationActivator(stateRoot: fixture.stateRoot)
    let staged = try activator.stage(composition)
    try activator.select(staged)
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry()
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .installEntry,
        phase: .activating,
        generationID: staged.manifest.generationID,
        previousGenerationID: nil,
        generationCreated: true
      )
    )
    let lifecycle = LifecycleFixture()

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle.controller),
      json: true
    )

    #expect(execution.succeeded)
    #expect(
      lifecycle.calls.withLock { $0 }
        == ["restart", "verify", "preflight", "restart", "verify"]
    )
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .current)
  }

  @Test
  func interruptedStagingBeforeGenerationDirectoryRecoversAndApplies() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .installEntry,
        phase: .staging,
        generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
        previousGenerationID: nil,
        generationCreated: true
      )
    )
    let generations = fixture.stateRoot.appending(
      path: "keybindings/generations",
      directoryHint: .isDirectory
    )
    #expect(!FileManager.default.fileExists(atPath: generations.path))
    let lifecycle = LifecycleFixture()

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle.controller),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "applied")
    #expect(report["mutated"] as? Bool == true)
    #expect(lifecycle.calls.withLock { $0 } == ["preflight", "restart", "verify"])
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test
  func interruptedActivatingUpdateReportsRecoveryWhenRestoredStateNeedsNoChange() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }

    let defaults = fixture.resources.appending(path: "defaults.skhdrc")
    let originalDefaults = try String(contentsOf: defaults, encoding: .utf8)
    let previousGenerationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    try "alt - j : interrupted command\n".write(
      to: defaults,
      atomically: true,
      encoding: .utf8
    )
    let preparation = try KeybindingsPlanCommandRunner.live.prepare(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home
    )
    let composition = try #require(preparation.composition)
    let activator = KeybindingGenerationActivator(stateRoot: fixture.stateRoot)
    let interrupted = try activator.stage(composition)
    try activator.select(interrupted)
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .updateGeneration,
        phase: .activating,
        generationID: interrupted.manifest.generationID,
        previousGenerationID: previousGenerationID,
        generationCreated: true
      )
    )
    try originalDefaults.write(to: defaults, atomically: true, encoding: .utf8)

    let execution = try fixture.execute(runner: runner, json: true)
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "no_change")
    #expect(report["mutated"] as? Bool == true)
    #expect(report["lifecycle"] as? String == "reload")
    #expect(lifecycle.calls.withLock { $0 } == ["reload", "verify", "preflight", "verify"])
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
        == previousGenerationID
    )
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test
  func previewModelsPendingRecoveryWithoutTrustingDirtyProviderState() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.stateRoot.appending(path: "keybindings", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .installEntry,
        phase: .activating,
        generationID: "k-01234567-89ab-cdef-0123-456789abcdef",
        previousGenerationID: nil,
        generationCreated: true
      )
    )
    let lifecycle = LifecycleFixture()

    let execution = try fixture.runner(lifecycle: lifecycle.controller).preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "recovery_planned")
    #expect(report["lifecycle"] as? String == "restart")
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
  }

  @Test
  func previewRejectsNoncanonicalStateRootLikeApply() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()

    let execution = try fixture.runner(lifecycle: lifecycle.controller).preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.root.appending(path: "other-state", directoryHint: .isDirectory),
      homeDirectory: fixture.home,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
  }

  @Test
  func inconsistentTransactionCannotDeleteItsRestoredGeneration() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let keybindings = fixture.stateRoot.appending(
      path: "keybindings",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: keybindings, withIntermediateDirectories: true)
    let generation = "k-01234567-89ab-cdef-0123-456789abcdef"
    try """
    {
      "generation_created": true,
      "generation_id": "\(generation)",
      "operation": "update_generation",
      "phase": "activating",
      "previous_generation_id": "\(generation)",
      "schema_version": 1
    }
    """.write(
      to: keybindings.appending(path: "transaction.json"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: KeybindingApplyTransactionError.self) {
      _ = try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read()
    }
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }
}

private final class LifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])

  var controller: KeybindingLifecycleController {
    KeybindingLifecycleController(
      preflight: { self.calls.withLock { $0.append("preflight") } },
      restart: { self.calls.withLock { $0.append("restart") } },
      reload: { self.calls.withLock { $0.append("reload") } },
      verifyProcess: { self.calls.withLock { $0.append("verify") } }
    )
  }
}

private struct KeybindingsApplyFixture {
  let root: URL
  let home: URL
  let stateRoot: URL
  let resources: URL
  let profile: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybindings-apply-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    resources = root.appending(path: "resources", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    for directory in [stateRoot, resources, home.appending(path: ".config/skhd")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try "alt - j : focus south\n".write(
      to: resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1
    [[bindings]]
    identity = "alt-j"
    label = "Focus below"
    category = "Test"
    order = 1
    """.write(
      to: resources.appending(path: "metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func runner(lifecycle: KeybindingLifecycleController) -> KeybindingsApplyCommandRunner {
    KeybindingsApplyCommandRunner(
      planner: .live,
      lifecycle: lifecycle,
      checkpoint: { _ in }
    )
  }

  func execute(
    runner: KeybindingsApplyCommandRunner,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: false,
      stateRoot: stateRoot,
      homeDirectory: home,
      json: json
    )
  }
}
