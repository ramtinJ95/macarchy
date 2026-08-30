import Darwin
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
    let teardown = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: true
    )
    #expect(teardown.status == .planned)

    let second = try fixture.execute(runner: runner, json: true)
    let secondReport = try jsonObject(second.output)
    #expect(second.succeeded)
    #expect(secondReport["outcome"] as? String == "no_change")
    #expect(secondReport["mutated"] as? Bool == false)
    #expect(
      lifecycle.calls.withLock { $0 }
        == ["preflight", "restart", "verify", "preflight", "preflight", "verify"]
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
  func approvedRegularFileAdoptionPreviewsAndTeardownRestoresExactBytes() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : exact external bytes\n".utf8)
    try original.write(to: entry)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640],
      ofItemAtPath: entry.path
    )
    try setExtendedAttribute("com.macarchy.test", value: "preserved", at: entry)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)

    let refused = try fixture.execute(runner: runner, adopt: false, json: true)
    #expect(!refused.succeeded)
    #expect(try Data(contentsOf: entry) == original)
    let preview = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      adopt: try fixture.adoptionDigest(),
      json: true
    )
    #expect(preview.succeeded)
    #expect(try Data(contentsOf: entry) == original)

    let applied = try fixture.execute(runner: runner, adopt: true, json: true)
    #expect(applied.succeeded)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
    let teardown = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(teardown.status == .removed)
    #expect(teardown.mutationAttempted)
    #expect(try Data(contentsOf: entry) == original)
    let restoredAttributes = try FileManager.default.attributesOfItem(atPath: entry.path)
    #expect(restoredAttributes[.posixPermissions] as? Int == 0o640)
    #expect(try extendedAttribute("com.macarchy.test", at: entry) == "preserved")
    #expect(
      lifecycle.calls.withLock { $0 } == [
        "preflight", "preflight", "restart", "verify", "preflight", "restart", "verify",
      ])
  }

  @Test
  func adoptionRestartFailureRollsBackExactRegularFile() throws {
    enum Injected: Error { case restart }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : rollback exact bytes\n".utf8)
    try original.write(to: entry)
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
      adopt: true,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(restartCount.withLock { $0 } == 2)
    #expect(try Data(contentsOf: entry) == original)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func interruptedTeardownRollsBackThenIdempotentApplyKeepsManagedEntry() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : interrupted teardown\n".utf8).write(to: entry)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    var transaction = KeybindingApplyTransaction(
      operation: .teardownEntry,
      phase: .staged,
      generationID: generationID,
      previousGenerationID: generationID,
      generationCreated: false
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(transaction)
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    transaction = transaction.withPhase(.entryRestored)
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(transaction)

    let execution = try fixture.execute(runner: runner, adopt: true, json: true)
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "no_change")
    #expect(report["mutated"] as? Bool == true)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget)
    #expect(lifecycle.calls.withLock { $0 } == ["preflight", "verify"])
  }

  @Test
  func globalTeardownPreflightsSiblingOwnershipBeforeRestoringKeybindings() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skhd, withIntermediateDirectories: true)
    let entry = skhd.appending(path: "skhdrc")
    try Data("alt - x : exact prior entry\n".utf8).write(to: entry)
    let resources = fixture.root.appending(path: "keybinding-resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
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
    let lifecycle = LifecycleFixture()
    let runner = KeybindingsApplyCommandRunner(lifecycle: lifecycle.controller)
    let adoptionEvidence = try #require(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.stateRoot,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
      ).adoptionEvidenceDigest
    )
    #expect(
      try runner.execute(
        resourcesRoot: resources,
        profileURL: fixture.root.appending(path: "missing-profile.toml"),
        profileRequired: false,
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        adopt: adoptionEvidence,
        json: true
      ).succeeded
    )
    lifecycle.calls.withLock { $0.removeAll() }
    try Data("user drift\n".utf8).write(to: fixture.kittyConfiguration, options: .atomic)

    #expect(throws: SetupOwnershipError.self) {
      _ = try SetupOwnershipManager(keybindingLifecycle: lifecycle.controller).teardown(
        homeDirectory: fixture.home,
        dryRun: false
      )
    }

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
    #expect(lifecycle.calls.withLock { $0 } == ["preflight"])
  }

  @Test
  func approvedEntrySymlinkAdoptionNeverChangesTargetAndRestoresExactLinkText() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "dotfiles/skhdrc")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sourceBytes = Data("alt - x : external source\n".utf8)
    try sourceBytes.write(to: source)
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let linkText = "../../../dotfiles/skhdrc"
    try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: linkText)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)

    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    #expect(try Data(contentsOf: source) == sourceBytes)
    _ = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: entry.path) == linkText)
    #expect(try Data(contentsOf: source) == sourceBytes)
  }

  @Test
  func boundedDirectorySymlinkAdoptionNeverWritesThroughAndRestoresExactLink() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceEntry = source.appending(path: "skhdrc")
    let sourceBytes = Data("alt - x : directory source\n".utf8)
    try sourceBytes.write(to: sourceEntry)
    let linkText = "../../dotfiles/skhd"
    try FileManager.default.createSymbolicLink(atPath: skhd.path, withDestinationPath: linkText)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)

    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    #expect(try Data(contentsOf: sourceEntry) == sourceBytes)
    var metadata = stat()
    #expect(lstat(skhd.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFDIR)
    _ = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == linkText)
    #expect(try Data(contentsOf: sourceEntry) == sourceBytes)
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
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: KeybindingAdoptionEvidence(
        kind: .absent,
        linkDestination: nil,
        contentDigest: nil,
        inventory: []
      ),
      approvedEvidenceDigest: nil
    )
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
        == ["preflight", "restart", "verify", "preflight", "restart", "verify"]
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
    #expect(
      lifecycle.calls.withLock { $0 }
        == ["preflight", "reload", "verify", "preflight", "verify"]
    )
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

  @Test
  func teardownDoesNotFinalizeMissingOwnershipWithoutFinalizationPhase() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : preserve evidence\n".utf8).write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    try store.write(
      KeybindingApplyTransaction(
        operation: .teardownEntry,
        phase: .activating,
        generationID: generationID,
        previousGenerationID: generationID,
        generationCreated: false
      )
    )
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    try SetupOwnershipManager().persist(records: [], context: context)
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    #expect(FileManager.default.fileExists(atPath: backup.path))

    #expect(throws: SetupOwnershipError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: false
      )
    }

    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(try store.read()?.phase == .activating)
  }

  @Test
  func finalizedTeardownResidueIsDurablyRecognized() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : finalized restoration\n".utf8)
    try original.write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    let finalizing = KeybindingApplyTransaction(
      operation: .teardownEntry,
      phase: .restorationFinalizing,
      generationID: generationID,
      previousGenerationID: generationID,
      generationCreated: false
    )
    try store.write(finalizing)
    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.restoreOriginalEntry()
    try provider.finalizeOriginalRestoration()

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .none)
    #expect(try Data(contentsOf: entry) == original)
    #expect(try store.read() == nil)
  }

  @Test
  func teardownFinalizationResumesWithoutRollingManagedEntryBack() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : finalizing restoration\n".utf8)
    try original.write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    try store.write(
      KeybindingApplyTransaction(
        operation: .teardownEntry,
        phase: .restorationFinalizing,
        generationID: generationID,
        previousGenerationID: generationID,
        generationCreated: false
      )
    )
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .none)
    #expect(try Data(contentsOf: entry) == original)
    #expect(try store.read() == nil)
  }

  @Test
  func finalizedAdoptionRollbackResidueCanCompleteAndReapply() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : rollback finalized\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let preparation = try KeybindingsPlanCommandRunner.live.prepare(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home
    )
    let composition = try #require(preparation.composition)
    let activator = KeybindingGenerationActivator(stateRoot: fixture.stateRoot)
    let generation = try activator.stage(composition)
    try activator.select(generation)
    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    var transaction = KeybindingApplyTransaction(
      operation: .adoptEntry,
      phase: .activating,
      generationID: generation.manifest.generationID,
      previousGenerationID: nil,
      generationCreated: true
    )
    try store.write(transaction)
    try provider.restoreOriginalEntry()
    try activator.restoreCurrent(generationID: nil)
    transaction = transaction.withPhase(.restorationFinalizing)
    try store.write(transaction)
    try provider.finalizeOriginalRestoration()

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: evidence.digest,
      json: true
    )

    #expect(execution.succeeded)
    #expect(try store.read() == nil)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func directoryAdoptionRecoversAuthenticatedEmptyConstructionClaim() throws {
    enum Interrupted: Error { case afterDirectoryCreate }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("alt - x : source\n".utf8).write(to: source.appending(path: "skhdrc"))
    try FileManager.default.createSymbolicLink(
      atPath: skhd.path,
      withDestinationPath: "../../dotfiles/skhd"
    )
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .directoryClaimCreated { throw Interrupted.afterDirectoryCreate }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let claim = fixture.home.appending(
      path: ".config/.skhd.macarchy-keybindings-\(try #require(record.claimNonce))"
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: claim.path).isEmpty)

    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )

    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: skhd.appending(path: "skhdrc").path
      ) == KeybindingProviderInspector.managedTarget
    )
    #expect(!FileManager.default.fileExists(atPath: claim.path))
  }

  @Test
  func directoryRestorationRecoversClaimAfterManagedLeafRemoval() throws {
    enum Interrupted: Error { case afterLeafRemoval }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("alt - x : source\n".utf8).write(to: source.appending(path: "skhdrc"))
    let linkText = "../../dotfiles/skhd"
    try FileManager.default.createSymbolicLink(atPath: skhd.path, withDestinationPath: linkText)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .directoryClaimEntryRemoved { throw Interrupted.afterLeafRemoval }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }

    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == linkText)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/.skhd.macarchy-keybindings").path
      )
    )
  }

  @Test
  func regularRestorationRecoversAuthenticatedPartialClaim() throws {
    enum Interrupted: Error { case afterWrite }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : original\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularRestorationClaimWritten { throw Interrupted.afterWrite }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }
    let record = try fixture.keybindingOwnershipRecord()
    let claim = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce))"
    )
    #expect(FileManager.default.fileExists(atPath: claim.path))

    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()

    #expect(try Data(contentsOf: entry) == original)
    #expect(!FileManager.default.fileExists(atPath: claim.path))
  }

  @Test
  func foreignReplacementOfAuthenticatedRegularClaimIsPreservedAndBlocks() throws {
    enum Interrupted: Error { case afterWrite }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : original\n".utf8).write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularRestorationClaimWritten { throw Interrupted.afterWrite }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }
    let record = try fixture.keybindingOwnershipRecord()
    let claim = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce))"
    )
    try FileManager.default.removeItem(at: claim)
    let foreign = Data("foreign replacement".utf8)
    try foreign.write(to: claim)

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    }

    #expect(try Data(contentsOf: claim) == foreign)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func foreignReplacementOfAuthenticatedDirectoryClaimIsPreservedAndBlocks() throws {
    enum Interrupted: Error { case afterDirectoryCreate }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("alt - x : source\n".utf8).write(to: source.appending(path: "skhdrc"))
    let linkText = "../../dotfiles/skhd"
    try FileManager.default.createSymbolicLink(atPath: skhd.path, withDestinationPath: linkText)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .directoryClaimCreated { throw Interrupted.afterDirectoryCreate }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let claim = fixture.home.appending(
      path: ".config/.skhd.macarchy-keybindings-\(try #require(record.claimNonce))"
    )
    try FileManager.default.removeItem(at: claim)
    try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: false)

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: claim.path).isEmpty)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == linkText)
  }

  @Test
  func staleAdoptionEvidenceBlocksBeforeGenerationOrTransactionMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : previewed\n".utf8).write(to: entry)
    let reviewed = try fixture.adoptionDigest()
    try Data("alt - x : changed after preview\n".utf8).write(to: entry)

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: reviewed,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(try Data(contentsOf: entry) == Data("alt - x : changed after preview\n".utf8))
  }

  @Test
  func adoptionPreflightRejectsPinnedBackupParentSymlinkBeforeMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : external\n".utf8).write(to: entry)
    let external = fixture.root.appending(path: "external-backups", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let setup = fixture.stateRoot.appending(path: "state/setup", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: setup.appending(path: "backups").path,
      withDestinationPath: external.path
    )

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: try fixture.adoptionDigest(),
      json: true
    )

    #expect(!execution.succeeded)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
  }

  @Test
  func teardownDryRunAuthenticatesBackupMetadataAndForeignClaims() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : external\n".utf8).write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: backup.path
    )

    #expect(throws: SetupOwnershipError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: true
      )
    }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func teardownDryRunRejectsForeignDeterministicClaimWithoutMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : external\n".utf8).write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let claim = fixture.home.appending(path: ".config/skhd/.skhdrc.macarchy-keybindings")
    try FileManager.default.createSymbolicLink(
      atPath: claim.path,
      withDestinationPath: "foreign-target"
    )

    #expect(throws: SetupOwnershipError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: true
      )
    }

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: claim.path) == "foreign-target"
    )
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func multiplyLinkedRegularEntryIsRejectedBeforePreviewOrApply() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : hard linked\n".utf8).write(to: entry)
    let sibling = fixture.root.appending(path: "same-inode")
    #expect(link(entry.path, sibling.path) == 0)

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: "reviewed-before-hard-link",
      json: true
    )

    #expect(!execution.succeeded)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(try Data(contentsOf: sibling) == Data("alt - x : hard linked\n".utf8))
  }

  @Test
  func preparedManifestBeforeBackupRollsBackOnlyUntouchedPinnedOriginal() throws {
    enum Interrupted: Error { case afterManifest }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : untouched\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .manifestPrepared { throw Interrupted.afterManifest }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    #expect(!FileManager.default.fileExists(atPath: backup.path))

    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.preflightOriginalRestoration()
    try provider.restoreOriginalEntry()
    try provider.finalizeOriginalRestoration()

    #expect(try Data(contentsOf: entry) == original)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func preparedManifestWithoutBackupRejectsSameByteInodeReplacement() throws {
    enum Interrupted: Error { case afterManifest }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : replaced inode\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .manifestPrepared { throw Interrupted.afterManifest }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    try original.write(to: entry, options: .atomic)

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home)
        .preflightOriginalRestoration()
    }
    #expect(try Data(contentsOf: entry) == original)
  }

  @Test(arguments: [UInt32(UF_IMMUTABLE), UInt32(UF_APPEND)])
  func immutableOrAppendRegularEntryFlagsBlockAdoptionBeforeMutation(_ flag: UInt32) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : immutable\n".utf8).write(to: entry)
    guard chflags(entry.path, flag) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = chflags(entry.path, 0) }
    let reviewed = try fixture.adoptionDigest()

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: reviewed,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect((report["message"] as? String)?.contains("unsupported restrictive flag") == true)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test
  func hardLinkAddedAfterBackupBlocksFinalPinnedDisplacement() throws {
    enum Interrupted: Error { case afterBackup }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : linked late\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .backupWritten { throw Interrupted.afterBackup }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let sibling = fixture.root.appending(path: "late-hard-link")
    #expect(link(entry.path, sibling.path) == 0)

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(try Data(contentsOf: entry) == original)
    #expect(try Data(contentsOf: sibling) == original)
    var metadata = stat()
    #expect(lstat(entry.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFREG)
  }

  @Test
  func teardownDryRunAndExecuteIncludeRecoveryAndSubsequentTeardown() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : teardown after recovery\n".utf8)
    try original.write(to: entry)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }
    let previous = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    try "alt - j : pending update\n".write(
      to: fixture.resources.appending(path: "defaults.skhdrc"),
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
    let staged = try KeybindingGenerationActivator(stateRoot: fixture.stateRoot).stage(
      try #require(preparation.composition)
    )
    try KeybindingGenerationActivator(stateRoot: fixture.stateRoot).select(staged)
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    try store.write(
      KeybindingApplyTransaction(
        operation: .updateGeneration,
        phase: .activating,
        generationID: staged.manifest.generationID,
        previousGenerationID: previous,
        generationCreated: true
      )
    )

    let preview = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: true
    )
    #expect(preview.status == .planned)
    #expect(!preview.mutationAttempted)
    #expect(preview.lifecycle == .restart)
    #expect(preview.message.contains("recovery lifecycle=reload; teardown lifecycle=restart"))
    #expect(try store.read() != nil)
    lifecycle.calls.withLock { $0.removeAll() }

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .removed)
    #expect(result.mutationAttempted)
    #expect(result.lifecycle == .restart)
    #expect(result.message.contains("recovery lifecycle=reload; teardown lifecycle=restart"))
    #expect(
      lifecycle.calls.withLock { $0 }
        == ["preflight", "reload", "verify", "preflight", "restart", "verify"]
    )
    #expect(try Data(contentsOf: entry) == original)
    #expect(try store.read() == nil)
  }

  @Test
  func missingOwnershipBlocksUpdateRecoveryBeforePointerOrLifecycleMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }
    let previous = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    try "alt - j : unsafe update\n".write(
      to: fixture.resources.appending(path: "defaults.skhdrc"),
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
    let activator = KeybindingGenerationActivator(stateRoot: fixture.stateRoot)
    let staged = try activator.stage(try #require(preparation.composition))
    try activator.select(staged)
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    try store.write(
      KeybindingApplyTransaction(
        operation: .updateGeneration,
        phase: .activating,
        generationID: staged.manifest.generationID,
        previousGenerationID: previous,
        generationCreated: true
      )
    )
    try SetupOwnershipManager().persist(
      records: [],
      context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
    )

    #expect(throws: SetupOwnershipError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: false
      )
    }

    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
        == staged.manifest.generationID
    )
    #expect(try store.read()?.operation == .updateGeneration)
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes { bytes in
      url.path.withCString { path in
        name.withCString { attribute in
          Darwin.setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private func extendedAttribute(_ name: String, at url: URL) throws -> String {
    let size = url.path.withCString { path in
      name.withCString { Darwin.getxattr(path, $0, nil, 0, 0, 0) }
    }
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { bytes in
      url.path.withCString { path in
        name.withCString { Darwin.getxattr(path, $0, bytes.baseAddress, bytes.count, 0, 0) }
      }
    }
    guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return String(decoding: data, as: UTF8.self)
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
    KeybindingsApplyCommandRunner(lifecycle: lifecycle)
  }

  func execute(
    runner: KeybindingsApplyCommandRunner,
    adopt: Bool = false,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try execute(
      runner: runner,
      adoptionEvidence: adopt ? adoptionDigest() : nil,
      json: json
    )
  }

  func execute(
    runner: KeybindingsApplyCommandRunner,
    adoptionEvidence: String?,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: false,
      stateRoot: stateRoot,
      homeDirectory: home,
      adopt: adoptionEvidence,
      json: json
    )
  }

  func adoptionEvidence() throws -> KeybindingAdoptionEvidence {
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    let inspection = KeybindingProviderInspector().inspect(
      homeDirectory: home,
      stateRoot: stateRoot,
      generation: generation
    )
    if let evidence = inspection.adoptionEvidence { return evidence }
    let records = try SetupOwnershipManager().readRecords(
      context: SetupOwnershipManager.Context(homeDirectory: home)
    )
    let record = try #require(
      records.first { $0.id == KeybindingProviderInspector.ownershipID }
    )
    guard record.originalKind == .regularFile else {
      Issue.record("test fixture can only reconstruct regular-file recovery evidence")
      throw CancellationError()
    }
    let entry = home.appending(path: ".config/skhd/skhdrc")
    return KeybindingAdoptionEvidence(
      kind: .regularFile,
      linkDestination: nil,
      contentDigest: sha256Digest(try Data(contentsOf: entry)),
      inventory: []
    )
  }

  func adoptionDigest() throws -> String {
    try adoptionEvidence().digest
  }

  func keybindingOwnershipRecord() throws -> SetupOwnershipRecord {
    try #require(
      SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: home)
      ).first { $0.id == KeybindingProviderInspector.ownershipID }
    )
  }
}
