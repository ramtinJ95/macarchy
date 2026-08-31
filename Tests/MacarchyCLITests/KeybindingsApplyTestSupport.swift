import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

final class LifecycleFixture: Sendable {
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
  struct AcceptanceCheckpointObservation: Sendable {
    let selectedGenerationID: String
    let currentGenerationID: String?
    let transactionGenerationID: String?
    let transactionPhase: KeybindingApplyPhase?
    let lifecycleEvidenceExists: Bool
    let lifecycleStatus: KeybindingLifecycleEvidenceStatus
  }
#endif

struct KeybindingsApplyFixture {
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

enum SymlinkFinalizationCheckpoint: CaseIterable {
  case deletionPublished
  case postRemoval
}

private enum SymlinkFinalizationInterruption: Error {
  case injected
}

extension KeybindingsApplyCommandTests {
  func exerciseSymlinkFinalizationRecovery(
    directoryLevel: Bool,
    checkpoint: SymlinkFinalizationCheckpoint,
    throughApply: Bool
  ) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let providerURL: URL
    if directoryLevel {
      providerURL = fixture.home.appending(path: ".config/skhd")
      try FileManager.default.removeItem(at: providerURL)
      let source = fixture.root.appending(path: "dotfiles/skhd")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try Data("alt - x : directory finalization\n".utf8).write(
        to: source.appending(path: "skhdrc")
      )
      try FileManager.default.createSymbolicLink(
        atPath: providerURL.path,
        withDestinationPath: source.path
      )
    } else {
      providerURL = fixture.home.appending(path: ".config/skhd/skhdrc")
      let source = fixture.root.appending(path: "dotfiles/skhdrc")
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("alt - x : entry finalization\n".utf8).write(to: source)
      try FileManager.default.createSymbolicLink(
        atPath: providerURL.path,
        withDestinationPath: source.path
      )
    }
    var originalMetadata = stat()
    #expect(lstat(providerURL.path, &originalMetadata) == 0)
    let evidence = try fixture.adoptionEvidence()
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    #expect(
      try fixture.execute(
        runner: runner,
        adoptionEvidence: evidence.digest,
        json: true
      ).succeeded
    )
    let record = try fixture.keybindingOwnershipRecord()
    let nonce = try #require(record.claimNonce)
    let retained = URL(filePath: try #require(record.retainedOriginalPath))
    let deletionResidue = retained.deletingLastPathComponent().appending(
      path: ".\(retained.lastPathComponent).deleting-\(nonce)"
    )
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
    let publishedCount = Mutex(0)
    let interrupted = KeybindingProviderTransaction(
      homeDirectory: fixture.home,
      faultInjector: { observed in
        switch checkpoint {
        case .deletionPublished where observed == .deletionCandidatePublished:
          let shouldInterrupt = publishedCount.withLock { count in
            count += 1
            return count == (directoryLevel ? 2 : 1)
          }
          if shouldInterrupt { throw SymlinkFinalizationInterruption.injected }
        case .postRemoval where observed == .backupRemoved:
          throw SymlinkFinalizationInterruption.injected
        default:
          break
        }
      }
    )
    #expect(throws: SymlinkFinalizationInterruption.self) {
      try interrupted.finalizeOriginalRestoration()
    }
    var restoredMetadata = stat()
    #expect(lstat(providerURL.path, &restoredMetadata) == 0)
    #expect(restoredMetadata.st_dev == originalMetadata.st_dev)
    #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
    #expect(
      FileManager.default.fileExists(atPath: deletionResidue.path)
        == (checkpoint == .deletionPublished)
    )
    #expect(!FileManager.default.fileExists(atPath: retained.path))

    if throughApply {
      let recovered = try fixture.execute(
        runner: runner,
        adoptionEvidence: evidence.digest,
        json: true
      )
      #expect(recovered.succeeded)
      let reapplied = try fixture.keybindingOwnershipRecord()
      var retainedMetadata = stat()
      let reappliedRetainedPath = try #require(reapplied.retainedOriginalPath)
      #expect(lstat(reappliedRetainedPath, &retainedMetadata) == 0)
      #expect(retainedMetadata.st_dev == originalMetadata.st_dev)
      #expect(retainedMetadata.st_ino == originalMetadata.st_ino)
    } else {
      let recovered = try runner.teardownLocked(
        stateRoot: fixture.stateRoot,
        homeDirectory: fixture.home,
        dryRun: false
      )
      #expect(recovered.status == .none)
      #expect(lstat(providerURL.path, &restoredMetadata) == 0)
      #expect(restoredMetadata.st_dev == originalMetadata.st_dev)
      #expect(restoredMetadata.st_ino == originalMetadata.st_ino)
      #expect(
        try SetupOwnershipManager().readRecords(
          context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
        ).isEmpty
      )
    }
    #expect(try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read() == nil)
    #expect(!FileManager.default.fileExists(atPath: deletionResidue.path))
  }

  func assertMultiplyLinkedSymlinkBlocks(directoryLevel: Bool) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let symlink: URL
    let alias: URL
    if directoryLevel {
      symlink = fixture.home.appending(path: ".config/skhd")
      alias = fixture.home.appending(path: ".config/skhd-alias")
      try FileManager.default.removeItem(at: symlink)
      let source = fixture.root.appending(path: "dotfiles/skhd")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try Data("alt - x : directory hard link\n".utf8).write(
        to: source.appending(path: "skhdrc")
      )
      try FileManager.default.createSymbolicLink(
        atPath: symlink.path,
        withDestinationPath: source.path
      )
    } else {
      symlink = fixture.home.appending(path: ".config/skhd/skhdrc")
      alias = fixture.home.appending(path: ".config/skhd/skhdrc-alias")
      let source = fixture.root.appending(path: "dotfiles/skhdrc")
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("alt - x : entry hard link\n".utf8).write(to: source)
      try FileManager.default.createSymbolicLink(
        atPath: symlink.path,
        withDestinationPath: source.path
      )
    }
    let reviewedEvidence = try fixture.adoptionEvidence()
    let linked = symlink.path.withCString { source in
      alias.path.withCString { destination in
        Darwin.linkat(AT_FDCWD, source, AT_FDCWD, destination, 0)
      }
    }
    #expect(linked == 0)
    var before = stat()
    #expect(lstat(symlink.path, &before) == 0)
    #expect(before.st_nlink == 2)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)

    let preview = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(!preview.succeeded)
    #expect(throws: (any Error).self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).preflightInstall(
        expectedEvidence: reviewedEvidence,
        approvedEvidenceDigest: reviewedEvidence.digest
      )
    }
    let applied = try fixture.execute(
      runner: runner,
      adoptionEvidence: reviewedEvidence.digest,
      json: true
    )
    #expect(!applied.succeeded)
    #expect(try jsonObject(applied.output)["mutated"] as? Bool == false)
    var after = stat()
    #expect(lstat(symlink.path, &after) == 0)
    #expect(after.st_ino == before.st_ino)
    #expect(after.st_nlink == 2)
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }

  func assertOversizedReservedSymlinkMarkerBlocks(directoryLevel: Bool) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let symlink: URL
    if directoryLevel {
      symlink = fixture.home.appending(path: ".config/skhd")
      try FileManager.default.removeItem(at: symlink)
      let source = fixture.root.appending(path: "dotfiles/skhd")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try Data("alt - x : directory marker\n".utf8).write(
        to: source.appending(path: "skhdrc")
      )
      try FileManager.default.createSymbolicLink(
        atPath: symlink.path,
        withDestinationPath: source.path
      )
    } else {
      symlink = fixture.home.appending(path: ".config/skhd/skhdrc")
      let source = fixture.root.appending(path: "dotfiles/skhdrc")
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("alt - x : entry marker\n".utf8).write(to: source)
      try FileManager.default.createSymbolicLink(
        atPath: symlink.path,
        withDestinationPath: source.path
      )
    }
    let reviewedEvidence = try fixture.adoptionEvidence()
    let marker = Data(
      repeating: 0x61,
      count: SetupOwnershipManager.maximumExtendedAttributeValueSize + 1
    )
    try setSymbolicLinkExtendedAttribute(
      KeybindingProviderInspector.claimMarkerAttribute,
      data: marker,
      at: symlink
    )
    var before = stat()
    #expect(lstat(symlink.path, &before) == 0)
    let runner = fixture.runner(lifecycle: LifecycleFixture().controller)
    let preview = try runner.preview(
      resourcesRoot: fixture.resources,
      profileURL: fixture.profile,
      profileRequired: false,
      stateRoot: fixture.stateRoot,
      homeDirectory: fixture.home,
      json: true
    )
    #expect(!preview.succeeded)
    #expect(throws: (any Error).self) {
      try KeybindingProviderTransaction(homeDirectory: fixture.home).preflightInstall(
        expectedEvidence: reviewedEvidence,
        approvedEvidenceDigest: reviewedEvidence.digest
      )
    }
    let applied = try fixture.execute(
      runner: runner,
      adoptionEvidence: reviewedEvidence.digest,
      json: true
    )
    #expect(!applied.succeeded)
    #expect(try jsonObject(applied.output)["mutated"] as? Bool == false)
    var after = stat()
    #expect(lstat(symlink.path, &after) == 0)
    #expect(after.st_ino == before.st_ino)
    #expect(
      try symbolicLinkExtendedAttributeSize(
        KeybindingProviderInspector.claimMarkerAttribute,
        at: symlink
      ) == marker.count
    )
    #expect(
      KeybindingGenerationInspector().inspect(stateRoot: fixture.stateRoot).status == .missing
    )
    #expect(
      try SetupOwnershipManager().readRecords(
        context: SetupOwnershipManager.Context(homeDirectory: fixture.home)
      ).isEmpty
    )
  }
}
