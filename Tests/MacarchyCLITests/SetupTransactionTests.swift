import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

extension SetupOwnershipTests {
  @Test
  func pinnedThemeLinkReadPreservesSetupErrors() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-pinned-theme-link-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let parentDescriptor = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parentDescriptor) }
    let invalidURL = root.appending(path: "invalid")
    let invalidDestination: [CChar] = [-1, 0]
    let created = invalidDestination.withUnsafeBufferPointer { destination in
      "invalid".withCString {
        Darwin.symlinkat(destination.baseAddress!, parentDescriptor, $0)
      }
    }
    #expect(created == 0)
    let manager = SetupOwnershipManager()
    #expect(
      throws: SetupOwnershipError.system(
        "read pinned theme link",
        invalidURL,
        "destination is not UTF-8"
      )
    ) {
      try manager.readPinnedSymbolicLink(
        parentDescriptor: parentDescriptor,
        name: "invalid",
        url: invalidURL
      )
    }

    let missingURL = root.appending(path: "missing")
    #expect(
      throws: SetupOwnershipError.system(
        "read pinned theme link",
        missingURL,
        String(cString: strerror(ENOENT))
      )
    ) {
      try manager.readPinnedSymbolicLink(
        parentDescriptor: parentDescriptor,
        name: "missing",
        url: missingURL
      )
    }
  }

  @Test
  func teardownFinishesAnInterruptedThemeLinkRemoval() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(SetupOwnershipManager.batThemeLinkID, placement: .claimed)
    ])

    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    var teardownStatuses = unownedTeardownStatuses
    teardownStatuses["bat.theme-link"] = .removed
    expectStatuses(teardown, teardownStatuses)
    #expect(try fixture.pathIsMissing(fixture.batThemeRemoval))
    #expect(try fixture.pathIsMissing(fixture.batThemeLink))
  }

  @Test
  func themeLinkTeardownNeverDeletesAConcurrentPathClaim() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(SetupOwnershipManager.batThemeLinkID)
    ])
    let batThemeLink = fixture.batThemeLink
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .teardownReady {
        try FileManager.default.removeItem(at: batThemeLink)
        try Data("concurrent owner\n".utf8).write(to: batThemeLink)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownPreflightsEveryOwnedSeamBeforeChangingAnyOfThem() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership(
      fixture.legacyBatEza(bat: "--italic-text=always\n", shell: "export EDITOR=nvim\n"))
    try Data("user edit\n\(fixture.batDirective)\n".utf8).write(
      to: fixture.batConfiguration,
      options: .atomic
    )
    let ezaBefore = try fixture.shellConfigurationText()

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.batConfiguration)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }

    #expect(try fixture.batConfigurationText() == "user edit\n\(fixture.batDirective)\n")
    #expect(try fixture.shellConfigurationText() == ezaBefore)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownRejectsAnOwnedThemeLinkBelowASwappedParentBeforeMutation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership(
      fixture.legacyBatEza(bat: "--italic-text=always\n", shell: "export EDITOR=nvim\n"))
    let ezaDirectory = fixture.ezaThemeLink.deletingLastPathComponent()
    let movedEzaDirectory = fixture.root.appending(path: "eza-original")
    try FileManager.default.moveItem(at: ezaDirectory, to: movedEzaDirectory)
    try FileManager.default.createSymbolicLink(
      at: ezaDirectory,
      withDestinationURL: movedEzaDirectory
    )
    let batBefore = try fixture.batConfigurationText()

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.ezaThemeLink)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }

    #expect(try fixture.batConfigurationText() == batBefore)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  /// Where an older release's setup stopped after recording a prepared Kitty include.
  enum InterruptedSetupBoundary: CaseIterable {
    case recordOnly
    case backupSaved
    case replacementSwapped
    case targetWritten
  }

  @Test(arguments: InterruptedSetupBoundary.allCases)
  func teardownRemovesAPreparedRecordAtEveryInterruptedSetupBoundary(
    _ boundary: InterruptedSetupBoundary
  ) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = "font_size 13\n"
    let installed = original + "\(fixture.includeDirective)\n"
    let swapped = boundary == .replacementSwapped || boundary == .targetWritten
    try fixture.writeLegacyOwnership([
      fixture.legacyKittyInclude(
        original: original,
        onDisk: swapped ? installed : original,
        phase: .prepared,
        backupPresent: boundary != .recordOnly,
        residue: boundary == .replacementSwapped ? original : nil
      )
    ])

    let preview = try #require(
      SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true).first)
    #expect(preview.status == .planned)
    #expect(try fixture.configuration() == (swapped ? installed : original))

    let teardown = try #require(
      SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false).first)

    #expect(teardown.status == .removed)
    #expect(teardown.mutationAttempted)
    #expect(try fixture.configuration() == original)
    #expect(try fixture.pathIsMissing(fixture.backup))
    #expect(try fixture.pathIsMissing(fixture.replacement))
    #expect(try fixture.pathIsMissing(fixture.manifest))
  }

  @Test
  func teardownClearsPreparedLinkAndPiSelectorRecords() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pi = "{\n  \"provider\": \"openai\"\n}\n"
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(
        SetupOwnershipManager.batThemeLinkID, phase: .prepared, placement: .absent),
      fixture.legacyThemeLink(SetupOwnershipManager.ezaThemeLinkID, phase: .prepared),
      fixture.legacyPiSelector(contents: pi, phase: .prepared),
    ])

    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)

    var teardownStatuses = unownedTeardownStatuses
    for id in ["bat.theme-link", "eza.theme-link", "pi.selector"] {
      teardownStatuses[id] = .removed
    }
    expectStatuses(teardown, teardownStatuses)
    #expect(try fixture.pathIsMissing(fixture.batThemeLink))
    #expect(try fixture.pathIsMissing(fixture.ezaThemeLink))
    #expect(try String(contentsOf: fixture.piConfiguration, encoding: .utf8) == pi)
    #expect(try fixture.pathIsMissing(fixture.manifest))
  }

  @Test
  func concurrentConfigurationEditsAreNeverOverwritten() throws {
    let boundaryFixture = try Fixture()
    defer { boundaryFixture.remove() }
    try boundaryFixture.writeLegacyOwnership([boundaryFixture.legacyKittyInclude()])
    let boundaryTarget = boundaryFixture.kittyConfiguration
    let boundaryEdit = Data("font_size 15\n".utf8)
    let boundaryTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try boundaryEdit.write(to: boundaryTarget, options: .atomic)
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try boundaryTeardown.teardown(homeDirectory: boundaryFixture.home, dryRun: false)
    }
    #expect(try boundaryFixture.configuration() == "font_size 15\n")
    #expect(!FileManager.default.fileExists(atPath: boundaryFixture.replacement.path))

    let metadataFixture = try Fixture()
    defer { metadataFixture.remove() }
    try metadataFixture.writeLegacyOwnership([metadataFixture.legacyKittyInclude()])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: metadataFixture.kittyConfiguration.path
    )
    let metadataTarget = metadataFixture.kittyConfiguration
    let installed = try metadataFixture.configuration()
    let metadataTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try Data(installed.utf8).write(to: metadataTarget, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644],
          ofItemAtPath: metadataTarget.path
        )
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try metadataTeardown.teardown(homeDirectory: metadataFixture.home, dryRun: false)
    }
    #expect(try metadataFixture.configuration() == installed)
    #expect(try metadataFixture.permissions() == 0o644)
    #expect(!FileManager.default.fileExists(atPath: metadataFixture.replacement.path))

    let teardownFixture = try Fixture()
    defer { teardownFixture.remove() }
    try teardownFixture.writeLegacyOwnership([teardownFixture.legacyKittyInclude()])
    let teardownTarget = teardownFixture.kittyConfiguration
    let teardownEdit = Data(
      "font_size 14\n\(teardownFixture.includeDirective)\n".utf8
    )
    let interruptedTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .teardownReady {
        try teardownEdit.write(to: teardownTarget, options: .atomic)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedTeardown.teardown(homeDirectory: teardownFixture.home, dryRun: false)
    }
    #expect(
      try teardownFixture.configuration()
        == "font_size 14\n\(teardownFixture.includeDirective)\n"
    )
  }

  @Test
  func replacementProceedsPastAProvenanceStampButNeverOverwritesAUserEdit() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-provenance-replacement-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appending(path: ".config/herdr", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appending(path: "config.toml")
    let replacement = directory.appending(path: ".config.toml.macarchy-replacement")
    let original = Data("[theme]\nname = \"tokyo-night\"\n".utf8)
    let managed = Data("[theme]\nname = \"macarchy\"\n".utf8)
    // The kernel stamps a file created by a provenance-tagged process; the original has none.
    let stampReplacement: @Sendable () throws -> Void = {
      let stamp = Data("tagged creator".utf8)
      let result = stamp.withUnsafeBytes { bytes in
        replacement.path.withCString { path in
          "com.apple.provenance".withCString { name in
            Darwin.setxattr(path, name, bytes.baseAddress, stamp.count, 0, XATTR_NOFOLLOW)
          }
        }
      }
      guard result == 0 else { throw SetupOwnershipError.posix("stamp", replacement) }
    }
    func replace(atReady edit: @escaping @Sendable () throws -> Void) throws {
      try original.write(to: target)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: target.path)
      try SetupOwnershipManager { checkpoint in
        if checkpoint == .replacementReady { try edit() }
      }.replaceRegularFile(
        target: target,
        replacementName: replacement.lastPathComponent,
        homeDirectory: home,
        expectedDigest: sha256Digest(original),
        data: managed,
        label: "Herdr theme surface"
      )
    }

    try replace(atReady: stampReplacement)
    #expect(try Data(contentsOf: target) == managed)

    let userEdit = Data("[theme]\nname = \"nord\"\n".utf8)
    #expect(throws: SetupOwnershipError.ownershipDrift(target)) {
      try replace(atReady: {
        try stampReplacement()
        try userEdit.write(to: target, options: .atomic)
      })
    }
    #expect(try Data(contentsOf: target) == userEdit)
    #expect(!FileManager.default.fileExists(atPath: replacement.path))
  }

  @Test
  func parentDirectorySwapCannotRedirectTheTeardownWrite() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    let installed = try fixture.configuration()
    let kittyDirectory = fixture.kittyConfiguration.deletingLastPathComponent()
    let movedDirectory = kittyDirectory.appendingPathExtension("original")
    let externalDirectory = fixture.root.appending(path: "external-kitty")
    let externalConfiguration = externalDirectory.appending(path: "kitty.conf")
    try FileManager.default.createDirectory(
      at: externalDirectory,
      withIntermediateDirectories: true
    )
    try Data(installed.utf8).write(to: externalConfiguration)
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .teardownReady {
        try FileManager.default.moveItem(at: kittyDirectory, to: movedDirectory)
        try FileManager.default.createSymbolicLink(
          at: kittyDirectory,
          withDestinationURL: externalDirectory
        )
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: externalConfiguration, encoding: .utf8) == installed)
    #expect(
      try String(
        contentsOf: movedDirectory.appending(path: "kitty.conf"),
        encoding: .utf8
      ) == installed
    )
  }

  @Test(arguments: [false, true])
  func teardownWaitsForActivationPreflightAndCanonicalCommit(abortCoordinator: Bool) async throws {
    // Other suites can synchronously wait on the held activation lock. Keep its
    // release coordinator off the cooperative pool those waiters can occupy.
    // The entire scenario must stay synchronous: Task.sleep can depend on that
    // pool even when the sleeping task prefers a Dispatch executor.
    let executor = BlockingTaskExecutor(label: "teardown-activation-overlap")
    try await withTaskExecutorPreference(executor) {
      if abortCoordinator {
        #expect(throws: OverlapCoordinatorFailure.self) {
          try teardownActivationOverlapScenario(abortCoordinator: true)
        }
      } else {
        try teardownActivationOverlapScenario(abortCoordinator: false)
      }
    }
  }

  private struct OverlapCoordinatorFailure: Error {}

  private func teardownActivationOverlapScenario(abortCoordinator: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    let installed = try fixture.configuration()
    let package = try ThemePackageLoader().load(
      packageURL: URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "Themes/catppuccin-mocha")
    )
    let stateRoot = fixture.stateRoot
    let home = fixture.home
    let preflightEntered = DispatchSemaphore(value: 0)
    let releasePreflight = DispatchSemaphore(value: 0)
    let workers = DispatchGroup()
    defer {
      // Release and join before fixture removal, including a failed assertion
      // or injected coordinator error before the ordinary release point.
      releasePreflight.signal()
      #expect(workers.wait(timeout: .now() + 5) == .success)
    }
    let activationResult = Mutex<Result<GenerationManifest, any Error>?>(nil)
    workers.enter()
    DispatchQueue.global().async {
      defer { workers.leave() }
      let result = Result {
        try ThemeActivator(root: stateRoot).activate(
          package: package,
          expectedActiveGenerationID: nil,
          preparedBackground: {
            preflightEntered.signal()
            try #require(releasePreflight.wait(timeout: .now() + 5) == .success)
            let background = try #require(package.backgrounds.first)
            return PreparedThemeBackground(
              selection: GenerationBackground(id: background.id, format: background.format),
              data: package.data(for: background)
            )
          }
        )
      }
      activationResult.withLock { $0 = result }
    }
    // Readiness can wait behind other suites on the process-wide lock. Use
    // the worker coordination budget, not the short contention observation
    // below, to establish that this scenario has actually started.
    try #require(preflightEntered.wait(timeout: .now() + 5) == .success)
    let teardownCompleted = Mutex(false)
    let teardownResult = Mutex<Result<[SetupIntegrationResult], any Error>?>(nil)
    workers.enter()
    DispatchQueue.global().async {
      defer { workers.leave() }
      let result = Result {
        try SetupOwnershipManager().teardown(
          homeDirectory: home,
          dryRun: false
        )
      }
      teardownResult.withLock { $0 = result }
      teardownCompleted.withLock { $0 = true }
    }

    Thread.sleep(forTimeInterval: 0.025)
    #expect(!teardownCompleted.withLock { $0 })
    #expect(try fixture.configuration() == installed)
    if abortCoordinator { throw OverlapCoordinatorFailure() }
    releasePreflight.signal()

    try #require(workers.wait(timeout: .now() + 5) == .success)
    _ = try #require(activationResult.withLock { $0 }).get()
    #expect(try #require(teardownResult.withLock { $0 }).get().first?.status == .removed)
    #expect(try fixture.configuration() == "font_size 13\n")
  }

  @Test
  func teardownRefusesToEraseChangesMadeAfterSetup() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    try Data("font_size 14\n\(fixture.includeDirective)\n".utf8).write(
      to: fixture.kittyConfiguration,
      options: .atomic
    )

    let expected = SetupOwnershipError.ownershipDrift(fixture.kittyConfiguration)
    #expect(throws: expected) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    let execution = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: true)
    let report = try decode(TeardownReport.self, execution.output)
    #expect(!execution.succeeded)
    expectStatuses(report.integrations, ["kitty.include": "failed"])
    #expect(report.integrations.first?.message == expected.description)
    #expect(report.integrations.first?.mutationAttempted == false)
    let human = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: false, json: false)
    #expect(!human.output.contains("brew uninstall"))
    #expect(try fixture.configuration() == "font_size 14\n\(fixture.includeDirective)\n")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
    #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
  }

  @Test
  func ownershipRejectsAnUnsupportedSchemaVersion() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"schema_version":99,"records":[]}"#.utf8).write(to: fixture.manifest)

    #expect(throws: SetupOwnershipError.invalidManifest("unsupported schema version 99")) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func ownershipRejectsOutOfContractSchemaOneShapes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let prereleaseRecord = """
      {
        "schema_version": 1,
        "records": [{
          "id": "kitty.include",
          "phase": "applied",
          "target_path": "\(fixture.kittyConfiguration.path)",
          "backup_path": "state/setup/backups/kitty.conf",
          "original_digest": "original",
          "installed_digest": "installed"
        }]
      }
      """
    let documents = [
      #"{"schema_version":1,"records":[],"integration":{}}"#,
      #"{"schema_version":1,"records":[{"id":"bat.theme-link","phase":"applied","kind":"symbolic_link","target_path":"target","installed_digest":"digest","link_destination":"destination","unknown_field":true}]}"#,
      prereleaseRecord,
    ]

    for document in documents {
      try Data(document.utf8).write(to: fixture.manifest, options: .atomic)
      do {
        _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
        Issue.record("Expected strict schema-v1 rejection")
      } catch SetupOwnershipError.invalidManifest {
      } catch {
        Issue.record("Expected invalid manifest, got \(error)")
      }
    }
  }

  @Test
  func teardownDryRunRejectsASymlinkedBackupBeforePromisingRestoration() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    let externalBackup = fixture.root.appending(path: "external-kitty.conf")
    try FileManager.default.removeItem(at: fixture.backup)
    try Data("font_size 13\n".utf8).write(to: externalBackup)
    try FileManager.default.createSymbolicLink(
      at: fixture.backup,
      withDestinationURL: externalBackup
    )

    let expected = SetupOwnershipError.corruptBackup(fixture.backup)
    #expect(throws: expected) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
    let execution = try TeardownCommandRunner(
      ownershipManager: SetupOwnershipManager()
    ).execute(homeDirectory: fixture.home, dryRun: true, json: true)
    let report = try decode(TeardownReport.self, execution.output)
    #expect(!execution.succeeded)
    expectStatuses(report.integrations, ["kitty.include": "failed"])
    #expect(report.integrations.first?.message == expected.description)
    #expect(report.integrations.first?.mutationAttempted == false)
    #expect(try fixture.configuration().contains(fixture.includeDirective))
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownRejectsAPermissiveBackup() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.backup.path
    )

    #expect(throws: SetupOwnershipError.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func teardownNeverRecursivelyRemovesSubstitutedBackupState() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([fixture.legacyKittyInclude()])
    try Data("font_size 13\n".utf8).write(
      to: fixture.kittyConfiguration,
      options: .atomic
    )
    try FileManager.default.removeItem(at: fixture.backup)
    try FileManager.default.createDirectory(
      at: fixture.backup,
      withIntermediateDirectories: false
    )
    let sentinel = fixture.backup.appending(path: "preserve")
    try Data("evidence".utf8).write(to: sentinel)

    #expect(throws: SetupOwnershipError.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "evidence")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func teardownPreservesReplacementResidueUntilTheBackupIsValidated() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = "font_size 13\n"
    try fixture.writeLegacyOwnership([
      fixture.legacyKittyInclude(
        original: original, phase: .prepared, backupPresent: false, residue: original)
    ])
    let residue = try Data(contentsOf: fixture.replacement)

    #expect(throws: SetupOwnershipError.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try Data(contentsOf: fixture.replacement) == residue)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

extension BtopYaziAtuinSetupTests {
  @Test
  func teardownPreflightsTheWholeBatchBeforeRemovingAnySeam() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(SetupOwnershipManager.btopThemeLinkID),
      fixture.legacyFileRecord(
        SetupOwnershipManager.yaziSelectorID,
        original: "[flavor]\nlight = \"default\"\n",
        installed: "[flavor]\ndark = \"macarchy-current\"\nlight = \"default\"\n"
      ),
      fixture.legacyThemeLink(SetupOwnershipManager.atuinThemeLinkID),
    ])
    try Data("user changed this file\n".utf8).write(
      to: fixture.yaziConfiguration,
      options: .atomic
    )

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.yaziConfiguration)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try fixture.linkDestination(fixture.atuinThemeLink) == fixture.atuinThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.btopThemeLink) == fixture.btopThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

extension NeovimStarshipSetupTests {
  @Test
  func teardownPreflightsBothOwnedLinksBeforeRemovingEither() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeLegacyOwnership([
      fixture.legacyThemeLink(SetupOwnershipManager.neovimThemeLinkID),
      fixture.legacyThemeLink(SetupOwnershipManager.starshipConfigurationLinkID),
    ])
    try FileManager.default.removeItem(at: fixture.neovimThemeLink)
    try Data("user-owned configuration\n".utf8).write(
      to: fixture.neovimThemeLink
    )

    #expect(throws: SetupOwnershipError.ownershipDrift(fixture.neovimThemeLink)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try fixture.linkDestination(fixture.starshipConfigurationLink)
        == fixture.starshipBridge.path
    )
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

extension AgentTUISetupTests {
  @Test
  func piSelectorTeardownResumesAnInterruptedKeyRemoval() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = "{\n  \"provider\": \"openai\"\n}\n"
    try fixture.writeLegacyOwnership([
      fixture.legacyPiSelector(
        contents: "{\n  \"theme\": \"macarchy-current\",\n  \"provider\": \"openai\"\n}\n")
    ])

    let interruptedTeardown = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedTeardown.teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement) == false)

    let teardown = try SetupOwnershipManager().teardown(
      homeDirectory: fixture.home,
      dryRun: false
    )
    #expect(teardown.first { $0.id == "pi.selector" }?.status == .removed)
    #expect(try String(contentsOf: fixture.piConfiguration, encoding: .utf8) == original)
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement))
  }
}
