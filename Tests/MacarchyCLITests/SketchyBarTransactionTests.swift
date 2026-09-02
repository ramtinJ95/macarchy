import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct SketchyBarTransactionTests {
  @Test
  func interruptedAdoptionRestoresTheExactRegularFileInode() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal bar\n")
    var original = stat()
    #expect(lstat(entry.path, &original) == 0)
    let digest = try fixture.adoptionDigest()
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .providerChanged { throw SketchyBarInterruptionError.injected }
    }

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: digest
      )
    }
    let storedTransaction = try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    let pending = try #require(storedTransaction)
    let retained = try #require(pending.ownership.retainedOriginalPath)
    var retainedMetadata = stat()
    #expect(lstat(retained, &retainedMetadata) == 0)
    #expect(retainedMetadata.st_dev == original.st_dev)
    #expect(retainedMetadata.st_ino == original.st_ino)

    try transaction.recoverApply(pending)

    var restored = stat()
    #expect(lstat(entry.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal bar\n")
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func adoptsAndAuthenticatesAnEntrySymlinkWithoutRecreatingIt() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "personal/sketchybarrc")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "personal symlink bar\n".write(to: source, atomically: true, encoding: .utf8)
    let entry = try fixture.installEntrySymlink(target: source.path)
    var original = stat()
    #expect(lstat(entry.path, &original) == 0)

    let first = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: try fixture.adoptionDigest()
    )
    let storedOwnership = try SketchyBarOwnershipStore(stateRoot: fixture.state).read()
    let ownership = try #require(storedOwnership)
    let retained = try #require(ownership.retainedOriginalPath)
    var retainedMetadata = stat()
    #expect(lstat(retained, &retainedMetadata) == 0)
    #expect(retainedMetadata.st_dev == original.st_dev)
    #expect(retainedMetadata.st_ino == original.st_ino)
    #expect(try fixture.linkTarget(URL(filePath: retained)) == source.path)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .current)

    let second = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: nil
    )
    fixture.lifecycle.replaceProcess()
    let refreshed = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: nil
    )
    #expect(first.changed)
    #expect(!second.changed)
    #expect(second.generationID == first.generationID)
    #expect(refreshed.changed)
    #expect(refreshed.generationID == first.generationID)
  }

  @Test
  func adoptsTheMultiFileDirectorySymlinkWithoutCopyingOrWalkingItsTree() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let personal = fixture.root.appending(path: "dotfiles/sketchybar", directoryHint: .isDirectory)
    let nested = personal.appending(path: "helpers/private", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "personal lua entry\n".write(
      to: personal.appending(path: "sketchybarrc"),
      atomically: true,
      encoding: .utf8
    )
    try Data([0, 1, 2, 3]).write(to: nested.appending(path: "opaque.bin"))
    try "return {}\n".write(
      to: personal.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
    }
    let directory = try fixture.installDirectorySymlink(target: "../../dotfiles/sketchybar")
    var original = stat()
    #expect(lstat(directory.path, &original) == 0)
    let inventoryBefore = try FileManager.default.contentsOfDirectory(atPath: personal.path)
      .sorted()

    _ = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: try fixture.adoptionDigest()
    )

    let storedOwnership = try SketchyBarOwnershipStore(stateRoot: fixture.state).read()
    let ownership = try #require(storedOwnership)
    let retained = try #require(ownership.retainedOriginalPath)
    var retainedMetadata = stat()
    #expect(lstat(retained, &retainedMetadata) == 0)
    #expect(retainedMetadata.st_dev == original.st_dev)
    #expect(retainedMetadata.st_ino == original.st_ino)
    #expect(try fixture.linkTarget(URL(filePath: retained)) == "../../dotfiles/sketchybar")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: personal.path).sorted()
        == inventoryBefore
    )

    try "drift\n".write(
      to: personal.appending(path: "added-after-adoption"),
      atomically: true,
      encoding: .utf8
    )
    let provider = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: fixture.home,
      stateRoot: fixture.state,
      enabled: true,
      generation: SketchyBarGenerationInspector(stateRoot: fixture.state).inspect()
    )
    #expect(provider.status == .blocked)
    #expect(provider.ownership == "uninspectable")
    #expect(provider.message.contains("source inventory drifted"))
  }

  @Test
  func interruptedPublicationIsRecoveredBeforeProviderMutation() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("untouched\n")
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .generationPublished { throw SketchyBarInterruptionError.injected }
    }

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }
    let storedTransaction = try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    let pending = try #require(storedTransaction)
    let published = fixture.state.appending(
      path: "desktop/sketchybar/generations/\(pending.generationID)",
      directoryHint: .isDirectory
    )
    let selectionResidue = fixture.state.appending(
      path: "desktop/sketchybar/.current-\(pending.generationID)"
    )
    try FileManager.default.createSymbolicLink(
      atPath: selectionResidue.path,
      withDestinationPath: "generations/\(pending.generationID)"
    )
    #expect(FileManager.default.fileExists(atPath: published.path))
    #expect(try String(contentsOf: entry, encoding: .utf8) == "untouched\n")

    try transaction.recoverApply(pending)

    #expect(!FileManager.default.fileExists(atPath: published.path))
    var missing = stat()
    #expect(lstat(selectionResidue.path, &missing) != 0 && errno == ENOENT)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "untouched\n")
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func adoptionRequiresTheCurrentReviewedDigest() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal\n")

    #expect(throws: SketchyBarDesktopError.self) {
      try fixture.transaction().convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: "sha256:not-reviewed"
      )
    }
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal\n")
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func retainedDirectorySymlinkRecoversBeforeManagedDirectoryCreation() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let personal = fixture.root.appending(path: "dotfiles/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    try "personal\n".write(
      to: personal.appending(path: "sketchybarrc"),
      atomically: true,
      encoding: .utf8
    )
    let directory = try fixture.installDirectorySymlink(target: "../../dotfiles/sketchybar")
    var original = stat()
    #expect(lstat(directory.path, &original) == 0)
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .originalRetained { throw SketchyBarInterruptionError.injected }
    }

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }
    var missing = stat()
    #expect(lstat(directory.path, &missing) != 0 && errno == ENOENT)
    let pending = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )

    try transaction.recoverApply(pending)

    var restored = stat()
    #expect(lstat(directory.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(try fixture.linkTarget(directory) == "../../dotfiles/sketchybar")
  }

  @Test
  func foreignManagedDirectoryContentsBlockRecoveryWithoutDeletion() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let personal = fixture.root.appending(path: "dotfiles/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    try "personal\n".write(
      to: personal.appending(path: "sketchybarrc"),
      atomically: true,
      encoding: .utf8
    )
    _ = try fixture.installDirectorySymlink(target: "../../dotfiles/sketchybar")
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .providerChanged { throw SketchyBarInterruptionError.injected }
    }
    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }
    let foreign = fixture.home.appending(path: ".config/sketchybar/foreign")
    try "keep\n".write(to: foreign, atomically: true, encoding: .utf8)
    let pending = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )

    #expect(throws: SketchyBarDesktopError.self) {
      try transaction.recoverApply(pending)
    }

    #expect(try String(contentsOf: foreign, encoding: .utf8) == "keep\n")
    var retained = stat()
    #expect(lstat(pending.ownership.retainedOriginalPath!, &retained) == 0)
    #expect(SketchyBarTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func postRenameSourceDriftRestoresTheDisplacedSymlinkAndGeneration() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "personal/sketchybarrc")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "before\n".write(to: source, atomically: true, encoding: .utf8)
    let entry = try fixture.installEntrySymlink(target: source.path)
    var original = stat()
    #expect(lstat(entry.path, &original) == 0)
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .originalRetained {
        try "after\n".write(to: source, atomically: true, encoding: .utf8)
      }
    }

    #expect(throws: SketchyBarDesktopError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }

    var restored = stat()
    #expect(lstat(entry.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(try fixture.linkTarget(entry) == source.path)
    #expect(try String(contentsOf: source, encoding: .utf8) == "after\n")
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func interruptedAbsentInstallRemovesOnlyItsCreatedDirectory() throws {
    for interruption in [
      SketchyBarTransactionCheckpoint.configurationDirectoryCreated,
      .providerChanged,
    ] {
      let fixture = try SketchyBarTransactionFixture(serviceRunning: false)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let transaction = fixture.transaction { checkpoint in
        if checkpoint == interruption { throw SketchyBarInterruptionError.injected }
      }

      #expect(throws: SketchyBarInterruptionError.self) {
        try transaction.convergeLocked(
          composition: fixture.composition,
          adoptionEvidenceDigest: nil
        )
      }
      let pending = try #require(
        try SketchyBarTransactionStore(stateRoot: fixture.state).read()
      )

      try transaction.recoverApply(pending)

      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.home.appending(path: ".config/sketchybar").path))
    }
  }

  @Test
  func interruptedManagedUpdateRestoresPreviousGenerationAndOwnership() throws {
    let fixture = try SketchyBarTransactionFixture(serviceRunning: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: nil
    )
    let previousOwnership = try #require(
      try SketchyBarOwnershipStore(stateRoot: fixture.state).read()
    )
    let updatedComposition = try fixture.composition(
      profile: """
        schema_version = 1
        [desktop]
        provider = "disabled"
        """
    )
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .generationSelected { throw SketchyBarInterruptionError.injected }
    }

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: updatedComposition,
        adoptionEvidenceDigest: nil
      )
    }
    let pending = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )
    #expect(pending.generationID != first.generationID)

    try transaction.recoverApply(pending)

    #expect(
      SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().generationID
        == first.generationID
    )
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == previousOwnership)
  }

  @Test
  func malformedTransactionPathsAreRejectedBeforeRecovery() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal\n")
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .generationPublished { throw SketchyBarInterruptionError.injected }
    }
    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }
    let transactionURL = fixture.state.appending(path: "desktop/sketchybar/transaction.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: transactionURL)) as? [String: Any]
    )
    var ownership = try #require(json["ownership"] as? [String: Any])
    var original = try #require(ownership["original"] as? [String: Any])
    original["public_path"] = "/tmp/not-sketchybar"
    ownership["original"] = original
    json["ownership"] = ownership
    try JSONSerialization.data(withJSONObject: json).write(to: transactionURL, options: .atomic)

    let malformed = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )
    #expect(throws: SketchyBarDesktopError.self) { try transaction.recoverApply(malformed) }
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal\n")
  }

  @Test
  func staleLifecycleEvidenceBlocksBeforeTransactionMutation() throws {
    let fixture = try SketchyBarTransactionFixture(serviceRunning: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: nil
    )
    let lifecycleStore = SketchyBarLifecycleEvidenceStore(stateRoot: fixture.state)
    let evidence = try #require(try lifecycleStore.read())
    try lifecycleStore.write(
      SketchyBarLifecycleEvidence(
        generationID: "s-00000000-0000-0000-0000-000000000000",
        runtime: evidence.runtime,
        coreRuntime: evidence.coreRuntime
      )
    )

    #expect(throws: SketchyBarDesktopError.self) {
      try fixture.transaction().convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: nil
      )
    }

    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(
      SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().generationID
        == first.generationID
    )
  }

  @Test
  func runningServiceWithoutAnOriginalConfigurationBlocksBeforeMutation() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: SketchyBarDesktopError.self) {
      try fixture.transaction().convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: nil
      )
    }

    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
  }

  @Test
  func failedReloadRestoresTheOriginalEntryBeforeReloadingIt() throws {
    let fixture = try SketchyBarTransactionFixture(failedReloads: 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal\n")

    #expect(throws: SketchyBarLifecycleTestError.self) {
      try fixture.transaction().convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }

    #expect(fixture.lifecycle.reloadEntryStates == ["managed", "personal"])
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal\n")
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(try SketchyBarLifecycleEvidenceStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func failedCoreRuntimeVerificationRestoresTheOriginalBeforeReloadingIt() throws {
    let fixture = try SketchyBarTransactionFixture(coreRuntimeStatus: .drifted)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal\n")

    #expect(throws: SketchyBarDesktopError.self) {
      try fixture.transaction().convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: try fixture.adoptionDigest()
      )
    }

    #expect(fixture.lifecycle.reloadEntryStates == ["managed", "personal"])
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal\n")
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
    #expect(try SketchyBarLifecycleEvidenceStore(stateRoot: fixture.state).read() == nil)
  }

  @Test
  func partialHookRuntimeRequiresPersistableEvidence() throws {
    for hookItemCount in [0, 62] {
      let fixture = try SketchyBarTransactionFixture(
        serviceRunning: false,
        coreRuntimeStatus: .partial,
        hookItemCount: hookItemCount
      )
      defer { try? FileManager.default.removeItem(at: fixture.root) }

      if hookItemCount == 0 {
        let result = try fixture.transaction().convergeLocked(
          composition: fixture.composition,
          adoptionEvidenceDigest: nil
        )
        let evidence = try #require(
          try SketchyBarLifecycleEvidenceStore(stateRoot: fixture.state).read()
        )
        #expect(result.changed)
        #expect(evidence.coreRuntime.status == .partial)
      } else {
        #expect(throws: SketchyBarDesktopError.self) {
          try fixture.transaction().convergeLocked(
            composition: fixture.composition,
            adoptionEvidenceDigest: nil
          )
        }
        #expect(try SketchyBarLifecycleEvidenceStore(stateRoot: fixture.state).read() == nil)
      }
    }
  }

  @Test
  func interruptedStartIsStoppedAfterFilesystemRecovery() throws {
    let fixture = try SketchyBarTransactionFixture(serviceRunning: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .serviceChanged { throw SketchyBarInterruptionError.injected }
    }

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: fixture.composition,
        adoptionEvidenceDigest: nil
      )
    }
    let pending = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )
    #expect(fixture.lifecycle.events == ["start"])

    try transaction.recoverApply(pending)

    #expect(fixture.lifecycle.events == ["start", "stop"])
    #expect(fixture.lifecycle.stopSnapshots == ["missing/no-current"])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.home.appending(path: ".config/sketchybar").path
      )
    )
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func interruptedTeardownContinuesForwardFromTheRestoredOriginal() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = try fixture.installRegularEntry("personal\n")
    var original = stat()
    #expect(lstat(entry.path, &original) == 0)
    let transaction = fixture.transaction { checkpoint in
      if checkpoint == .generationDeselected { throw SketchyBarInterruptionError.injected }
    }
    _ = try transaction.convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: try fixture.adoptionDigest()
    )

    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.teardownLocked(dryRun: false)
    }
    let pending = try #require(
      try SketchyBarTransactionStore(stateRoot: fixture.state).read()
    )
    #expect(pending.operation == .teardown)
    #expect(pending.phase == .serviceChanged)
    #expect(try String(contentsOf: entry, encoding: .utf8) == "personal\n")
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
    try SketchyBarGenerationActivator(stateRoot: fixture.state).removeTransactionResidue(
      pending.generationID
    )

    let resumed = try fixture.transaction().teardownLocked(dryRun: false)

    var restored = stat()
    #expect(resumed.changed)
    #expect(lstat(entry.path, &restored) == 0)
    #expect(restored.st_dev == original.st_dev)
    #expect(restored.st_ino == original.st_ino)
    #expect(fixture.lifecycle.reloadEntryStates == ["managed", "personal", "personal"])
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(SketchyBarGenerationInspector(stateRoot: fixture.state).inspect().status == .missing)
    #expect(!SketchyBarTransactionStore(stateRoot: fixture.state).exists)
  }

  @Test
  func teardownRestartsAnOriginallyRunningServiceThatStoppedLater() throws {
    let fixture = try SketchyBarTransactionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.installRegularEntry("personal\n")
    _ = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: try fixture.adoptionDigest()
    )
    try fixture.lifecycle.controller.stop()

    _ = try fixture.transaction().teardownLocked(dryRun: false)

    #expect(fixture.lifecycle.isRunning)
  }

  @Test
  func teardownRemovesEveryManagedSketchyBarGeneration() throws {
    let fixture = try SketchyBarTransactionFixture(serviceRunning: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.transaction().convergeLocked(
      composition: fixture.composition,
      adoptionEvidenceDigest: nil
    )
    let updated = try fixture.composition(
      profile: """
        schema_version = 1
        [desktop]
        provider = "disabled"
        """
    )
    _ = try fixture.transaction().convergeLocked(
      composition: updated,
      adoptionEvidenceDigest: nil
    )
    let generations = fixture.state.appending(path: "desktop/sketchybar/generations")
    #expect(try FileManager.default.contentsOfDirectory(atPath: generations.path).count == 2)
    let invalid = generations.appending(
      path: "s-00000000-0000-0000-0000-000000000000",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) {
      try fixture.transaction().teardownLocked(dryRun: true)
    }
    try FileManager.default.removeItem(at: invalid)

    _ = try fixture.transaction().teardownLocked(dryRun: false)

    #expect(!FileManager.default.fileExists(atPath: generations.path))
  }
}

private struct SketchyBarTransactionFixture {
  let root: URL
  let home: URL
  let state: URL
  let composition: SketchyBarComposition
  let lifecycle: SketchyBarLifecycleFixture
  let coreRuntime: SketchyBarCoreRuntimeInspection

  init(
    serviceRunning: Bool = true,
    failedReloads: Int = 0,
    coreRuntimeStatus: SketchyBarCoreRuntimeStatus = .converged,
    hookItemCount: Int = 0
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-transaction-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    lifecycle = SketchyBarLifecycleFixture(
      running: serviceRunning,
      failedReloads: failedReloads,
      entry: home.appending(path: ".config/sketchybar/sketchybarrc"),
      current: state.appending(path: "desktop/sketchybar/current")
    )
    coreRuntime = SketchyBarCoreRuntimeInspection(
      status: coreRuntimeStatus,
      message: coreRuntimeStatus == .converged ? "converged" : "runtime drift",
      themeGenerationID: "g-00000000-0000-0000-0000-000000000000",
      barColor: "0xf01e1e2e",
      items: (["macarchy.clock", "macarchy.space.1", "macarchy.theme.ready"]
        + (0..<hookItemCount).map { "personal.\($0)" }).sorted(),
      spaceIndices: [1],
      clockLabelPresent: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let profileText: String
    if coreRuntimeStatus == .partial {
      try "# trusted\n".write(
        to: root.appending(path: "hook.sh"),
        atomically: true,
        encoding: .utf8
      )
      profileText = "schema_version = 1\n[sketchybar]\nhook = \"hook.sh\"\n"
    } else {
      profileText = "schema_version = 1\n"
    }
    let profile = try PortableProfileLoader().decode(
      profileText,
      source: root.appending(path: "profile.toml")
    )
    composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml"),
      profile: profile,
      stateRoot: state
    )
  }

  func transaction(
    faultInjector: @escaping @Sendable (SketchyBarTransactionCheckpoint) throws -> Void = { _ in }
  ) -> SketchyBarProviderTransaction {
    SketchyBarProviderTransaction(
      homeDirectory: home,
      stateRoot: state,
      lifecycle: lifecycle.controller,
      coreRuntime: SketchyBarCoreRuntimeController(
        inspect: { _ in self.coreRuntime },
        settle: { _ in self.coreRuntime },
        settleRestored: { $0.agreesWithProviderRuntime(self.coreRuntime) }
      ),
      faultInjector: faultInjector
    )
  }

  func composition(profile: String) throws -> SketchyBarComposition {
    let decoded = try PortableProfileLoader().decode(
      profile,
      source: root.appending(path: "updated-profile.toml")
    )
    return try SketchyBarConfigurationComposer().compose(
      defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml"),
      profile: decoded,
      stateRoot: state
    )
  }

  func installRegularEntry(_ contents: String) throws -> URL {
    let entry = try configurationEntry()
    try contents.write(to: entry, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: entry.path)
    return entry
  }

  func installEntrySymlink(target: String) throws -> URL {
    let entry = try configurationEntry()
    try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
    return entry
  }

  func installDirectorySymlink(target: String) throws -> URL {
    let configuration = home.appending(path: ".config/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: configuration.path,
      withDestinationPath: target
    )
    return configuration
  }

  func adoptionDigest() throws -> String {
    let inspection = SketchyBarProviderPlanInspector().inspect(
      homeDirectory: home,
      stateRoot: state,
      enabled: true,
      generation: SketchyBarGenerationInspector(stateRoot: state).inspect()
    )
    return try #require(inspection.adoptionEvidenceDigest)
  }

  func linkTarget(_ url: URL) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { throw POSIXError(.EIO) }
    return String(
      decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )
  }

  private func configurationEntry() throws -> URL {
    let configuration = home.appending(path: ".config/sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    return configuration.appending(path: "sketchybarrc")
  }
}

private enum SketchyBarLifecycleTestError: Error {
  case reload
}

private final class SketchyBarLifecycleFixture: Sendable {
  private struct State: Sendable {
    var running: Bool
    var failedReloads: Int
    var processID: Int32 = 123
    var events: [String] = []
    var reloadEntryStates: [String] = []
    var stopSnapshots: [String] = []
  }

  private let state: Mutex<State>
  private let entry: URL
  private let current: URL

  init(running: Bool, failedReloads: Int, entry: URL, current: URL) {
    state = Mutex(State(running: running, failedReloads: failedReloads))
    self.entry = entry
    self.current = current
  }

  var controller: SketchyBarLifecycleController {
    SketchyBarLifecycleController(
      inspect: {
        self.state.withLock { $0.running ? Self.runtime(processID: $0.processID) : .stopped }
      },
      preflight: { self.state.withLock { $0.running } },
      reload: { url in
        let entryState = Self.entryState(url)
        return try self.state.withLock {
          $0.events.append("reload")
          $0.reloadEntryStates.append(entryState)
          if $0.failedReloads > 0 {
            $0.failedReloads -= 1
            throw SketchyBarLifecycleTestError.reload
          }
          guard $0.running else { throw SketchyBarLifecycleTestError.reload }
          return Self.runtime(processID: $0.processID)
        }
      },
      start: {
        self.state.withLock {
          $0.events.append("start")
          $0.running = true
          return Self.runtime(processID: $0.processID)
        }
      },
      stop: {
        let currentState = Self.exists(self.current) ? "current" : "no-current"
        let snapshot = "\(Self.entryState(self.entry))/\(currentState)"
        self.state.withLock {
          $0.events.append("stop")
          $0.stopSnapshots.append(snapshot)
          $0.running = false
        }
      }
    )
  }

  var events: [String] { state.withLock { $0.events } }
  var reloadEntryStates: [String] { state.withLock { $0.reloadEntryStates } }
  var stopSnapshots: [String] { state.withLock { $0.stopSnapshots } }
  var isRunning: Bool { state.withLock { $0.running } }

  func replaceProcess() {
    state.withLock { $0.processID += 1 }
  }

  private static func runtime(processID: Int32) -> SketchyBarRuntimeInspection {
    SketchyBarRuntimeInspection(
      status: .running,
      message: "running",
      processID: processID,
      executablePath: "/opt/homebrew/Cellar/sketchybar/test/bin/sketchybar",
      serviceLabel: SketchyBarHomebrewService.serviceLabel
    )
  }

  private static func entryState(_ url: URL) -> String {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return "missing" }
    if metadata.st_mode & S_IFMT == S_IFLNK { return "managed" }
    return (try? String(contentsOf: url, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
  }

  private static func exists(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
  }
}
