import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct TuicrPresetLifecycleTests {
  @Test
  func missingTuicrPrerequisiteBlocksBeforeConfigurationMutation() async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missing = EnvironmentPrerequisiteInspector { profile, _ in
      guard profile.presets.tuicr else { return [] }
      return [
        EnvironmentPrerequisiteStatus(
          id: "tuicr",
          status: "missing",
          requirement: "/opt/homebrew/bin/tuicr must be executable",
          remediation: "Install Homebrew formula tuicr."
        )
      ]
    }

    let result = try await fixture.apply(prerequisites: missing)

    #expect(!result.succeeded)
    #expect(result.output.contains("Missing prerequisites: tuicr"))
    #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appending(path: "environment/ownership.json").path
      )
    )
  }

  @Test
  func cleanEnableNoOpPersistedSelectionAndDisableAreOneLifecycle() async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == Set(ThemeActivationCoordinator.adapterRequirements.keys).subtracting([TuicrAdapter.id])
    )

    let plan = try fixture.plan()
    let planJSON = try jsonObject(plan.output)
    #expect(plan.succeeded)
    #expect(planJSON["presets"] as? [String: String] == ["tuicr": "enabled"])
    #expect(
      Set((planJSON["entries"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [])
        == ["tuicr_configuration", "tuicr_theme", "tuicr_syntax"]
    )

    let first = try await fixture.apply()
    #expect(first.succeeded)
    #expect(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?
        .enabledThemeAdapterIDs == [TuicrAdapter.id]
    )
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "theme = \"macarchy-current\"\n"
    )
    #expect(try fixture.link(fixture.themeLink) == fixture.themeDestination.path)
    #expect(try fixture.link(fixture.syntaxLink) == fixture.syntaxDestination.path)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == [TuicrAdapter.id]
    )

    let repeatApply = try await fixture.apply()
    #expect(repeatApply.succeeded)
    #expect(try jsonObject(repeatApply.output)["outcome"] as? String == "no_change")

    try fixture.writeProfile(tuicr: false)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains("tuicr")
    )
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.syntaxLink.path))
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains("tuicr")
    )
  }

  @Test
  func tuicrOnlyAppliedInventoryExcludesStarshipFromThemeAndDoctorPaths() async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    #expect(try await fixture.apply().succeeded)
    let consumerPaths = fixture.runtimeConsumerPaths()
    let enabled = try ThemeRuntimeSelection.enabledAdapterIDs(
      stateRoot: fixture.state,
      consumerPaths: consumerPaths
    )
    #expect(enabled == [TuicrAdapter.id])

    #expect(!FileManager.default.fileExists(atPath: consumerPaths.starshipBehaviorURL.path))
    let coordinator = ThemeActivationCoordinator(
      root: fixture.state,
      consumerPaths: consumerPaths,
      processRunner: ProcessRunner { _ in throw TuicrFixtureError.injectedFailure },
      wallpaperControl: WallpaperControl(inspect: { [] }, set: { _, _ in }),
      wallpaperSignal: YabaiWallpaperSignal(
        configurationURL: fixture.root.appending(path: "unused-yabairc"),
        macarchyExecutableURL: fixture.root.appending(path: "unused-macarchy"),
        yabaiExecutableURL: fixture.root.appending(path: "unused-yabai")
      ),
      controlIsAvailable: { _ in true },
      enabledAdapterIDs: enabled
    )
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/tokyo-night")
    )

    try coordinator.preflight(package: package)
    let preview = try coordinator.previewReconciliation([])
    #expect(preview.inspections.map(\.adapterID) == [TuicrAdapter.id])
    let reconciliation = try await coordinator.reconcile(adapterIDs: [])
    #expect(reconciliation.record.results.map(\.adapterID) == [TuicrAdapter.id])

    let doctor = DoctorCommandRunner(
      read: readThemeStatusSnapshot,
      inspect: { _, _ in
        try coordinator.inspectAdapters([], includeRuntimeChecks: true)
      },
      enabledAdapterIDs: { _, _ in enabled }
    )
    let diagnosis = try doctor.execute(
      stateRoot: fixture.state,
      consumerPaths: consumerPaths,
      json: false
    )
    #expect(diagnosis.succeeded)
    #expect(diagnosis.output.contains("tuicr.integration [ok]"))
    #expect(!diagnosis.output.contains("starship"))
    #expect(!FileManager.default.fileExists(atPath: consumerPaths.starshipBehaviorURL.path))
  }

  @Test
  func failedEnvironmentChangeRestoresPriorAppliedAdapterInventory() async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    #expect(try await fixture.apply().succeeded)
    try fixture.writeProfile(tuicr: false, bat: true)
    let proposedObserved = Mutex(false)

    let result = try await fixture.apply { checkpoint in
      guard checkpoint == .authorityPublished else { return }
      let ownership = try #require(
        try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
      )
      #expect(ownership.enabledThemeAdapterIDs == [BatAdapter.id])
      proposedObserved.withLock { $0 = true }
      throw TuicrFixtureError.injectedFailure
    }

    #expect(!result.succeeded)
    #expect(proposedObserved.withLock { $0 })
    let restored = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(restored.enabledThemeAdapterIDs == [TuicrAdapter.id])
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == [TuicrAdapter.id]
    )
  }

  @Test
  func malformedAndUnknownAppliedAdapterInventoriesBlockRuntimeSelection() throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = EnvironmentStateStore(stateRoot: fixture.state)

    for ownership in [
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        tuicrEnabled: true,
        enabledThemeAdapterIDs: [TuicrAdapter.id, TuicrAdapter.id]
      ),
      EnvironmentOwnership(
        generationID: "e-00000000-0000-0000-0000-000000000000",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        enabledThemeAdapterIDs: ["unknown-adapter"]
      ),
    ] {
      try store.writeOwnership(ownership)
      #expect(throws: (any Error).self) {
        try ThemeRuntimeSelection.enabledAdapterIDs(
          stateRoot: fixture.state,
          homeDirectory: fixture.home
        )
      }
    }
  }

  @Test
  func ownershipWithoutAppliedAdapterInventoryDecodesWithLegacySelection() throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let legacy = EnvironmentOwnership(
      generationID: "e-00000000-0000-0000-0000-000000000000",
      records: [],
      createdDirectories: [],
      originalThemeBridges: [],
      tuicrEnabled: true
    )
    let data = try JSONEncoder().encode(legacy)
    #expect(!String(decoding: data, as: UTF8.self).contains("enabled_theme_adapter_ids"))
    let decoded = try JSONDecoder().decode(EnvironmentOwnership.self, from: data)
    #expect(decoded.enabledThemeAdapterIDs == nil)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(decoded)

    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == Set(ThemeActivationCoordinator.adapterRequirements.keys)
    )
  }

  @Test
  func adoptionRestoresTheExactSelectorBoundaryAfterUnrelatedRewrites() async throws {
    let original = "wrap = true\r\ntheme = \"personal\" # keep me\r\nmouse = false\r\n"
    let fixture = try TuicrFixture(configuration: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(chmod(fixture.configuration.path, 0o640) == 0)
    try fixture.activateTheme()
    #expect(
      try EnvironmentTuicrDocument.applyingManaged(to: original, source: fixture.configuration)
        == "wrap = true\r\ntheme = \"macarchy-current\"\r\nmouse = false\r\n"
    )
    let plan = try fixture.plan()
    let digest = try #require(
      try jsonObject(plan.output)["adoption_evidence_digest"] as? String
    )

    let apply = try await fixture.apply(adopt: digest)
    #expect(apply.succeeded)
    let managed = try String(contentsOf: fixture.configuration, encoding: .utf8)
    #expect(managed.contains("wrap = true\r\n"))
    #expect(managed.contains("mouse = false\r\n"))
    #expect(managed.contains("theme = \"macarchy-current\"\r\n"))
    let storedTuicr = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()?.tuicr
    )
    #expect(storedTuicr.originalSelector?.contents == "theme = \"personal\" # keep me\r\n")
    #expect(storedTuicr.originalSelector?.lineIndex == 1)
    var managedMetadata = stat()
    #expect(lstat(fixture.configuration.path, &managedMetadata) == 0)
    #expect(managedMetadata.st_mode & 0o777 == 0o640)

    let storedOwnership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    let malformedTuicr = EnvironmentTuicrOwnership(
      path: storedTuicr.path,
      originalFileExisted: false,
      originalSelector: storedTuicr.originalSelector,
      insertedSeparatorBefore: false
    )
    #expect(!malformedTuicr.hasValidShape)
    #expect(
      !EnvironmentTuicrOwnership(
        path: storedTuicr.path,
        originalFileExisted: false,
        originalSelector: nil,
        insertedSeparatorBefore: true
      ).hasValidShape
    )
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
      EnvironmentOwnership(
        generationID: storedOwnership.generationID,
        records: storedOwnership.records,
        createdDirectories: storedOwnership.createdDirectories,
        originalThemeBridges: storedOwnership.originalThemeBridges,
        btop: storedOwnership.btop,
        tuicr: malformedTuicr,
        tuicrEnabled: true
      )
    )
    let malformedTeardown = try fixture.teardown()
    #expect(!malformedTeardown.succeeded)
    #expect(malformedTeardown.output.contains("invalid"))
    #expect(try fixture.link(fixture.themeLink) == fixture.themeDestination.path)
    #expect(try fixture.link(fixture.syntaxLink) == fixture.syntaxDestination.path)
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == managed)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(storedOwnership)

    try "theme = \"macarchy-current\"\r\nwrap = false\r\nmouse = false\r\n".write(
      to: fixture.configuration,
      atomically: true,
      encoding: .utf8
    )
    let rewritten = try String(contentsOf: fixture.configuration, encoding: .utf8)
    let restored = try EnvironmentTuicrDocument.restoringOriginal(
      in: rewritten,
      ownership: EnvironmentTuicrDocument.ownership(for: original, source: fixture.configuration),
      source: fixture.configuration
    )
    #expect(
      restored == "wrap = false\r\ntheme = \"personal\" # keep me\r\nmouse = false\r\n"
    )

    let teardown = try fixture.teardown()
    #expect(teardown.succeeded)
    #expect(
      try String(contentsOf: fixture.configuration, encoding: .utf8)
        == "wrap = false\r\ntheme = \"personal\" # keep me\r\nmouse = false\r\n"
    )
  }

  @Test
  func multilineStringDecoysAndNoFinalNewlineRemainUntouched() throws {
    let source = URL(filePath: "/test/config.toml")
    let multiline = #"""
      description = """
      theme = "basic-decoy"
      """
      notes = '''
      theme = "literal-decoy"
      '''
      [review]
      wrap = true
      """#
    let ownership = try EnvironmentTuicrDocument.ownership(for: multiline, source: source)
    let managed = try EnvironmentTuicrDocument.applyingManaged(to: multiline, source: source)
    #expect(managed.contains("theme = \"basic-decoy\""))
    #expect(managed.contains("theme = \"literal-decoy\""))
    #expect(managed.contains("'''\ntheme = \"macarchy-current\"\n[review]"))
    #expect(
      try EnvironmentTuicrDocument.restoringOriginal(
        in: managed,
        ownership: ownership,
        source: source
      ) == multiline
    )

    let noFinalNewline = "wrap = true"
    let noFinalOwnership = try EnvironmentTuicrDocument.ownership(
      for: noFinalNewline,
      source: source
    )
    let appended = try EnvironmentTuicrDocument.applyingManaged(
      to: noFinalNewline,
      source: source
    )
    #expect(appended == "wrap = true\ntheme = \"macarchy-current\"")
    #expect(
      try EnvironmentTuicrDocument.restoringOriginal(
        in: appended,
        ownership: noFinalOwnership,
        source: source
      ) == noFinalNewline
    )
    #expect(
      try EnvironmentTuicrDocument.restoringOriginal(
        in: appended + "\nmouse = false\n",
        ownership: noFinalOwnership,
        source: source
      ) == "wrap = true\nmouse = false\n"
    )

    let originalSelectorWithoutFinalNewline = "wrap = true\ntheme = \"personal\""
    let originalSelectorOwnership = try EnvironmentTuicrDocument.ownership(
      for: originalSelectorWithoutFinalNewline,
      source: source
    )
    let managedOriginalSelector = try EnvironmentTuicrDocument.applyingManaged(
      to: originalSelectorWithoutFinalNewline,
      source: source
    )
    #expect(
      try EnvironmentTuicrDocument.restoringOriginal(
        in: managedOriginalSelector + "\nmouse = false\n",
        ownership: originalSelectorOwnership,
        source: source
      ) == "wrap = true\ntheme = \"personal\"\nmouse = false\n"
    )
  }

  @Test
  func lateAuthorityPublicationFailureRollsBackSelectionAndOwnership() async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let checkpointObserved = Mutex(false)
    let interruptedTransaction = Mutex<EnvironmentTransaction?>(nil)

    let result = try await fixture.apply { checkpoint in
      guard checkpoint == .authorityPublished else { return }
      #expect(EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
      interruptedTransaction.withLock {
        $0 = try? EnvironmentStateStore(stateRoot: fixture.state).readTransaction()
      }
      #expect(
        try ThemeRuntimeSelection.enabledAdapterIDs(
          stateRoot: fixture.state,
          homeDirectory: fixture.home
        ).contains(TuicrAdapter.id)
      )
      checkpointObserved.withLock { $0 = true }
      throw TuicrFixtureError.injectedFailure
    }

    #expect(!result.succeeded)
    #expect(checkpointObserved.withLock { $0 })
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(TuicrAdapter.id)
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))

    try EnvironmentStateStore(stateRoot: fixture.state).writeTransaction(
      try #require(interruptedTransaction.withLock { $0 })
    )
    #expect(
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    )
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(TuicrAdapter.id)
    )
    let recoveredOwnership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    let replacementName = ".macarchy-environment-tuicr-claimed.replacement"
    try EnvironmentStateStore(stateRoot: fixture.state).writeTransaction(
      EnvironmentTransaction(
        operation: .teardown,
        previousOwnership: recoveredOwnership,
        proposedOwnership: nil,
        previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: fixture.state)
          .currentDestination(),
        tuicrReplacementName: replacementName
      )
    )
    try FileManager.default.moveItem(
      at: fixture.configuration,
      to: fixture.configuration.deletingLastPathComponent().appending(path: replacementName)
    )
    #expect(
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.syntaxLink.path))
    #expect(
      try !ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains(TuicrAdapter.id)
    )
  }

  @Test
  func driftIsVisibleAndInterruptedTeardownRecoversTheOwnedKeyAndLinks() async throws {
    let fixture = try TuicrFixture(configuration: "wrap = true\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.activateTheme()
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.apply(adopt: digest).succeeded)
    try "theme = \"wrong\"\nwrap = true\n".write(
      to: fixture.configuration,
      atomically: true,
      encoding: .utf8
    )
    let driftedStatus = try fixture.status()
    #expect(!driftedStatus.succeeded)
    #expect(!fixture.applySyncPreview().succeeded)
    let driftedTeardown = try fixture.teardown()
    #expect(!driftedTeardown.succeeded)
    #expect(try fixture.link(fixture.themeLink) == fixture.themeDestination.path)
    #expect(try fixture.link(fixture.syntaxLink) == fixture.syntaxDestination.path)
    #expect(!EnvironmentStateStore(stateRoot: fixture.state).transactionExists)

    try "theme = \"macarchy-current\"\nwrap = true\n".write(
      to: fixture.configuration,
      atomically: true,
      encoding: .utf8
    )
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let observedOwnership = try store.readOwnership()
    let ownership = try #require(observedOwnership)
    try store.writeTransaction(
      EnvironmentTransaction(
        operation: .teardown,
        previousOwnership: ownership,
        proposedOwnership: nil,
        previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: fixture.state)
          .currentDestination(),
        btopReplacementName: nil,
        tuicrReplacementName: ".macarchy-environment-tuicr-recovery.replacement"
      )
    )

    #expect(
      try EnvironmentTransactionCoordinator(
        homeDirectory: fixture.home,
        stateRoot: fixture.state
      ).recoverLocked()
    )
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8) == "wrap = true\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.themeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.syntaxLink.path))
  }

  @Test(arguments: [ExternalTuicrLayout.configurationSymlink, .directorySymlink])
  func exactExternalTupleOnlyPublishesAndRemovesAuthority(
    layout: ExternalTuicrLayout
  ) async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.installExternalTuple(layout: layout, selector: "macarchy-current")
    try fixture.activateTheme()
    let original = try fixture.externalTupleSnapshot()

    let plan = try fixture.plan()
    #expect(plan.succeeded)
    let plannedEntries = try #require(try jsonObject(plan.output)["entries"] as? [[String: Any]])
    #expect(
      Dictionary(
        uniqueKeysWithValues: plannedEntries.compactMap { entry -> (String, String)? in
          guard let id = entry["id"] as? String, id.hasPrefix("tuicr_") else { return nil }
          return (id, entry["ownership"] as? String ?? "")
        }
      ) == [
        "tuicr_configuration": "external_exact",
        "tuicr_theme": "external_exact",
        "tuicr_syntax": "external_exact",
      ]
    )

    let applied = try await fixture.apply()
    #expect(applied.succeeded)
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(ownership.tuicrEnabled)
    #expect(ownership.tuicr == nil)
    #expect(
      ownership.records.allSatisfy { $0.id != .tuicrTheme && $0.id != .tuicrSyntax }
    )
    #expect(try fixture.externalTupleSnapshot() == original)

    let status = try fixture.status()
    #expect(status.succeeded)
    let statusEntries = try #require(
      try jsonObject(status.output)["entries"] as? [[String: Any]]
    )
    #expect(
      statusEntries.filter { ($0["id"] as? String)?.hasPrefix("tuicr_") == true }
        .allSatisfy { $0["ownership"] as? String == "external_exact" }
    )
    #expect(try fixture.externalTupleSnapshot() == original)

    let noOp = try await fixture.apply()
    #expect(noOp.succeeded)
    #expect(try jsonObject(noOp.output)["outcome"] as? String == "no_change")
    #expect(try fixture.externalTupleSnapshot() == original)

    try fixture.writeProfile(tuicr: false)
    let disabled = try await fixture.apply()
    #expect(disabled.succeeded)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try fixture.externalTupleSnapshot() == original)

    try fixture.writeProfile(tuicr: true)
    #expect(try await fixture.apply().succeeded)
    let teardown = try fixture.teardown()
    #expect(teardown.succeeded)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(try fixture.externalTupleSnapshot() == original)
  }

  @Test(arguments: [ExternalTuicrLayout.configurationSymlink, .directorySymlink])
  func divergentExternalSelectorBlocksBeforeMutation(layout: ExternalTuicrLayout) async throws {
    let fixture = try TuicrFixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.installExternalTuple(layout: layout, selector: "personal")
    try fixture.activateTheme()
    let original = try fixture.externalTupleSnapshot()

    let plan = try fixture.plan()
    #expect(!plan.succeeded)
    #expect(plan.output.contains("divergent tuicr selector"))
    let applied = try await fixture.apply()
    #expect(!applied.succeeded)
    #expect(applied.output.contains("divergent tuicr selector"))
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    #expect(
      try EnvironmentGenerationStore(stateRoot: fixture.state).currentDestination() == nil
    )
    #expect(try fixture.externalTupleSnapshot() == original)
  }

  @Test
  func completeLegacySetupOwnershipKeepsTuicrSelectedWithoutProfileAdoption() throws {
    let fixture = try TuicrFixture(configuration: "wrap = true\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    try FileManager.default.createDirectory(
      at: fixture.themeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var records = [SetupOwnershipRecord]()
    let manager = SetupOwnershipManager()
    _ = try manager.setupTuicrThemeLink(context: context, dryRun: false, records: &records)
    _ = try manager.setupTuicrSyntaxLink(context: context, dryRun: false, records: &records)
    _ = try manager.setupTuicrSelector(context: context, dryRun: false, records: &records)
    try fixture.writeProfile(tuicr: false)

    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ).contains("tuicr")
    )
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
      EnvironmentOwnership(
        generationID: "e-\(UUID().uuidString.lowercased())",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        enabledThemeAdapterIDs: []
      )
    )
    #expect(
      try ThemeRuntimeSelection.enabledAdapterIDs(
        stateRoot: fixture.state,
        homeDirectory: fixture.home
      ) == [TuicrAdapter.id]
    )
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(nil)
    let plan = try fixture.plan()
    #expect(plan.succeeded)
    #expect(plan.output.contains("legacy_setup"))
    let entries = try #require(try jsonObject(plan.output)["entries"] as? [[String: Any]])
    #expect(
      Set(entries.compactMap { $0["id"] as? String })
        == ["tuicr_configuration", "tuicr_theme", "tuicr_syntax"]
    )
    #expect(try String(contentsOf: fixture.configuration, encoding: .utf8).contains("wrap = true"))

    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
      EnvironmentOwnership(
        generationID: "e-\(UUID().uuidString.lowercased())",
        records: [],
        createdDirectories: [],
        originalThemeBridges: [],
        tuicrEnabled: true
      )
    )
    let overlap = try TeardownCommandRunner(ownershipManager: manager).execute(
      homeDirectory: fixture.home,
      dryRun: false,
      json: false
    )
    #expect(!overlap.succeeded)
    #expect(overlap.output.contains("tuicr.selector [failed]"))
    #expect(overlap.output.contains("[presets].tuicr = false"))
    #expect(overlap.output.contains("macarchy environment apply"))
    #expect(
      Set(try manager.readRecords(context: context).map(\.id)).isSuperset(of: [
        SetupOwnershipManager.tuicrSelectorID,
        SetupOwnershipManager.tuicrThemeLinkID,
        SetupOwnershipManager.tuicrSyntaxLinkID,
      ])
    )
    #expect(try fixture.link(fixture.themeLink) == fixture.themeDestination.path)
    #expect(try fixture.link(fixture.syntaxLink) == fixture.syntaxDestination.path)
    try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(nil)

    try FileManager.default.removeItem(at: fixture.themeLink)
    try FileManager.default.createSymbolicLink(
      at: fixture.themeLink,
      withDestinationURL: fixture.root.appending(path: "wrong-theme.toml")
    )
    let drifted = try fixture.plan()
    #expect(!drifted.succeeded)
    #expect(drifted.output.contains("legacy setup-owned tuicr_theme"))
  }
}

private enum TuicrFixtureError: Error {
  case injectedFailure
}

enum ExternalTuicrLayout: Sendable {
  case configurationSymlink
  case directorySymlink
}

private struct ExternalTuicrSnapshot: Equatable {
  struct Entry: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let linkDestination: String?
    let data: Data?
  }

  let entries: [String: Entry]
}

private struct TuicrFixture {
  let root: URL
  let home: URL
  let state: URL
  let profile: URL
  let configuration: URL
  let themeLink: URL
  let syntaxLink: URL
  let themeDestination: URL
  let syntaxDestination: URL

  init(configuration contents: String?) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-tuicr-preset-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    state = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    profile = root.appending(path: "profile.toml")
    configuration = home.appending(path: ".config/tuicr/config.toml")
    themeLink = home.appending(path: ".config/tuicr/themes/macarchy-current.toml")
    syntaxLink = home.appending(path: ".config/tuicr/themes/macarchy-current.tmTheme")
    themeDestination = state.appending(path: "current/generated/tuicr.toml")
    syntaxDestination = state.appending(path: "current/generated/bat.tmTheme")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if let contents {
      try FileManager.default.createDirectory(
        at: configuration.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: configuration, atomically: true, encoding: .utf8)
    }
    try writeProfile(tuicr: true)
  }

  func writeProfile(tuicr: Bool, bat: Bool = false) throws {
    try """
    schema_version = 1
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    [editor]
    provider = "disabled"
    [tools]
    bat = \(bat)
    eza = false
    btop = false
    yazi = false
    [presets]
    tuicr = \(tuicr)
    """.write(to: profile, atomically: true, encoding: .utf8)
  }

  func runtimeConsumerPaths() -> ThemeConsumerPaths {
    let paths = testConsumerPaths()
    return ThemeConsumerPaths(
      kittyConfigurationURL: paths.kittyConfigurationURL,
      sketchyBarConfigurationURL: paths.sketchyBarConfigurationURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      ezaConfigurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      batConfigurationDirectoryURL: paths.batConfigurationDirectoryURL,
      batCacheDirectoryURL: paths.batCacheDirectoryURL,
      btopConfigurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      yaziConfigurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      atuinConfigurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
      neovimConfigurationDirectoryURL: paths.neovimConfigurationDirectoryURL,
      starshipConfigurationURL: paths.starshipConfigurationURL,
      starshipBehaviorURL: root.appending(path: "missing-starship-behavior.toml"),
      piConfigurationDirectoryURL: paths.piConfigurationDirectoryURL,
      herdrConfigurationURL: paths.herdrConfigurationURL,
      tuicrConfigurationDirectoryURL: configuration.deletingLastPathComponent(),
      codexConfigurationDirectoryURL: paths.codexConfigurationDirectoryURL,
      spicetifyConfigurationDirectoryURL: paths.spicetifyConfigurationDirectoryURL
    )
  }

  func activateTheme() throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    _ = try ThemeActivator(root: state).activate(package: package)
  }

  func installExternalTuple(layout: ExternalTuicrLayout, selector: String) throws {
    let external = root.appending(path: "dotfiles/tuicr", directoryHint: .isDirectory)
    let externalConfiguration = external.appending(path: "config.toml")
    let externalThemes = external.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: externalThemes, withIntermediateDirectories: true)
    try "theme = \"\(selector)\"\nwrap = true\n".write(
      to: externalConfiguration,
      atomically: true,
      encoding: .utf8
    )

    switch layout {
    case .configurationSymlink:
      try FileManager.default.createDirectory(
        at: themeLink.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        atPath: configuration.path,
        withDestinationPath: "../../../dotfiles/tuicr/config.toml"
      )
    case .directorySymlink:
      try FileManager.default.createSymbolicLink(
        atPath: configuration.deletingLastPathComponent().path,
        withDestinationPath: "../../dotfiles/tuicr"
      )
    }
    try FileManager.default.createSymbolicLink(
      at: layout == .configurationSymlink
        ? themeLink : externalThemes.appending(path: themeLink.lastPathComponent),
      withDestinationURL: themeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: layout == .configurationSymlink
        ? syntaxLink : externalThemes.appending(path: syntaxLink.lastPathComponent),
      withDestinationURL: syntaxDestination
    )
  }

  func externalTupleSnapshot() throws -> ExternalTuicrSnapshot {
    let external = root.appending(path: "dotfiles/tuicr", directoryHint: .isDirectory)
    let paths = [
      configuration.deletingLastPathComponent(),
      configuration,
      themeLink,
      syntaxLink,
      external,
      external.appending(path: "config.toml"),
      external.appending(path: "themes", directoryHint: .isDirectory),
      external.appending(path: "themes/(themeLink.lastPathComponent)"),
      external.appending(path: "themes/(syntaxLink.lastPathComponent)"),
    ]
    var entries = [String: ExternalTuicrSnapshot.Entry]()
    for path in paths {
      var metadata = stat()
      guard lstat(path.path, &metadata) == 0 else {
        if errno == ENOENT { continue }
        throw EnvironmentLifecycleError.system("snapshot external tuicr tuple", path, errno)
      }
      let kind = metadata.st_mode & S_IFMT
      entries[path.path] = ExternalTuicrSnapshot.Entry(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        mode: UInt32(metadata.st_mode),
        size: Int64(metadata.st_size),
        linkDestination: kind == S_IFLNK
          ? try FileManager.default.destinationOfSymbolicLink(atPath: path.path) : nil,
        data: kind == S_IFREG ? try BoundedRegularFile.read(at: path).data : nil
      )
    }
    return ExternalTuicrSnapshot(entries: entries)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    adopt: String? = nil,
    prerequisites: EnvironmentPrerequisiteInspector = .assumed,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentApplyCommandRunner(
      prerequisites: prerequisites,
      theme: themeController,
      verifier: .assumed,
      transactionFaultInjector: faultInjector
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      adopt: adopt,
      json: true
    )
  }

  func applySyncPreview() -> (output: String, succeeded: Bool) {
    (try? plan()) ?? ("", false)
  }

  func status() throws -> (output: String, succeeded: Bool) {
    try EnvironmentStatusCommandRunner(prerequisites: .assumed, theme: themeController).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: testConsumerPaths(),
      json: true
    )
  }

  func teardown() throws -> (output: String, succeeded: Bool) {
    try EnvironmentTeardownCommandRunner().execute(
      stateRoot: state,
      homeDirectory: home,
      dryRun: false,
      json: true
    )
  }

  func link(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  private var themeController: DesktopThemeController {
    DesktopThemeController(
      reconcile: { adapterIDs, _, _ in
        DesktopThemeReconciliation(
          generationID: "theme",
          results: adapterIDs.map {
            DesktopThemeAdapterStatus(
              adapterID: $0,
              requirement: "required",
              status: "restart_required",
              message: "Restart tuicr to use the active palette"
            )
          },
          succeeded: true
        )
      },
      inspect: { adapterIDs, _, _ in
        adapterIDs.map {
          DesktopThemeAdapterStatus(
            adapterID: $0,
            requirement: "required",
            status: "ready",
            message: "Fresh tuicr sessions use the active palette"
          )
        }
      }
    )
  }
}
