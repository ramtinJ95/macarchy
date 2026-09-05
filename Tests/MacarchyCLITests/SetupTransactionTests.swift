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
  func batAndEzaTransactionsResumeFileAndLinkBoundaries() throws {
    for checkpoint in [
      SetupOwnershipCheckpoint.manifestPrepared,
      .backupWritten,
      .replacementSwapped,
      .targetWritten,
    ] {
      let fixture = try Fixture(configuration: "", externalBatEza: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createLocalBatEzaConfigurations(
        bat: "--italic-text=always\n",
        shell: "\(fixture.ezaDirective)\n"
      )
      let interrupted = SetupOwnershipManager { observed in
        if observed == checkpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
      }
      let resumed = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
      var resumedStatuses = externalFixtureStatuses
      for id in ["bat.selector", "bat.theme-link", "eza.theme-link"] {
        resumedStatuses[id] = .owned
      }
      expectStatuses(resumed, resumedStatuses)
      #expect(try fixture.batConfigurationText().contains(fixture.batDirective))
      #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
      #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    }

    for checkpoint in [SetupOwnershipCheckpoint.manifestPrepared, .targetWritten] {
      let fixture = try Fixture(configuration: "", externalBatEza: false)
      defer { fixture.remove() }
      try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
      try fixture.createLocalBatEzaConfigurations(
        bat: "\(fixture.batDirective)\n",
        shell: "\(fixture.ezaDirective)\n"
      )
      let interrupted = SetupOwnershipManager { observed in
        if observed == checkpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
      }
      let resumed = try SetupOwnershipManager().setup(
        homeDirectory: fixture.home,
        dryRun: false
      )
      var resumedStatuses = externalFixtureStatuses
      for id in ["bat.theme-link", "eza.theme-link"] {
        resumedStatuses[id] = .owned
      }
      expectStatuses(resumed, resumedStatuses)
      #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    }

    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.ezaThemeLink,
      withDestinationURL: fixture.ezaThemeDestination
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try FileManager.default.moveItem(at: fixture.batThemeLink, to: fixture.batThemeRemoval)

    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    var resumedStatuses = externalFixtureStatuses
    resumedStatuses["bat.theme-link"] = .owned
    expectStatuses(resumed, resumedStatuses)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))

    try FileManager.default.moveItem(at: fixture.batThemeLink, to: fixture.batThemeRemoval)
    let teardown = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    var teardownStatuses = externalFixtureStatuses.mapValues { _ in
      SetupIntegrationResult.Status.none
    }
    teardownStatuses["bat.theme-link"] = .removed
    expectStatuses(teardown, teardownStatuses)
    #expect(!FileManager.default.fileExists(atPath: fixture.batThemeRemoval.path))
  }

  @Test
  func themeLinkCreationNeverOverwritesAConcurrentPathClaim() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    let batThemeLink = fixture.batThemeLink
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .manifestPrepared {
        try Data("concurrent owner\n".utf8).write(to: batThemeLink)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
    expectOwnershipError(.ownershipDrift(fixture.batThemeLink)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(
      try String(contentsOf: fixture.batThemeLink, encoding: .utf8)
        == "concurrent owner\n"
    )
  }

  @Test
  func themeLinkTeardownNeverDeletesAConcurrentPathClaim() throws {
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "\(fixture.batDirective)\n",
      shell: "\(fixture.ezaDirective)\n"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.ezaThemeLink,
      withDestinationURL: fixture.ezaThemeDestination
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
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
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try Data("user edit\n\(fixture.batDirective)\n".utf8).write(
      to: fixture.batConfiguration,
      options: .atomic
    )
    let ezaBefore = try fixture.shellConfigurationText()

    expectOwnershipError(.ownershipDrift(fixture.batConfiguration)) {
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
    let fixture = try Fixture(configuration: "", externalBatEza: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBatEzaConfigurations(
      bat: "--italic-text=always\n",
      shell: "export EDITOR=nvim\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let ezaDirectory = fixture.ezaThemeLink.deletingLastPathComponent()
    let movedEzaDirectory = fixture.root.appending(path: "eza-original")
    try FileManager.default.moveItem(at: ezaDirectory, to: movedEzaDirectory)
    try FileManager.default.createSymbolicLink(
      at: ezaDirectory,
      withDestinationURL: movedEzaDirectory
    )
    let batBefore = try fixture.batConfigurationText()

    expectOwnershipError(.ownershipDrift(fixture.ezaThemeLink)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }

    #expect(try fixture.batConfigurationText() == batBefore)
    #expect(try fixture.linkDestination(fixture.batThemeLink) == fixture.batThemeDestination.path)
    #expect(try fixture.linkDestination(fixture.ezaThemeLink) == fixture.ezaThemeDestination.path)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func setupResumesAtEveryRecordedTransactionBoundary() throws {
    let setupCheckpoints: [SetupOwnershipCheckpoint] = [
      .manifestPrepared, .backupWritten, .replacementSwapped, .targetWritten,
    ]
    for selectedCheckpoint in setupCheckpoints {
      let fixture = try Fixture(configuration: "font_size 13\n")
      defer { fixture.remove() }
      let interrupted = SetupOwnershipManager { checkpoint in
        if checkpoint == selectedCheckpoint { throw FixtureError.interrupted }
      }

      #expect(throws: SetupOwnershipTransactionError.self) {
        try interrupted.setup(
          homeDirectory: fixture.home,
          dryRun: false
        )
      }
      let prepared = try decode(
        OwnershipManifest.self,
        String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
      )
      #expect(prepared.records.map(\.phase) == ["prepared"])

      let resumed = try #require(
        SetupOwnershipManager().setup(
          homeDirectory: fixture.home,
          dryRun: false
        ).first)
      let applied = try decode(
        OwnershipManifest.self,
        String(decoding: Data(contentsOf: fixture.manifest), as: UTF8.self)
      )

      #expect(resumed.status == .owned)
      #expect(resumed.mutationAttempted)
      #expect(applied.records.map(\.phase) == ["applied"])
      #expect(try fixture.configuration().contains(fixture.includeDirective))
      #expect(FileManager.default.fileExists(atPath: fixture.backup.path))
      #expect(
        try #require(
          SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false).first
        ).status
          == .removed
      )
      #expect(try fixture.configuration() == "font_size 13\n")
    }
  }

  @Test
  func setupPreservesReplacementResidueUntilTheBackupIsValidated() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
    }
    let residue = try Data(contentsOf: fixture.replacement)
    try FileManager.default.removeItem(at: fixture.backup)

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try Data(contentsOf: fixture.replacement) == residue)
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func concurrentConfigurationEditsAreNeverOverwritten() throws {
    let setupFixture = try Fixture(configuration: "font_size 13\n")
    defer { setupFixture.remove() }
    let setupTarget = setupFixture.kittyConfiguration
    let setupEdit = Data("font_size 14\n".utf8)
    let interruptedSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .backupWritten {
        try setupEdit.write(to: setupTarget, options: .atomic)
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedSetup.setup(homeDirectory: setupFixture.home, dryRun: false)
    }
    #expect(try setupFixture.configuration() == "font_size 14\n")

    let boundaryFixture = try Fixture(configuration: "font_size 13\n")
    defer { boundaryFixture.remove() }
    let boundaryTarget = boundaryFixture.kittyConfiguration
    let boundaryEdit = Data("font_size 15\n".utf8)
    let boundarySetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try boundaryEdit.write(to: boundaryTarget, options: .atomic)
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try boundarySetup.setup(homeDirectory: boundaryFixture.home, dryRun: false)
    }
    #expect(try boundaryFixture.configuration() == "font_size 15\n")
    #expect(!FileManager.default.fileExists(atPath: boundaryFixture.replacement.path))

    let metadataFixture = try Fixture(configuration: "font_size 13\n")
    defer { metadataFixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: metadataFixture.kittyConfiguration.path
    )
    let metadataTarget = metadataFixture.kittyConfiguration
    let metadataSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementReady {
        try Data("font_size 13\n".utf8).write(to: metadataTarget, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644],
          ofItemAtPath: metadataTarget.path
        )
      }
    }
    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try metadataSetup.setup(homeDirectory: metadataFixture.home, dryRun: false)
    }
    #expect(try metadataFixture.configuration() == "font_size 13\n")
    #expect(try metadataFixture.permissions() == 0o644)
    #expect(!FileManager.default.fileExists(atPath: metadataFixture.replacement.path))

    let teardownFixture = try Fixture(configuration: "font_size 13\n")
    defer { teardownFixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: teardownFixture.home, dryRun: false)
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
  func parentDirectorySwapCannotRedirectTheSetupWrite() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    let kittyDirectory = fixture.kittyConfiguration.deletingLastPathComponent()
    let movedDirectory = kittyDirectory.appendingPathExtension("original")
    let externalDirectory = fixture.root.appending(path: "external-kitty")
    let externalConfiguration = externalDirectory.appending(path: "kitty.conf")
    try FileManager.default.createDirectory(
      at: externalDirectory,
      withIntermediateDirectories: true
    )
    try Data("font_size 13\n".utf8).write(to: externalConfiguration)
    let manager = SetupOwnershipManager { checkpoint in
      if checkpoint == .backupWritten {
        try FileManager.default.moveItem(at: kittyDirectory, to: movedDirectory)
        try FileManager.default.createSymbolicLink(
          at: kittyDirectory,
          withDestinationURL: externalDirectory
        )
      }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try manager.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: externalConfiguration, encoding: .utf8) == "font_size 13\n")
    #expect(
      try String(
        contentsOf: movedDirectory.appending(path: "kitty.conf"),
        encoding: .utf8
      ) == "font_size 13\n"
    )
  }

  @Test(arguments: [false, true])
  func setupWaitsForActivationPreflightAndCanonicalCommit(abortCoordinator: Bool) async throws {
    // Other suites can synchronously wait on the held activation lock. Keep its
    // release coordinator off the cooperative pool those waiters can occupy.
    // The entire scenario must stay synchronous: Task.sleep can depend on that
    // pool even when the sleeping task prefers a Dispatch executor.
    let executor = BlockingTaskExecutor(label: "setup-activation-overlap")
    try await withTaskExecutorPreference(executor) {
      if abortCoordinator {
        #expect(throws: OverlapCoordinatorFailure.self) {
          try setupActivationOverlapScenario(abortCoordinator: true)
        }
      } else {
        try setupActivationOverlapScenario(abortCoordinator: false)
      }
    }
  }

  private struct OverlapCoordinatorFailure: Error {}

  private func setupActivationOverlapScenario(abortCoordinator: Bool) throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
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
    try #require(preflightEntered.wait(timeout: .now() + 0.5) == .success)
    let setupCompleted = Mutex(false)
    let setupResult = Mutex<Result<[SetupIntegrationResult], any Error>?>(nil)
    workers.enter()
    DispatchQueue.global().async {
      defer { workers.leave() }
      let result = Result {
        try SetupOwnershipManager().setup(
          homeDirectory: home,
          dryRun: false
        )
      }
      setupResult.withLock { $0 = result }
      setupCompleted.withLock { $0 = true }
    }

    Thread.sleep(forTimeInterval: 0.025)
    #expect(!setupCompleted.withLock { $0 })
    #expect(try fixture.configuration() == "font_size 13\n")
    if abortCoordinator { throw OverlapCoordinatorFailure() }
    releasePreflight.signal()

    try #require(workers.wait(timeout: .now() + 5) == .success)
    _ = try #require(activationResult.withLock { $0 }).get()
    #expect(try #require(setupResult.withLock { $0 }).get().first?.status == .owned)
    #expect(try fixture.configuration().contains(fixture.includeDirective))
  }

  @Test
  func teardownRefusesToEraseChangesMadeAfterSetup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(
      homeDirectory: fixture.home,
      dryRun: false
    )
    try Data("font_size 14\n\(fixture.includeDirective)\n".utf8).write(
      to: fixture.kittyConfiguration,
      options: .atomic
    )

    let expected = SetupOwnershipError.ownershipDrift(fixture.kittyConfiguration)
    expectOwnershipError(expected) {
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
  func ownershipRejectsAnInstalledDigestThatCannotBeReproducedFromBackup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let forgedConfiguration = Data("font_size 99\n".utf8)
    var manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest))
        as? [String: Any]
    )
    var records = try #require(manifest["records"] as? [[String: Any]])
    records[0]["installed_digest"] = sha256Digest(forgedConfiguration)
    manifest["records"] = records
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
      to: fixture.manifest,
      options: .atomic
    )
    try forgedConfiguration.write(to: fixture.kittyConfiguration, options: .atomic)

    expectOwnershipError(
      .invalidManifest("Kitty installed digest cannot be reproduced")
    ) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func ownershipRejectsAnUnsupportedSchemaVersion() throws {
    let fixture = try Fixture(configuration: "")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"schema_version":99,"records":[]}"#.utf8).write(to: fixture.manifest)

    expectOwnershipError(.invalidManifest("unsupported schema version 99")) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func ownershipRejectsOutOfContractSchemaOneShapes() throws {
    let fixture = try Fixture(configuration: "")
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
        _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
        Issue.record("Expected strict schema-v1 rejection")
      } catch SetupOwnershipError.invalidManifest {
      } catch {
        Issue.record("Expected invalid manifest, got \(error)")
      }
    }
  }

  @Test
  func teardownDryRunRejectsASymlinkedBackupBeforePromisingRestoration() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    let externalBackup = fixture.root.appending(path: "external-kitty.conf")
    try FileManager.default.removeItem(at: fixture.backup)
    try Data("font_size 13\n".utf8).write(to: externalBackup)
    try FileManager.default.createSymbolicLink(
      at: fixture.backup,
      withDestinationURL: externalBackup
    )

    let expected = SetupOwnershipError.corruptBackup(fixture.backup)
    expectOwnershipError(expected) {
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
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.backup.path
    )

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: true)
    }
  }

  @Test
  func teardownNeverRecursivelyRemovesSubstitutedBackupState() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
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

    expectOwnershipError(.corruptBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().teardown(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "evidence")
    #expect(FileManager.default.fileExists(atPath: fixture.manifest.path))
  }

  @Test
  func setupRefusesAnOrphanedBackup() throws {
    let fixture = try Fixture(configuration: "font_size 13\n")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.backup.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("recovery evidence".utf8).write(to: fixture.backup)

    expectOwnershipError(.orphanedBackup(fixture.backup)) {
      _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: true)
    }
    #expect(try String(contentsOf: fixture.backup, encoding: .utf8) == "recovery evidence")
    #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
  }
}

extension BtopYaziAtuinSetupTests {
  @Test
  func interruptedTOMLSelectorReproducesAndResumesFromBackup() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\nlight = \"default\"\n",
      atuin: "[theme]\nname = \"macarchy-current\"\n"
    )
    try fixture.createBtopYaziAtuinThemeLinks()
    let interrupted = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interrupted.setup(homeDirectory: fixture.home, dryRun: false)
    }
    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)

    var resumedStatuses = externalFixtureStatuses
    resumedStatuses["yazi.selector"] = .owned
    expectStatuses(resumed, resumedStatuses)
    #expect(
      try String(contentsOf: fixture.yaziConfiguration, encoding: .utf8)
        == "[flavor]\ndark = \"macarchy-current\"\nlight = \"default\"\n"
    )
  }

  @Test
  func teardownPreflightsTheWholeBatchBeforeRemovingAnySeam() throws {
    let fixture = try Fixture(configuration: "", externalBtopYaziAtuin: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createLocalBtopYaziAtuinConfigurations(
      btop: "\(BtopAdapter.themeDirective)\n",
      yazi: "[flavor]\nlight = \"default\"\n",
      atuin: "sync_frequency = \"5m\"\n"
    )
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
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
  func ownedLinksResumeAtTheirRecordedCreationBoundaries() throws {
    let neovim = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { neovim.remove() }
    try neovim.writeKittyConfiguration("\(neovim.includeDirective)\n")
    try neovim.createNeovimStarshipPrerequisites()
    let interruptedNeovim = SetupOwnershipManager { checkpoint in
      if checkpoint == .targetWritten { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedNeovim.setup(homeDirectory: neovim.home, dryRun: false)
    }
    let resumedNeovim = try SetupOwnershipManager().setup(
      homeDirectory: neovim.home,
      dryRun: false
    )
    var resumedNeovimStatuses = externalFixtureStatuses
    resumedNeovimStatuses["neovim.theme-link"] = .owned
    resumedNeovimStatuses["starship.configuration-link"] = .owned
    expectStatuses(resumedNeovim, resumedNeovimStatuses)

    let starship = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { starship.remove() }
    try starship.writeKittyConfiguration("\(starship.includeDirective)\n")
    try starship.createNeovimStarshipPrerequisites()
    try starship.createExternalNeovimThemeLink()
    let interruptedStarship = SetupOwnershipManager { checkpoint in
      if checkpoint == .manifestPrepared { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedStarship.setup(homeDirectory: starship.home, dryRun: false)
    }
    let resumedStarship = try SetupOwnershipManager().setup(
      homeDirectory: starship.home,
      dryRun: false
    )
    var resumedStarshipStatuses = externalFixtureStatuses
    resumedStarshipStatuses["starship.configuration-link"] = .owned
    expectStatuses(resumedStarship, resumedStarshipStatuses)
  }

  @Test
  func teardownPreflightsBothOwnedLinksBeforeRemovingEither() throws {
    let fixture = try Fixture(configuration: "", externalNeovimStarship: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    try fixture.createNeovimStarshipPrerequisites()
    _ = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
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
  func piSelectorResumesInterruptedKeyInsertionAndRemoval() throws {
    let fixture = try Fixture(configuration: "", externalAgentTUIs: false)
    defer { fixture.remove() }
    try fixture.writeKittyConfiguration("\(fixture.includeDirective)\n")
    let original = "{\n  \"provider\": \"openai\"\n}\n"
    try fixture.createLocalAgentTUIConfigurations(
      pi: original,
      tuicr: "theme = \"macarchy-current\"\n",
      codex: "[tui]\ntheme = \"macarchy-current\"\n"
    )
    try fixture.createAgentTUIThemeLinks()
    let interruptedSetup = SetupOwnershipManager { checkpoint in
      if checkpoint == .replacementSwapped { throw FixtureError.interrupted }
    }

    #expect(throws: SetupOwnershipTransactionError.self) {
      _ = try interruptedSetup.setup(homeDirectory: fixture.home, dryRun: false)
    }
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement) == false)

    let resumed = try SetupOwnershipManager().setup(homeDirectory: fixture.home, dryRun: false)
    #expect(resumed.first { $0.id == "pi.selector" }?.status == .owned)
    #expect(try fixture.pathIsMissing(fixture.piSelectorReplacement))

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

private func expectOwnershipError(
  _ expected: SetupOwnershipError,
  operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record("Expected \(expected)")
  } catch let error as SetupOwnershipError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), got \(error)")
  }
}
