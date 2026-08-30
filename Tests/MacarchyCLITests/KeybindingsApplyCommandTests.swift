import ArgumentParser
import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingsApplyCommandTests {
  @Test
  func reviewedLegacyFallbackAdoptionNeverMutatesFallbackAndTeardownRevealsIt() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fallback = fixture.home.appending(path: ".skhdrc")
    let original = Data("alt - x : fallback stays external\n".utf8)
    try original.write(to: fallback)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)

    let refused = try fixture.execute(runner: runner, adopt: false, json: true)
    #expect(!refused.succeeded)
    #expect(try Data(contentsOf: fallback) == original)

    let applied = try fixture.execute(runner: runner, adopt: true, json: true)
    #expect(applied.succeeded)
    #expect(try Data(contentsOf: fallback) == original)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path
      ) == KeybindingProviderInspector.managedTarget
    )

    let teardown = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(teardown.status == .removed)
    #expect(try Data(contentsOf: fallback) == original)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path
      )
    )
  }

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
  func ordinaryParserDoesNotExposeAcceptanceRollbackFlag() throws {
    let arguments = [
      "keybindings", "apply", "--acceptance-fail-after-managed-update-reload",
    ]
    #if MACARCHY_ACCEPTANCE_TESTING
      _ = try Macarchy.parseAsRoot(arguments)
      #expect(throws: (any Error).self) {
        _ = try Macarchy.parseAsRoot(["teardown"] + arguments.suffix(1))
      }
      #expect(throws: (any Error).self) {
        _ = try Macarchy.parseAsRoot(arguments + ["--dry-run"])
      }
    #else
      #expect(throws: (any Error).self) {
        _ = try Macarchy.parseAsRoot(arguments)
      }
    #endif
  }

  #if MACARCHY_ACCEPTANCE_TESTING
    @Test
    func acceptanceCheckpointRollsBackManagedUpdateOnceAndCleansEvidence() throws {
      let fixture = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let lifecycle = LifecycleFixture()
      let runner = fixture.runner(lifecycle: lifecycle.controller)
      #expect(try fixture.execute(runner: runner, json: true).succeeded)
      let baseGeneration = try #require(
        KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
      )
      lifecycle.calls.withLock { $0.removeAll() }
      try "alt - j : acceptance update\n".write(
        to: fixture.resources.appending(path: "defaults.skhdrc"),
        atomically: true,
        encoding: .utf8
      )
      let checkpoint = Mutex<AcceptanceCheckpointObservation?>(nil)

      let execution = try runner.withAcceptanceManagedUpdateRollbackCheckpoint { generationID in
        let generation = KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
        let provider = KeybindingProviderInspector().inspect(
          homeDirectory: fixture.home,
          stateRoot: fixture.stateRoot,
          generation: generation
        )
        let transaction = try? KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read()
        let lifecycleURL = fixture.stateRoot.appending(path: "keybindings/lifecycle.json")
        checkpoint.withLock {
          $0 = AcceptanceCheckpointObservation(
            selectedGenerationID: generationID,
            currentGenerationID: generation.generationID,
            transactionGenerationID: transaction?.generationID,
            transactionPhase: transaction?.phase,
            lifecycleEvidenceExists: FileManager.default.fileExists(atPath: lifecycleURL.path),
            lifecycleStatus: KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).inspect(
              generation: generation,
              provider: provider,
              process: .testRunning
            ).status
          )
        }
      }.execute(
        resourcesRoot: fixture.resources,
        profileURL: fixture.profile,
        profileRequired: false,
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        json: true
      )
      let report = try jsonObject(execution.output)
      let observedCheckpoint = try #require(checkpoint.withLock { $0 })

      #expect(!execution.succeeded)
      #expect(report["outcome"] as? String == "failed")
      #expect(report["mutated"] as? Bool == true)
      #expect(report["lifecycle"] as? String == "reload")
      #expect(
        lifecycle.calls.withLock { $0 }
          == ["preflight", "reload", "verify", "preflight", "reload", "verify"]
      )
      #expect(
        execution.output.components(
          separatedBy: "acceptance checkpoint failed after verified managed update reload"
        ).count == 2
      )
      #expect(observedCheckpoint.selectedGenerationID != baseGeneration)
      #expect(
        observedCheckpoint.currentGenerationID == observedCheckpoint.selectedGenerationID
      )
      #expect(
        observedCheckpoint.transactionGenerationID == observedCheckpoint.selectedGenerationID
      )
      #expect(observedCheckpoint.transactionPhase == .activating)
      #expect(observedCheckpoint.lifecycleEvidenceExists)
      #expect(observedCheckpoint.lifecycleStatus == .matched)
      let restored = KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
      #expect(restored.generationID == baseGeneration)
      let provider = KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.stateRoot,
        generation: restored
      )
      #expect(provider.status == .managed)
      #expect(
        KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).inspect(
          generation: restored,
          provider: provider,
          process: .testRunning
        ).status == .matched
      )
      #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
      let generations = try FileManager.default.contentsOfDirectory(
        atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
      )
      #expect(generations == [baseGeneration])
    }

    @Test
    func acceptanceCheckpointBlocksEveryUnsupportedApplyBeforeMutation() throws {
      let clean = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: clean.root) }
      let cleanLifecycle = LifecycleFixture()
      let cleanExecution = try clean.runner(lifecycle: cleanLifecycle.controller)
        .withAcceptanceManagedUpdateRollbackCheckpoint().execute(
          resourcesRoot: clean.resources,
          profileURL: clean.profile,
          profileRequired: false,
          stateRoot: clean.stateRoot,
          homeDirectory: clean.home,
          json: true
        )
      #expect(!cleanExecution.succeeded)
      #expect(cleanLifecycle.calls.withLock { $0 }.isEmpty)
      #expect(
        KeybindingGenerationInspector().inspect(stateRoot: clean.stateRoot).status == .missing)
      #expect(try KeybindingApplyTransactionStore(stateRoot: clean.stateRoot).read() == nil)

      let adoption = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: adoption.root) }
      let adoptionEntry = adoption.home.appending(path: ".config/skhd/skhdrc")
      let adoptionBytes = Data("alt - x : external\n".utf8)
      try adoptionBytes.write(to: adoptionEntry)
      let adoptionLifecycle = LifecycleFixture()
      let adoptionExecution = try adoption.runner(lifecycle: adoptionLifecycle.controller)
        .withAcceptanceManagedUpdateRollbackCheckpoint().execute(
          resourcesRoot: adoption.resources,
          profileURL: adoption.profile,
          profileRequired: false,
          stateRoot: adoption.stateRoot,
          homeDirectory: adoption.home,
          adopt: try adoption.adoptionDigest(),
          json: true
        )
      #expect(!adoptionExecution.succeeded)
      #expect(adoptionLifecycle.calls.withLock { $0 }.isEmpty)
      #expect(try Data(contentsOf: adoptionEntry) == adoptionBytes)
      #expect(
        KeybindingGenerationInspector().inspect(stateRoot: adoption.stateRoot).status == .missing)
      #expect(try KeybindingApplyTransactionStore(stateRoot: adoption.stateRoot).read() == nil)

      let converged = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: converged.root) }
      let convergedLifecycle = LifecycleFixture()
      let convergedRunner = converged.runner(lifecycle: convergedLifecycle.controller)
      #expect(try converged.execute(runner: convergedRunner, json: true).succeeded)
      let convergedGeneration = try #require(
        KeybindingGenerationInspector().inspect(stateRoot: converged.stateRoot).generationID
      )
      convergedLifecycle.calls.withLock { $0.removeAll() }
      let convergedExecution = try convergedRunner.withAcceptanceManagedUpdateRollbackCheckpoint()
        .execute(
          resourcesRoot: converged.resources,
          profileURL: converged.profile,
          profileRequired: false,
          stateRoot: converged.stateRoot,
          homeDirectory: converged.home,
          json: true
        )
      #expect(!convergedExecution.succeeded)
      #expect(convergedLifecycle.calls.withLock { $0 }.isEmpty)
      #expect(
        KeybindingGenerationInspector().inspect(stateRoot: converged.stateRoot).generationID
          == convergedGeneration
      )
      #expect(try KeybindingApplyTransactionStore(stateRoot: converged.stateRoot).read() == nil)
    }

    @Test
    func acceptanceCheckpointBlocksPendingActivatingUpdateWithoutTouchingEvidence() throws {
      let fixture = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let lifecycle = LifecycleFixture()
      let runner = fixture.runner(lifecycle: lifecycle.controller)
      #expect(try fixture.execute(runner: runner, json: true).succeeded)
      let previousGenerationID = try #require(
        KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
      )

      try "alt - j : pending acceptance update\n".write(
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
      let composition = try #require(preparation.composition)
      let activator = KeybindingGenerationActivator(stateRoot: fixture.stateRoot)
      let pendingGeneration = try activator.stage(composition)
      try activator.select(pendingGeneration)
      let pending = KeybindingApplyTransaction(
        operation: .updateGeneration,
        phase: .activating,
        generationID: pendingGeneration.manifest.generationID,
        previousGenerationID: previousGenerationID,
        generationCreated: true
      )
      let transactionStore = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
      try transactionStore.write(pending)
      try KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).write(
        try KeybindingLifecycleEvidence(
          generationID: pending.generationID,
          providerEntryPoint: fixture.home.appending(path: ".config/skhd/skhdrc").path,
          providerTarget: KeybindingProviderInspector.managedTarget,
          action: .reload,
          process: .testRunning
        )
      )
      let currentURL = fixture.stateRoot.appending(path: "keybindings/current")
      let transactionURL = fixture.stateRoot.appending(path: "keybindings/transaction.json")
      let lifecycleURL = fixture.stateRoot.appending(path: "keybindings/lifecycle.json")
      let currentBefore = try FileManager.default.destinationOfSymbolicLink(
        atPath: currentURL.path
      )
      let transactionBefore = try Data(contentsOf: transactionURL)
      let lifecycleBefore = try Data(contentsOf: lifecycleURL)
      lifecycle.calls.withLock { $0.removeAll() }

      let execution = try runner.withAcceptanceManagedUpdateRollbackCheckpoint().execute(
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
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
          == currentBefore
      )
      #expect(try Data(contentsOf: transactionURL) == transactionBefore)
      #expect(try Data(contentsOf: lifecycleURL) == lifecycleBefore)
      #expect(try transactionStore.read() == pending)
    }

    @Test
    func acceptanceCheckpointRevalidatesNoChangeRaceBeforeTransactionMutation() throws {
      let fixture = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let initialLifecycle = LifecycleFixture()
      let initialRunner = fixture.runner(lifecycle: initialLifecycle.controller)
      #expect(try fixture.execute(runner: initialRunner, json: true).succeeded)

      let defaults = fixture.resources.appending(path: "defaults.skhdrc")
      let originalDefaults = try Data(contentsOf: defaults)
      try Data("alt - j : acceptance race update\n".utf8).write(to: defaults)
      let current = fixture.stateRoot.appending(path: "keybindings/current")
      let lifecycleEvidence = fixture.stateRoot.appending(path: "keybindings/lifecycle.json")
      let ownership = fixture.stateRoot.appending(path: "state/setup/ownership.json")
      let currentBefore = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
      let lifecycleBefore = try Data(contentsOf: lifecycleEvidence)
      let ownershipBefore = try Data(contentsOf: ownership)
      let generationsBefore = try FileManager.default.contentsOfDirectory(
        atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
      )
      let calls = Mutex<[String]>([])
      let lifecycle = KeybindingLifecycleController(
        preflight: {
          calls.withLock { $0.append("preflight") }
          try originalDefaults.write(to: defaults)
        },
        restart: { calls.withLock { $0.append("restart") } },
        reload: { calls.withLock { $0.append("reload") } },
        verifyProcess: { calls.withLock { $0.append("verify") } },
        inspectProcess: { .testRunning }
      )

      let execution = try fixture.runner(lifecycle: lifecycle)
        .withAcceptanceManagedUpdateRollbackCheckpoint().execute(
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
      #expect(calls.withLock { $0 } == ["preflight"])
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == currentBefore
      )
      #expect(try Data(contentsOf: lifecycleEvidence) == lifecycleBefore)
      #expect(try Data(contentsOf: ownership) == ownershipBefore)
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
        ) == generationsBefore
      )
      #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    }

    @Test(arguments: [false, true])
    func acceptanceCheckpointBlocksInstallAndAdoptionEligibilityRaces(
      leaveExternalEntry: Bool
    ) throws {
      let fixture = try KeybindingsApplyFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let initialLifecycle = LifecycleFixture()
      let initialRunner = fixture.runner(lifecycle: initialLifecycle.controller)
      #expect(try fixture.execute(runner: initialRunner, json: true).succeeded)
      try "alt - j : acceptance eligibility update\n".write(
        to: fixture.resources.appending(path: "defaults.skhdrc"),
        atomically: true,
        encoding: .utf8
      )

      let current = fixture.stateRoot.appending(path: "keybindings/current")
      let lifecycleEvidence = fixture.stateRoot.appending(path: "keybindings/lifecycle.json")
      let ownership = fixture.stateRoot.appending(path: "state/setup/ownership.json")
      let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
      let externalBytes = Data("alt - x : external eligibility race\n".utf8)
      let currentBefore = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
      let lifecycleBefore = try Data(contentsOf: lifecycleEvidence)
      let generationsBefore = try FileManager.default.contentsOfDirectory(
        atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
      )
      let calls = Mutex<[String]>([])
      let lifecycle = KeybindingLifecycleController(
        preflight: {
          calls.withLock { $0.append("preflight") }
          try FileManager.default.removeItem(at: entry)
          try FileManager.default.removeItem(at: ownership)
          if leaveExternalEntry { try externalBytes.write(to: entry) }
        },
        restart: { calls.withLock { $0.append("restart") } },
        reload: { calls.withLock { $0.append("reload") } },
        verifyProcess: { calls.withLock { $0.append("verify") } },
        inspectProcess: { .testRunning }
      )

      let execution = try fixture.runner(lifecycle: lifecycle)
        .withAcceptanceManagedUpdateRollbackCheckpoint().execute(
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
      #expect(calls.withLock { $0 } == ["preflight"])
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == currentBefore
      )
      #expect(try Data(contentsOf: lifecycleEvidence) == lifecycleBefore)
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: fixture.stateRoot.appending(path: "keybindings/generations").path
        ) == generationsBefore
      )
      #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
      #expect(!FileManager.default.fileExists(atPath: ownership.path))
      if leaveExternalEntry {
        #expect(try Data(contentsOf: entry) == externalBytes)
      } else {
        #expect(!FileManager.default.fileExists(atPath: entry.path))
      }
    }
  #endif

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
    try KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).write(
      try KeybindingLifecycleEvidence(
        generationID: staged.manifest.generationID,
        providerEntryPoint: fixture.home.appending(path: ".config/skhd/skhdrc").path,
        providerTarget: KeybindingProviderInspector.managedTarget,
        action: .restart,
        process: .testRunning
      )
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
    let finalGeneration = KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
    #expect(finalGeneration.generationID != staged.manifest.generationID)
    let finalProvider = KeybindingProviderInspector().inspect(
      homeDirectory: fixture.home,
      stateRoot: fixture.stateRoot,
      generation: finalGeneration
    )
    #expect(
      KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot).inspect(
        generation: finalGeneration,
        provider: finalProvider,
        process: .testRunning
      ).status == .matched
    )
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
  func previewPreflightsPendingRecoveryAndRejectsDirtyProviderState() throws {
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

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["lifecycle"] as? String == "none")
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
  func directoryAdoptionRecoversAtomicallyPublishedConstructionClaim() throws {
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
    #expect(try FileManager.default.contentsOfDirectory(atPath: claim.path) == ["skhdrc"])

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
      path:
        ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce)).publishing-\(try #require(record.claimNonce))"
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
      path:
        ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce)).publishing-\(try #require(record.claimNonce))"
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
  func regularDisplacementPinsOriginalAndSwapsBackForeignSameByteReplacement() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : pinned race\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    var before = stat()
    #expect(lstat(entry.path, &before) == 0)
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularOriginalPinned { try original.write(to: entry, options: .atomic) }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    var after = stat()
    #expect(lstat(entry.path, &after) == 0)
    #expect(after.st_ino != before.st_ino)
    #expect(try Data(contentsOf: entry) == original)
  }

  @Test
  func interruptedPostSwapClaimIsDurablyRecovered() throws {
    enum Interrupted: Error { case afterSwap }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : crash after swap\n".utf8).write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { if $0 == .providerClaimSwapped { throw Interrupted.afterSwap } }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func restoredMarkerRemovalRecoversFromRecordedIdentity() throws {
    enum Interrupted: Error { case beforeMarkerRemoval }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : marker recovery\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .restoredIdentityRecorded { throw Interrupted.beforeMarkerRemoval }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }

    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()

    #expect(try Data(contentsOf: entry) == original)
  }

  @Test
  func targetSourceRaceBlocksBeforeDirectorySymlinkDisplacement() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceEntry = source.appending(path: "skhdrc")
    try Data("alt - x : reviewed source\n".utf8).write(to: sourceEntry)
    let linkText = "../../dotfiles/skhd"
    try FileManager.default.createSymbolicLink(atPath: skhd.path, withDestinationPath: linkText)
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .providerClaimReady {
          try Data("alt - x : raced source\n".utf8).write(to: sourceEntry, options: .atomic)
        }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == linkText)
  }

  @Test
  func targetSourceRaceDuringDirectoryDisplacementSwapsProviderBack() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let source = fixture.root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceEntry = source.appending(path: "skhdrc")
    try Data("alt - x : approved\n".utf8).write(to: sourceEntry)
    let linkText = "../../dotfiles/skhd"
    try FileManager.default.createSymbolicLink(atPath: skhd.path, withDestinationPath: linkText)
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .sourceSwapCompleted {
          try Data("alt - x : changed during swap\n".utf8).write(to: sourceEntry, options: .atomic)
        }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == linkText)
  }

  @Test
  func reservedMarkerCollisionBlocksBeforeAdoptionMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : marker collision\n".utf8).write(to: entry)
    try setExtendedAttribute(
      KeybindingProviderInspector.claimMarkerAttribute,
      value: "foreign",
      at: entry
    )

    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: LifecycleFixture().controller),
      adoptionEvidence: try fixture.adoptionDigest(),
      json: true
    )

    #expect(!execution.succeeded)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty)
    #expect(try Data(contentsOf: entry) == Data("alt - x : marker collision\n".utf8))
  }

  @Test
  func backupDeletionInterruptionRetainsAuthenticatedRecordAndResumes() throws {
    enum Interrupted: Error { case afterBackupRemoval }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : backup deletion crash\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { if $0 == .backupRemoved { throw Interrupted.afterBackupRemoval } }
    )

    #expect(throws: Interrupted.self) { try interrupted.finalizeOriginalRestoration() }
    #expect(try fixture.keybindingOwnershipRecord().phase == .teardownPrepared)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc").path
      )
    )

    try KeybindingProviderTransaction(homeDirectory: fixture.home).finalizeOriginalRestoration()
    #expect(try Data(contentsOf: entry) == original)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty)
  }

  @Test
  func lateHardLinkOnRestoredClaimBlocksBeforeSwap() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : restoration link race\n".utf8).write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    let record = try fixture.keybindingOwnershipRecord()
    let publication = fixture.home.appending(
      path:
        ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce)).publishing-\(try #require(record.claimNonce))"
    )
    let alias = fixture.root.appending(path: "restored-claim-alias")
    let raced = Mutex(false)
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularRestorationClaimMetadataCopied {
          #expect(link(publication.path, alias.path) == 0)
          raced.withLock { $0 = true }
        }
      }
    )

    #expect(throws: SetupOwnershipError.self) { try transaction.restoreOriginalEntry() }
    #expect(raced.withLock { $0 })
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func validPendingRecoveryPreviewRunsLifecyclePreflight() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .updateGeneration,
        phase: .activating,
        generationID: generationID,
        previousGenerationID: generationID,
        generationCreated: false
      )
    )
    lifecycle.calls.withLock { $0.removeAll() }

    let execution = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )

    #expect(execution.succeeded)
    #expect(lifecycle.calls.withLock { $0 } == ["preflight"])
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

  @Test
  func mainCleanInstallOwnershipRecordRemainsApplicableAndTearsDown() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, json: true).succeeded)
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try removeExtendedAttribute(
      KeybindingProviderInspector.claimMarkerAttribute,
      at: entry,
      symbolicLink: true
    )
    let target = KeybindingProviderInspector.managedTarget
    let legacy = SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .applied,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(target.utf8)),
      linkDestination: target
    )
    try SetupOwnershipManager().persist(
      records: [legacy],
      context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
    )

    let reapplied = try fixture.execute(runner: runner, json: true)
    #expect(reapplied.succeeded)
    #expect(
      KeybindingProviderInspector().inspect(
        homeDirectory: fixture.home,
        stateRoot: fixture.stateRoot,
        generation: KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot)
      ).status == .managed
    )

    let teardown = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(teardown.status == .removed)
    #expect(!FileManager.default.fileExists(atPath: entry.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func teardownLockedFinalizesAuthenticatedRestorationAfterBackupDeletion() throws {
    enum Interrupted: Error { case afterBackupRemoval }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : resume finalization\n".utf8)
    try original.write(to: entry)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    let generationID = try #require(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).generationID
    )
    try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).write(
      KeybindingApplyTransaction(
        operation: .teardownEntry,
        phase: .restorationFinalizing,
        generationID: generationID,
        previousGenerationID: generationID,
        generationCreated: false
      )
    )
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .backupRemoved { throw Interrupted.afterBackupRemoval }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.finalizeOriginalRestoration() }
    #expect(try fixture.keybindingOwnershipRecord().phase == .teardownPrepared)

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(result.status == .none)
    #expect(try Data(contentsOf: entry) == original)
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test
  func restoredSymlinkPublishedBeforeIdentityRecordResumes() throws {
    enum Interrupted: Error { case afterPublication }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let source = fixture.home.appending(path: ".config/skhd/original.skhdrc")
    try Data("alt - x : symlink source\n".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: "original.skhdrc"
    )
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .restoredOriginalPublished { throw Interrupted.afterPublication }
      }
    )
    try interrupted.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }

    let resumed = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try resumed.restoreOriginalEntry()
    try resumed.finalizeOriginalRestoration()
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path) == "original.skhdrc")
  }

  @Test
  func restoredDirectorySymlinkPublishedBeforeIdentityRecordResumes() throws {
    enum Interrupted: Error { case afterPublication }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd")
    try FileManager.default.removeItem(at: skhd)
    let dotfiles = fixture.root.appending(path: "dotfiles/skhd")
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try Data("alt - x : directory source\n".utf8).write(
      to: dotfiles.appending(path: "skhdrc")
    )
    try FileManager.default.createSymbolicLink(
      atPath: skhd.path, withDestinationPath: dotfiles.path)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .restoredOriginalPublished { throw Interrupted.afterPublication }
      }
    )
    try interrupted.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }

    let resumed = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try resumed.restoreOriginalEntry()
    try resumed.finalizeOriginalRestoration()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == dotfiles.path)
  }

  @Test
  func cleanInstallRemovalClaimResumesAfterInterruption() throws {
    enum Interrupted: Error { case afterClaim }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .managedEntryClaimedForRemoval { throw Interrupted.afterClaim }
      }
    )
    try interrupted.installEntry(expectedEvidence: evidence, approvedEvidenceDigest: nil)
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }

    let resumed = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try resumed.restoreOriginalEntry()
    try resumed.finalizeOriginalRestoration()
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/skhd/skhdrc").path))
  }

  @Test
  func backupDeletionRacePreservesForeignReplacement() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : original\n".utf8).write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    try provider.restoreOriginalEntry()
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    let foreign = Data("foreign replacement\n".utf8)
    let raced = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        guard $0 == .deletionSourcePinned else { return }
        try foreign.write(to: backup, options: .atomic)
      }
    )

    #expect(throws: SetupOwnershipError.self) { try raced.finalizeOriginalRestoration() }
    #expect(try Data(contentsOf: backup) == foreign)
    #expect(try fixture.keybindingOwnershipRecord().phase == .teardownPrepared)
  }

  @Test
  func teardownFinalizationFailureAfterRestartRemainsRecoverableOnRestoredEntry() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : restored before finalization\n".utf8)
    try original.write(to: entry)
    let calls = Mutex<[String]>([])
    let armed = Mutex(false)
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    let alias = fixture.root.appending(path: "backup-hard-link")
    let lifecycle = KeybindingLifecycleController(
      preflight: { calls.withLock { $0.append("preflight") } },
      restart: { calls.withLock { $0.append("restart") } },
      reload: { calls.withLock { $0.append("reload") } },
      verifyProcess: {
        calls.withLock { $0.append("verify") }
        if armed.withLock({ value in
          defer { value = false }
          return value
        }) {
          guard link(backup.path, alias.path) == 0 else { throw POSIXError(.EIO) }
        }
      }
    )
    let runner = fixture.runner(lifecycle: lifecycle)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    calls.withLock { $0.removeAll() }
    armed.withLock { $0 = true }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: false
      )
    }

    #expect(calls.withLock { $0 } == ["preflight", "restart", "verify"])
    #expect(try Data(contentsOf: entry) == original)
    #expect(
      try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read()?.phase
        == .restorationFinalizing
    )
    #expect(try fixture.keybindingOwnershipRecord().phase == .teardownPrepared)

    try FileManager.default.removeItem(at: alias)
    calls.withLock { $0.removeAll() }
    let resumed = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(resumed.status == .none)
    #expect(calls.withLock { $0 }.isEmpty)
    #expect(try Data(contentsOf: entry) == original)
  }

  @Test
  func teardownDryRunRejectsMultiplyLinkedBackupWithoutMutation() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : backup preflight\n".utf8).write(to: entry)
    let lifecycle = LifecycleFixture()
    let runner = fixture.runner(lifecycle: lifecycle.controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)
    lifecycle.calls.withLock { $0.removeAll() }
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    let alias = fixture.root.appending(path: "backup-alias")
    #expect(link(backup.path, alias.path) == 0)

    #expect(throws: SetupOwnershipError.self) {
      _ = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: true
      )
    }

    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
  }

  @Test
  func symlinkReplacementDuringDisplacementIsSwappedBackAndPreserved() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let approved = fixture.home.appending(path: ".config/skhd/approved.skhdrc")
    let foreign = fixture.home.appending(path: ".config/skhd/foreign.skhdrc")
    try Data("alt - x : approved\n".utf8).write(to: approved)
    try Data("alt - x : foreign\n".utf8).write(to: foreign)
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: approved.lastPathComponent
    )
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        guard checkpoint == .sourceSwapCompleted else { return }
        let record = try fixture.keybindingOwnershipRecord()
        let claim = fixture.home.appending(
          path: ".config/skhd/.skhdrc.macarchy-keybindings-\(try #require(record.claimNonce))"
        )
        try FileManager.default.removeItem(at: claim)
        try FileManager.default.createSymbolicLink(
          atPath: claim.path,
          withDestinationPath: foreign.lastPathComponent
        )
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == foreign.lastPathComponent
    )
  }

  @Test
  func directorySymlinkReplacementDuringDisplacementIsSwappedBackAndPreserved() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let skhd = fixture.home.appending(path: ".config/skhd", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: skhd)
    let approved = fixture.root.appending(path: "dotfiles/approved-skhd")
    let foreign = fixture.root.appending(path: "dotfiles/foreign-skhd")
    for source in [approved, foreign] {
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try Data("alt - x : source\n".utf8).write(to: source.appending(path: "skhdrc"))
    }
    try FileManager.default.createSymbolicLink(
      atPath: skhd.path,
      withDestinationPath: approved.path
    )
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        guard checkpoint == .sourceSwapCompleted else { return }
        let record = try fixture.keybindingOwnershipRecord()
        let claim = fixture.home.appending(
          path: ".config/.skhd.macarchy-keybindings-\(try #require(record.claimNonce))"
        )
        try FileManager.default.removeItem(at: claim)
        try FileManager.default.createSymbolicLink(
          atPath: claim.path,
          withDestinationPath: foreign.path
        )
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: skhd.path) == foreign.path)
  }

  @Test
  func authenticatedPublishingResidueIsRemovedBeforeOwnershipRecord() throws {
    enum Interrupted: Error { case beforePublish }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let source = fixture.home.appending(path: ".config/skhd/original.skhdrc")
    try Data("alt - x : publishing residue\n".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: source.lastPathComponent
    )
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .providerPublicationAuthenticated { throw Interrupted.beforePublish }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let publication = fixture.home.appending(
      path:
        ".config/skhd/.skhdrc.macarchy-keybindings-\(nonce).publishing-\(nonce)"
    )
    var publicationMetadata = stat()
    #expect(lstat(publication.path, &publicationMetadata) == 0)

    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.restoreOriginalEntry()
    try provider.finalizeOriginalRestoration()

    #expect(!FileManager.default.fileExists(atPath: publication.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func deterministicDeletionResidueResumesBeforeFinalization() throws {
    enum Interrupted: Error { case afterRename }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let evidence = try fixture.adoptionEvidence()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: nil
    )
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let claim = ".skhdrc.macarchy-keybindings-\(nonce)"
    let residue = fixture.home.appending(
      path: ".config/skhd/.\(claim).deleting-\(nonce)"
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .deletionCandidatePublished { throw Interrupted.afterRename }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }
    var residueMetadata = stat()
    #expect(lstat(residue.path, &residueMetadata) == 0)

    let resumed = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try resumed.restoreOriginalEntry()
    try resumed.finalizeOriginalRestoration()

    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func displacedOriginalDeletionResidueIsAuthenticatedDuringAutomaticRollback() throws {
    enum Interrupted: Error { case afterRename }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : automatic rollback\n".utf8)
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
    let generation = try KeybindingGenerationActivator(stateRoot: fixture.stateRoot).stage(
      composition
    )
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    try store.write(
      KeybindingApplyTransaction(
        operation: .adoptEntry,
        phase: .staged,
        generationID: generation.manifest.generationID,
        previousGenerationID: nil,
        generationCreated: true
      )
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .deletionCandidatePublished { throw Interrupted.afterRename }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let claim = ".skhdrc.macarchy-keybindings-\(nonce)"
    let residue = fixture.home.appending(
      path: ".config/skhd/.\(claim).deleting-\(nonce)"
    )
    #expect(FileManager.default.fileExists(atPath: residue.path))

    let lifecycle = LifecycleFixture()
    let execution = try fixture.execute(
      runner: fixture.runner(lifecycle: lifecycle.controller),
      adoptionEvidence: nil,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(try jsonObject(execution.output)["outcome"] as? String == "blocked")
    #expect(try Data(contentsOf: entry) == original)
    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(try store.read() == nil)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
    #expect(lifecycle.calls.withLock { $0 }.isEmpty)
  }

  @Test
  func deletionCandidateReplacementAfterAuthenticationIsNeverUnlinked() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : final deletion race\n".utf8).write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let provider = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try provider.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    try provider.restoreOriginalEntry()
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    let residue = backup.deletingLastPathComponent().appending(
      path: ".keybindings-skhdrc.deleting-\(nonce)"
    )
    let foreign = Data("foreign final deletion replacement\n".utf8)
    let raced = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        guard $0 == .deletionCandidateAuthenticated else { return }
        try foreign.write(to: residue, options: .atomic)
      }
    )

    #expect(throws: SetupOwnershipError.self) { try raced.finalizeOriginalRestoration() }
    #expect(try Data(contentsOf: backup) == foreign)
    #expect(try fixture.keybindingOwnershipRecord().phase == .teardownPrepared)
  }

  @Test
  func regularAdoptionAtExtendedAttributeCountLimitRestores() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : exact xattr count\n".utf8).write(to: entry)
    let existingCount = try extendedAttributeNames(at: entry).count
    for index in 0..<(SetupOwnershipManager.maximumExtendedAttributeCount - existingCount) {
      try setExtendedAttribute("com.macarchy.boundary.\(index)", value: "x", at: entry)
    }
    #expect(
      try extendedAttributeNames(at: entry).count
        == SetupOwnershipManager.maximumExtendedAttributeCount
    )
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .removed)
    #expect(
      try extendedAttributeNames(at: entry).count
        == SetupOwnershipManager.maximumExtendedAttributeCount
    )
  }

  @Test
  func regularAdoptionAtExtendedAttributeAggregateLimitRestores() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : exact xattr aggregate\n".utf8).write(to: entry)
    let names = (0..<4).map { "com.macarchy.aggregate.\($0)" }
    let existingSize = try extendedAttributeAggregateSize(at: entry)
    var remaining =
      SetupOwnershipManager.maximumExtendedAttributeAggregateSize
      - existingSize
      - names.reduce(0) { $0 + $1.utf8.count + 1 }
    for name in names {
      let count = min(remaining, SetupOwnershipManager.maximumExtendedAttributeValueSize)
      try setExtendedAttribute(name, data: Data(repeating: 0x61, count: count), at: entry)
      remaining -= count
    }
    #expect(remaining == 0)
    #expect(
      try extendedAttributeAggregateSize(at: entry)
        == SetupOwnershipManager.maximumExtendedAttributeAggregateSize
    )
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(try fixture.execute(runner: runner, adopt: true, json: true).succeeded)

    let result = try runner.teardownLocked(
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      dryRun: false
    )

    #expect(result.status == .removed)
  }

  @Test
  func regularAdoptionRejectsExcessiveExtendedAttributeCount() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : xattrs\n".utf8).write(to: entry)
    for index in 0...SetupOwnershipManager.maximumExtendedAttributeCount {
      try setExtendedAttribute("com.macarchy.count.\(index)", value: "x", at: entry)
    }
    let evidence = try fixture.adoptionEvidence()

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).preflightInstall(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "state/setup/ownership.json").path))
  }

  @Test
  func regularAdoptionRejectsOversizedExtendedAttributeBeforeAllocatingIt() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try Data("alt - x : xattr value\n".utf8).write(to: entry)
    let value = Data(
      repeating: 0x61,
      count: SetupOwnershipManager.maximumExtendedAttributeValueSize + 1
    )
    try setExtendedAttribute("com.macarchy.oversized", data: value, at: entry)
    let evidence = try fixture.adoptionEvidence()

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).preflightInstall(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateRoot.appending(path: "state/setup/ownership.json").path))
  }

  @Test
  func authenticatedBackupPublicationResidueResumesFromPersistedNonce() throws {
    enum Interrupted: Error { case beforePublication }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : backup publication\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .backupPublicationReady { throw Interrupted.beforePublication }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let backup = fixture.stateRoot.appending(path: "state/setup/backups/keybindings-skhdrc")
    let residue = backup.deletingLastPathComponent().appending(
      path: "keybindings-skhdrc.publishing-\(nonce)"
    )
    #expect(try Data(contentsOf: residue) == original)
    #expect(!FileManager.default.fileExists(atPath: backup.path))

    try KeybindingProviderTransaction(homeDirectory: fixture.home).installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )

    #expect(try Data(contentsOf: backup) == original)
    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
  }

  @Test
  func authenticatedPartialBackupPublicationIsRemovedDuringRollback() throws {
    enum Interrupted: Error { case afterAuthentication }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : partial backup\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .backupPublicationAuthenticated { throw Interrupted.afterAuthentication }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try interrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let residue = fixture.stateRoot.appending(
      path: "state/setup/backups/keybindings-skhdrc.publishing-\(nonce)"
    )
    #expect(FileManager.default.fileExists(atPath: residue.path))

    let resumed = KeybindingProviderTransaction(homeDirectory: fixture.home)
    try resumed.preflightOriginalRestoration()
    try resumed.restoreOriginalEntry()
    try resumed.finalizeOriginalRestoration()

    #expect(try Data(contentsOf: entry) == original)
    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func backupPublicationDeletionResidueResumesBeforeOwnershipFinalization() throws {
    enum Interrupted: Error {
      case afterAuthentication
      case afterDeletionRename
    }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : publication deletion residue\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let publicationInterrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .backupPublicationAuthenticated { throw Interrupted.afterAuthentication }
      }
    )
    #expect(throws: SetupOwnershipTransactionError.self) {
      try publicationInterrupted.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let deletionInterrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .deletionCandidatePublished { throw Interrupted.afterDeletionRename }
      }
    )
    #expect(throws: Interrupted.self) {
      try deletionInterrupted.finalizeOriginalRestoration()
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let publication = "keybindings-skhdrc.publishing-\(nonce)"
    let residue = fixture.stateRoot.appending(
      path: "state/setup/backups/.\(publication).deleting-\(nonce)"
    )
    #expect(FileManager.default.fileExists(atPath: residue.path))
    #expect(record.phase == .teardownPrepared)

    try KeybindingProviderTransaction(homeDirectory: fixture.home)
      .finalizeOriginalRestoration()

    #expect(try Data(contentsOf: entry) == original)
    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func backupPublicationReplacementBeforeRenameIsPreservedAndBlocks() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : pinned backup publication\n".utf8)
    let foreign = Data("foreign backup publication\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        guard checkpoint == .backupPublicationReady else { return }
        let record = try fixture.keybindingOwnershipRecord()
        let nonce = try #require(record.claimNonce)
        let residue = fixture.stateRoot.appending(
          path: "state/setup/backups/keybindings-skhdrc.publishing-\(nonce)"
        )
        try foreign.write(to: residue, options: .atomic)
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let residue = fixture.stateRoot.appending(
      path: "state/setup/backups/keybindings-skhdrc.publishing-\(nonce)"
    )
    #expect(try Data(contentsOf: residue) == foreign)
    #expect(try Data(contentsOf: entry) == original)
  }

  @Test
  func legacyRollbackResumesDeterministicReplacementLink() throws {
    enum Interrupted: Error { case afterCreation }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installLegacyCleanEntry()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .legacyRestorationPublicationCreated { throw Interrupted.afterCreation }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreManagedEntry() }
    let residue = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-legacy-restoration"
    )
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: residue.path)
        == KeybindingProviderInspector.managedTarget
    )

    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreManagedEntry()

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        == KeybindingProviderInspector.managedTarget
    )
    #expect(!FileManager.default.fileExists(atPath: residue.path))
  }

  @Test
  func legacyRollbackPreservesForeignReplacementOfDeterministicResidue() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installLegacyCleanEntry()
    try KeybindingProviderTransaction(homeDirectory: fixture.home).restoreOriginalEntry()
    let residue = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-legacy-restoration"
    )
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        guard checkpoint == .legacyRestorationPublicationCreated else { return }
        try FileManager.default.removeItem(at: residue)
        try FileManager.default.createSymbolicLink(
          atPath: residue.path,
          withDestinationPath: "foreign-target"
        )
      }
    )

    #expect(throws: SetupOwnershipError.self) { try transaction.restoreManagedEntry() }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: residue.path) == "foreign-target"
    )
    #expect(!FileManager.default.fileExists(atPath: entry.path))
  }

  @Test
  func legacyRestorationDeletionResidueResumesDuringFinalization() throws {
    enum Interrupted: Error { case afterDeletionRename }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installLegacyCleanEntry()
    let publication = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-legacy-restoration"
    )
    try FileManager.default.createSymbolicLink(
      atPath: publication.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .deletionCandidatePublished { throw Interrupted.afterDeletionRename }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }
    let residue = fixture.home.appending(
      path:
        ".config/skhd/..skhdrc.macarchy-legacy-restoration.deleting-legacy-clean-install"
    )
    #expect(!FileManager.default.fileExists(atPath: publication.path))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: residue.path)
        == KeybindingProviderInspector.managedTarget
    )
    try FileManager.default.removeItem(at: entry)

    try KeybindingProviderTransaction(homeDirectory: fixture.home)
      .finalizeOriginalRestoration()

    #expect(!FileManager.default.fileExists(atPath: residue.path))
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  @Test
  func legacyRestorationForeignDeletionResidueBlocksFinalization() throws {
    enum Interrupted: Error { case afterDeletionRename }
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installLegacyCleanEntry()
    let publication = fixture.home.appending(
      path: ".config/skhd/.skhdrc.macarchy-legacy-restoration"
    )
    try FileManager.default.createSymbolicLink(
      atPath: publication.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: {
        if $0 == .deletionCandidatePublished { throw Interrupted.afterDeletionRename }
      }
    )
    #expect(throws: Interrupted.self) { try interrupted.restoreOriginalEntry() }
    let residue = fixture.home.appending(
      path:
        ".config/skhd/..skhdrc.macarchy-legacy-restoration.deleting-legacy-clean-install"
    )
    try FileManager.default.removeItem(at: residue)
    try FileManager.default.createSymbolicLink(
      atPath: residue.path,
      withDestinationPath: "foreign-target"
    )
    try FileManager.default.removeItem(at: entry)

    #expect(throws: SetupOwnershipError.self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home)
        .finalizeOriginalRestoration()
    }

    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: residue.path) == "foreign-target"
    )
    #expect(try fixture.keybindingOwnershipRecord().id == KeybindingProviderInspector.ownershipID)
  }

  @Test
  func regularCaptureUsesPinnedModeAfterPathInspectionRace() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : mode race\n".utf8)
    try original.write(to: entry)
    #expect(chmod(entry.path, 0o600) == 0)
    let evidence = try fixture.adoptionEvidence()
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularPathInspected {
          guard chmod(entry.path, 0o740) == 0 else { throw POSIXError(.EIO) }
        }
      }
    )

    try transaction.installEntry(
      expectedEvidence: evidence,
      approvedEvidenceDigest: evidence.digest
    )
    #expect(try fixture.keybindingOwnershipRecord().originalFileMode == 0o740)
    try transaction.restoreOriginalEntry()
    try transaction.finalizeOriginalRestoration()
    var metadata = stat()
    #expect(lstat(entry.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o7777 == 0o740)
  }

  @Test
  func regularCapturePathReplacementBeforePreparedPersistenceBlocks() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    let original = Data("alt - x : capture race\n".utf8)
    try original.write(to: entry)
    let evidence = try fixture.adoptionEvidence()
    var before = stat()
    #expect(lstat(entry.path, &before) == 0)
    let transaction = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { checkpoint in
        if checkpoint == .regularCaptureReady {
          try original.write(to: entry, options: .atomic)
        }
      }
    )

    #expect(throws: SetupOwnershipTransactionError.self) {
      try transaction.installEntry(
        expectedEvidence: evidence,
        approvedEvidenceDigest: evidence.digest
      )
    }
    var after = stat()
    #expect(lstat(entry.path, &after) == 0)
    #expect(after.st_ino != before.st_ino)
    #expect(try Data(contentsOf: entry) == original)
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
    try setExtendedAttribute(name, data: Data(value.utf8), at: url)
  }

  private func setExtendedAttribute(_ name: String, data: Data, at url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
      url.path.withCString { path in
        name.withCString { attribute in
          Darwin.setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private func removeExtendedAttribute(_ name: String, at url: URL, symbolicLink: Bool) throws {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | (symbolicLink ? O_SYMLINK : O_NOFOLLOW) | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }
    let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
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

  private func extendedAttributeNames(at url: URL) throws -> [String] {
    let size = url.path.withCString { Darwin.listxattr($0, nil, 0, 0) }
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var names = [CChar](repeating: 0, count: size)
    let count = url.path.withCString { Darwin.listxattr($0, &names, names.count, 0) }
    guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return names.prefix(count).map { UInt8(bitPattern: $0) }.split(separator: 0).map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  private func extendedAttributeAggregateSize(at url: URL) throws -> Int {
    let names = try extendedAttributeNames(at: url)
    return try names.reduce(names.reduce(0) { $0 + $1.utf8.count + 1 }) { total, name in
      let size = url.path.withCString { path in
        name.withCString { Darwin.getxattr(path, $0, nil, 0, 0, 0) }
      }
      guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return total + size
    }
  }
}

private final class LifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])

  var controller: KeybindingLifecycleController {
    KeybindingLifecycleController(
      preflight: { self.calls.withLock { $0.append("preflight") } },
      restart: { self.calls.withLock { $0.append("restart") } },
      reload: { self.calls.withLock { $0.append("reload") } },
      verifyProcess: { self.calls.withLock { $0.append("verify") } },
      inspectProcess: { .testRunning }
    )
  }
}

#if MACARCHY_ACCEPTANCE_TESTING
  private struct AcceptanceCheckpointObservation: Sendable {
    let selectedGenerationID: String
    let currentGenerationID: String?
    let transactionGenerationID: String?
    let transactionPhase: KeybindingApplyPhase?
    let lifecycleEvidenceExists: Bool
    let lifecycleStatus: KeybindingLifecycleEvidenceStatus
  }
#endif

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
      lifecycle: KeybindingLifecycleController(
        preflight: lifecycle.preflight,
        restart: lifecycle.restart,
        reload: lifecycle.reload,
        verifyProcess: lifecycle.verifyProcess,
        inspectProcess: { .testRunning }
      )
    )
  }

  func installLegacyCleanEntry() throws -> URL {
    let entry = home.appending(path: ".config/skhd/skhdrc")
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let record = SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .applied,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(KeybindingProviderInspector.managedTarget.utf8)),
      linkDestination: KeybindingProviderInspector.managedTarget
    )
    try SetupOwnershipManager().persist(
      records: [record],
      context: SetupOwnershipManager.Context(homeDirectory: home)
    )
    return entry
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
