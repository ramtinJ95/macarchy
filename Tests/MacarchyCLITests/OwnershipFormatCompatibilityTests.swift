import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Ownership state written by released versions must keep decoding, validating and re-encoding
/// with the same keys. The fixtures are the compatibility oracle for the shared
/// ownership-transaction engine (ADR-0297): change one only together with an approved format
/// migration, never to make a refactor pass.
struct OwnershipFormatCompatibilityTests {
  // MARK: - Keybindings

  @Test func keybindingTransactionSchemaOneRoundTrips() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)
    let (transaction, url) = try expectRoundTrip(
      "keybindings/transaction-schema1-update.json", at: "keybindings/transaction.json",
      in: fixture, read: store.read, write: store.write)

    #expect(transaction.schemaVersion == 1)
    #expect(transaction.operation == .updateGeneration)
    #expect(transaction.phase == .currentSelected)
    #expect(transaction.service == nil)
    #expect(transaction.withPhase(transaction.phase) == transaction)
    #expect(try filePermissions(url) == 0o600)
  }

  @Test func keybindingTransactionSchemaTwoKeepsCamelCaseServiceChange() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot)

    let (install, _) = try expectRoundTrip(
      "keybindings/transaction-schema2-install.json", at: "keybindings/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(install.schemaVersion == 2)
    // The writer's initializer derives the released schema version from the service change.
    #expect(install.withPhase(install.phase) == install)
    #expect(install.phase == .entryInstalled)
    #expect(install.service?.installationAttempted == true)
    #expect(install.service?.installed?.volumeUUID == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")

    let (teardown, _) = try expectRoundTrip(
      "keybindings/transaction-schema2-teardown.json", at: "keybindings/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(teardown.isFinalizingTeardown)
    #expect(teardown.service?.previousOwnership?.registration.inode == 4242)
  }

  @Test func keybindingTransactionRejectsUnknownFields() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    try fixture.install(
      "keybindings/transaction-schema1-update.json", at: "keybindings/transaction.json",
      editing: addingMember(#""unexpected" : true"#, after: #""generation_created" : true,"#))

    #expect(throws: KeybindingApplyTransactionError.self) {
      try KeybindingApplyTransactionStore(stateRoot: fixture.stateRoot).read()
    }
  }

  @Test func skhdServiceReceiptRoundTripsAndToleratesUnknownFields() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = SkhdServiceOwnershipStore(stateRoot: fixture.stateRoot)
    let (ownership, url) = try expectRoundTrip(
      "keybindings/service.json", at: "keybindings/service.json",
      in: fixture, read: store.read, write: { try store.write($0) })
    #expect(ownership.original.loaded == false)
    #expect(try filePermissions(url) == 0o600)

    try fixture.install(
      "keybindings/service.json", at: "keybindings/service.json",
      editing: addingMember(#""unexpected" : true"#, after: #""inode" : 4242,"#))
    #expect(try store.read() == ownership)
  }

  @Test func keybindingLifecycleEvidenceKeepsItsKeys() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = KeybindingLifecycleEvidenceStore(stateRoot: fixture.stateRoot)
    let data = try fixture.contents("keybindings/lifecycle.json")
    let evidence = try JSONDecoder().decode(KeybindingLifecycleEvidence.self, from: data)
    // The store's reader is private; matching inspection proves it accepted the fixture.
    let inspect = {
      store.inspect(
        generation: KeybindingGenerationInspection(
          status: .current, generationID: evidence.generationID, inputDigest: nil,
          renderedDigest: nil, configuration: nil, message: nil),
        provider: KeybindingProviderInspection(
          status: .managed, entryPoint: evidence.providerEntryPoint, ownership: "managed",
          source: nil, originalTarget: nil, expectedTarget: evidence.providerTarget, message: "",
          adoptionEvidenceDigest: nil, retainedOriginalRequirement: nil,
          retainedOriginalStatus: nil, sourceConfiguration: nil, adoptionEvidence: nil),
        process: KeybindingProcessInspection(
          status: .running, message: "", processID: evidence.processID,
          executablePath: evidence.executablePath, arguments: evidence.arguments)
      ).status
    }

    let url = try fixture.install("keybindings/lifecycle.json", at: "keybindings/lifecycle.json")
    #expect(inspect() == .matched)

    try fixture.removeInstalled(url)
    try store.write(evidence)
    try expectSameJSON(url, as: data)
    #expect(inspect() == .matched)
    #expect(try writesEscapedSlashes(url))
    #expect(try filePermissions(url) == 0o600)

    try fixture.install(
      "keybindings/lifecycle.json", at: "keybindings/lifecycle.json",
      editing: addingMember(#""unexpected" : true"#, after: #""process_id" : 321,"#))
    #expect(inspect() == .invalid)
  }

  @Test func keybindingJournalVocabularyIsStable() {
    for operation in ["adopt_entry", "install_entry", "teardown_entry", "update_generation"] {
      #expect(KeybindingApplyOperation(rawValue: operation) != nil, "\(operation)")
    }
    for phase in [
      "staging", "staged", "current_selected", "entry_installed", "entry_restored", "activating",
      "restoration_finalizing", "restoration_finalized",
    ] {
      #expect(KeybindingApplyPhase(rawValue: phase) != nil, "\(phase)")
    }
  }

  // MARK: - Desktop

  @Test func yabaiTransactionsKeepBothSchemas() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = YabaiTransactionStore(stateRoot: fixture.stateRoot)

    let (legacy, url) = try expectRoundTrip(
      "desktop/yabai-transaction-schema1.json", at: "desktop/yabai/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(legacy.schemaVersion == 1)
    #expect(legacy.service == nil)
    #expect(legacy.ownership.original.kind == .absent)
    #expect(try writesEscapedSlashes(url))

    let (current, _) = try expectRoundTrip(
      "desktop/yabai-transaction-schema2.json", at: "desktop/yabai/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(current.schemaVersion == 2)
    #expect(current.phase == .serviceChanged)
    #expect(current.service?.installed?.inode == 4242)

    let (teardown, _) = try expectRoundTrip(
      "desktop/yabai-transaction-schema2-teardown.json", at: "desktop/yabai/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(teardown.operation == .teardown)
    #expect(teardown.previousLifecycle?.runtime.status == .converged)
    #expect(teardown.service?.previousOwnership?.registration.inode == 4242)

    // The writer's initializer derives the released schema version from the service change.
    for transaction in [legacy, current, teardown] {
      #expect(
        YabaiTransaction(
          operation: transaction.operation, phase: transaction.phase,
          generationID: transaction.generationID,
          previousGenerationID: transaction.previousGenerationID,
          generationCreated: transaction.generationCreated, ownership: transaction.ownership,
          previousOwnership: transaction.previousOwnership,
          previousLifecycle: transaction.previousLifecycle,
          serviceWasRunning: transaction.serviceWasRunning, service: transaction.service)
          == transaction)
    }
  }

  @Test func yabaiOwnershipKeepsCamelCaseEvidenceAndDeviceOnlyRecords() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = YabaiOwnershipStore(stateRoot: fixture.stateRoot)

    let (current, _) = try expectRoundTrip(
      "desktop/yabai-ownership.json", at: "desktop/yabai/ownership.json",
      in: fixture, read: store.read, write: store.write)
    #expect(current.original.volumeUUID == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")

    let (legacy, _) = try expectRoundTrip(
      "desktop/yabai-ownership-legacy-device-only.json", at: "desktop/yabai/ownership.json",
      in: fixture, read: store.read, write: store.write)
    #expect(legacy.original.volumeUUID == nil)
    #expect(legacy.original.device == 16_777_234)
  }

  @Test func yabaiLifecycleAndServiceReceiptRoundTrip() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let lifecycle = YabaiLifecycleEvidenceStore(stateRoot: fixture.stateRoot)
    let (evidence, _) = try expectRoundTrip(
      "desktop/yabai-lifecycle.json", at: "desktop/yabai/lifecycle.json",
      in: fixture, read: lifecycle.read, write: lifecycle.write)
    #expect(evidence.runtime.status == .converged)

    let service = YabaiServiceOwnershipStore(stateRoot: fixture.stateRoot)
    let (ownership, url) = try expectRoundTrip(
      "desktop/yabai-service.json", at: "desktop/yabai/service.json",
      in: fixture, read: service.read, write: { try service.write($0) })
    #expect(ownership.registration.permissions == 0o644)
    #expect(try filePermissions(url) == 0o600)
  }

  @Test func sketchyBarTransactionsRoundTrip() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = SketchyBarTransactionStore(stateRoot: fixture.stateRoot)

    let (apply, _) = try expectRoundTrip(
      "desktop/sketchybar-transaction-apply.json", at: "desktop/sketchybar/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(apply.schemaVersion == 3)
    #expect(apply.phase == .generationPublished)

    let (teardown, _) = try expectRoundTrip(
      "desktop/sketchybar-transaction-teardown.json", at: "desktop/sketchybar/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(teardown.teardownGenerationIDs == [teardown.generationID])
    #expect(teardown.previousLifecycle?.coreRuntime.nativeConfiguration == true)
  }

  @Test func sketchyBarOwnershipKeepsDeviceOnlyRecords() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = SketchyBarOwnershipStore(stateRoot: fixture.stateRoot)

    let (current, _) = try expectRoundTrip(
      "desktop/sketchybar-ownership.json", at: "desktop/sketchybar/ownership.json",
      in: fixture, read: store.read, write: store.write)
    #expect(current.original.volumeUUID == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")

    let (legacy, _) = try expectRoundTrip(
      "desktop/sketchybar-ownership-legacy-device-only.json",
      at: "desktop/sketchybar/ownership.json",
      in: fixture, read: store.read, write: store.write)
    #expect(legacy.original.volumeUUID == nil)
  }

  @Test func sketchyBarLifecycleKeepsOlderCoreRuntimeEvidence() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = SketchyBarLifecycleEvidenceStore(stateRoot: fixture.stateRoot)

    let (current, _) = try expectRoundTrip(
      "desktop/sketchybar-lifecycle.json", at: "desktop/sketchybar/lifecycle.json",
      in: fixture, read: store.read, write: store.write)
    #expect(current.coreRuntime.nativeConfiguration == true)

    let (legacy, _) = try expectRoundTrip(
      "desktop/sketchybar-lifecycle-legacy-core-runtime.json",
      at: "desktop/sketchybar/lifecycle.json",
      in: fixture, read: store.read, write: store.write)
    #expect(legacy.coreRuntime.volumeLevelPresent == nil)
    #expect(legacy.runtime.serviceLabel == "sh.brew.sketchybar")
  }

  @Test func desktopAggregateJournalRoundTrips() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = DesktopAggregateTransactionStore(stateRoot: fixture.stateRoot)
    let (transaction, _) = try expectRoundTrip(
      "desktop/aggregate-transaction.json", at: "desktop/aggregate-transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(transaction.phase == .committing)
  }

  @Test func desktopStoresTolerateUnknownFields() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    try fixture.install(
      "desktop/yabai-transaction-schema1.json", at: "desktop/yabai/transaction.json",
      editing: addingMember(#""unexpected" : true"#, after: #""generation_created" : true,"#))
    #expect(try YabaiTransactionStore(stateRoot: fixture.stateRoot).read() != nil)

    try fixture.install(
      "desktop/sketchybar-ownership.json", at: "desktop/sketchybar/ownership.json",
      editing: addingMember(
        #""unexpected" : true"#, after: #""created_configuration_directory" : false,"#))
    #expect(try SketchyBarOwnershipStore(stateRoot: fixture.stateRoot).read() != nil)
  }

  @Test func desktopJournalVocabularyIsStable() {
    for phase in [
      "prepared", "generation_published", "generation_selected", "provider_changing",
      "provider_changed", "service_changing", "service_changed",
    ] {
      #expect(SketchyBarTransactionPhase(rawValue: phase) != nil, "\(phase)")
    }
    for phase in [
      "prepared", "provider_changing", "provider_changed", "service_changing", "service_changed",
    ] {
      #expect(YabaiTransactionPhase(rawValue: phase) != nil, "\(phase)")
    }
    for phase in ["mutating", "committing"] {
      #expect(DesktopAggregatePhase(rawValue: phase) != nil, "\(phase)")
    }
  }

  // MARK: - Setup

  @Test func setupManifestRoundTripsSharedRecords() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let manager = SetupOwnershipManager()
    let context = fixture.setupContext
    let (records, url) = try expectRoundTrip(
      "setup/ownership.json", at: "state/setup/ownership.json", in: fixture,
      read: { try manager.readRecords(context: context) },
      write: { try manager.persist(records: $0, context: context) })

    #expect(records.map(\.id) == ["bat.theme-link", "keybindings.skhd-entry", "kitty.include"])
    #expect(records[1].originalKind == .symbolicLink)
    #expect(try writesEscapedSlashes(url))
    #expect(try filePermissions(url) == 0o600)
  }

  @Test func setupManifestAcceptsLegacyAndRegularFileKeybindingRecords() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let manager = SetupOwnershipManager()
    let context = fixture.setupContext

    let (legacy, _) = try expectRoundTrip(
      "setup/ownership-keybinding-legacy-clean-install.json", at: "state/setup/ownership.json",
      in: fixture, read: { try manager.readRecords(context: context) },
      write: { try manager.persist(records: $0, context: context) })
    #expect(KeybindingProviderInspector.isLegacyCleanInstallRecord(try #require(legacy.first)))

    let (regular, _) = try expectRoundTrip(
      "setup/ownership-keybinding-regular-file.json", at: "state/setup/ownership.json",
      in: fixture, read: { try manager.readRecords(context: context) },
      write: { try manager.persist(records: $0, context: context) })
    #expect(regular.first?.originalKind == .regularFile)
    #expect(regular.first?.phase == .teardownPrepared)
  }

  @Test func setupManifestRejectsUnknownFieldsAndVolumeBoundKeybindingFiles() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let manager = SetupOwnershipManager()
    let context = fixture.setupContext

    try fixture.install(
      "setup/ownership.json", at: "state/setup/ownership.json",
      editing: addingMember(#""unexpected" : true"#, after: #""id" : "kitty.include","#))
    #expect(throws: (any Error).self) { try manager.readRecords(context: context) }

    // ADR-0265 left skhd regular-file adoption bound to its device, not a volume UUID.
    try fixture.install(
      "setup/ownership-keybinding-regular-file.json", at: "state/setup/ownership.json",
      editing: addingMember(
        #""original_volume_uuid" : "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE""#,
        after: #""original_source_digest" : "sha256:"#
          + String(repeating: "a", count: 64) + #"","#))
    #expect(throws: (any Error).self) { try manager.readRecords(context: context) }
  }

  @Test func unifiedSetupJournalRoundTripsAndRejectsUnknownFields() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = UnifiedSetupTransactionStore(stateRoot: fixture.stateRoot)

    let (apply, url) = try expectRoundTrip(
      "setup/transaction-apply.json", at: "state/setup/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(apply.phase == .committing)
    #expect(try filePermissions(url) == 0o600)

    let (teardown, _) = try expectRoundTrip(
      "setup/transaction-teardown.json", at: "state/setup/transaction.json",
      in: fixture, read: store.read, write: store.write)
    #expect(teardown.stages == [.environment, .desktop])

    try fixture.install(
      "setup/transaction-apply.json", at: "state/setup/transaction.json",
      editing: addingMember(#""unexpected" : true"#, after: #""operation" : "apply","#))
    #expect(throws: UnifiedSetupTransactionError.self) { try store.read() }
  }

  @Test func setupResidueAndBackupNamesAreStable() {
    let context = SetupOwnershipManager.Context(homeDirectory: URL(filePath: "/Users/fixture"))
    #expect(
      [
        context.replacementName, context.batSelectorReplacementName,
        context.ezaEnvironmentReplacementName, context.yaziSelectorReplacementName,
        context.atuinSelectorReplacementName, context.piSelectorReplacementName,
        context.tuicrSelectorReplacementName, context.codexSelectorReplacementName,
        context.spicetifySelectorsReplacementName,
      ] == [
        ".macarchy-kitty-transaction", ".macarchy-bat-config-transaction",
        ".macarchy-zshrc-transaction", ".macarchy-yazi-theme-transaction",
        ".macarchy-atuin-config-transaction", ".macarchy-pi-settings-transaction",
        ".macarchy-tuicr-config-transaction", ".macarchy-codex-config-transaction",
        ".macarchy-spicetify-config-transaction",
      ])
    #expect(
      [
        context.backupURL, context.batSelectorBackup, context.ezaEnvironmentBackup,
        context.yaziSelectorBackup, context.atuinSelectorBackup, context.tuicrSelectorBackup,
        context.codexSelectorBackup, context.spicetifySelectorsBackup,
      ].map(\.lastPathComponent) == [
        "kitty.conf", "bat-config", "zshrc", "yazi-theme.toml", "atuin-config.toml",
        "tuicr-config.toml", "codex-config.toml", "spicetify-config-xpui.ini",
      ])
  }

  // MARK: - Environment

  @Test func environmentOwnershipKeepsDerivedSchemaVersions() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = EnvironmentStateStore(stateRoot: fixture.stateRoot)
    let read = { try store.readOwnership() }
    let write = { (ownership: EnvironmentOwnership) in try store.writeOwnership(ownership) }

    let (first, url) = try expectRoundTrip(
      "environment/ownership-schema1.json", at: "environment/ownership.json",
      in: fixture, read: read, write: write)
    #expect(first.schemaVersion == 1)
    #expect(first.records.map(\.id) == [.batTheme, .kitty])
    #expect(try writesEscapedSlashes(url))
    #expect(try filePermissions(url) == 0o600)

    let (second, _) = try expectRoundTrip(
      "environment/ownership-schema2.json", at: "environment/ownership.json",
      in: fixture, read: read, write: write)
    #expect(second.schemaVersion == 2)
    #expect(second.standardNativeEntries == [.atuinConfiguration, .zsh])
    #expect(second.originalThemeBridges.first?.mode == 0o644)

    let (third, _) = try expectRoundTrip(
      "environment/ownership-schema3-lean-presets.json", at: "environment/ownership.json",
      in: fixture, read: read, write: write)
    #expect(third.schemaVersion == 3)
    #expect(third.borders?.leanService?.stateRoot == fixture.stateRoot.path)
    #expect(third.borders?.retainsBorders == false)
    #expect(third.btop?.originalAssignments.count == 6)
    #expect(third.codex?.introducedTable == true)
    #expect(third.herdr?.managedTheme.name == "tokyo-night")
    #expect(third.pi?.originalMember == Data(#""theme": "dark""#.utf8))
    #expect(third.spicetify?.originalTheme == "SpicetifyDefault")
    #expect(third.tuicr?.originalFileExisted == false)

    // The writer's initializer derives the released schema version from the content.
    for ownership in [first, second, third] {
      #expect(
        EnvironmentOwnership(
          copying: ownership, generationID: ownership.generationID, records: ownership.records,
          herdr: ownership.herdr, enabledThemeAdapterIDs: ownership.enabledThemeAdapterIDs,
          standardNativeEntries: ownership.standardNativeEntries ?? [])
          == ownership)
    }
  }

  @Test func environmentOwnershipDecodesTheMinimalLegacyShape() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    try fixture.install(
      "environment/ownership-legacy-minimal.json", at: "environment/ownership.json")

    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.stateRoot).readOwnership())
    #expect(ownership.schemaVersion == 1)
    #expect(!ownership.codexEnabled && !ownership.herdrEnabled && !ownership.piEnabled)
    #expect(ownership.enabledThemeAdapterIDs == nil)
    #expect(ownership.standardNativeEntries == nil)
  }

  @Test func environmentStoreToleratesUnknownFields() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    try fixture.install(
      "environment/ownership-schema1.json", at: "environment/ownership.json",
      editing: addingMember(#""unexpected" : true"#, after: #""codex_enabled" : false,"#))
    #expect(try EnvironmentStateStore(stateRoot: fixture.stateRoot).readOwnership() != nil)
  }

  @Test func environmentJournalRoundTripsBothDirectionsOfWork() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let store = EnvironmentStateStore(stateRoot: fixture.stateRoot)
    let read = { try store.readTransaction() }
    let write = { (transaction: EnvironmentTransaction) in try store.writeTransaction(transaction) }

    let (apply, url) = try expectRoundTrip(
      "environment/transaction-apply-forward.json", at: "environment/transaction.json",
      in: fixture, read: read, write: write)
    #expect(apply.operation == .apply)
    #expect(apply.direction == .forward)
    #expect(apply.previousThemeGenerationID == "g-11111111-1111-4111-8111-111111111111")
    #expect(try filePermissions(url) == 0o600)

    let (teardown, _) = try expectRoundTrip(
      "environment/transaction-teardown-forward.json", at: "environment/transaction.json",
      in: fixture, read: read, write: write)
    #expect(teardown.operation == .teardown)
    #expect(teardown.proposedOwnership == nil)
    let bridge = try #require(teardown.rollbackThemeBridges.first)
    #expect(bridge.path == fixture.stateRoot.appending(path: "state/adapters/kitty.conf").path)
    #expect(bridge.data == Data("include ../../current/generated/kitty.conf\n".utf8))
    #expect(bridge.mode == 0o644)
  }

  @Test func spicetifyRecoveryMarkerRoundTrips() throws {
    let fixture = try OwnershipFormatFixture()
    defer { fixture.remove() }
    let url = try fixture.install(
      "environment/spicetify-recovery.json", at: "environment/spicetify-recovery.json")
    let store = EnvironmentStateStore(stateRoot: fixture.stateRoot)
    #expect(try store.hasUnverifiedSpicetifyRecovery())

    try fixture.removeInstalled(url)
    try store.recordUnverifiedSpicetifyRecovery()
    try expectSameJSON(url, as: fixture.contents("environment/spicetify-recovery.json"))
  }

  @Test func environmentReplacementNamesKeepTheirShape() {
    let name = EnvironmentReplacementNames.reserve("pi")
    #expect(name.hasPrefix(".macarchy-environment-pi-"))
    #expect(name.hasSuffix(".replacement"))
    #expect(EnvironmentReplacementNames.isValid(name, preset: "pi", required: true))
  }
}

/// Reads the installed fixture through the released reader, writes the decoded value back
/// through the released writer, requires the same JSON document and reads it once more.
private func expectRoundTrip<Value>(
  _ name: String,
  at relativePath: String,
  in fixture: OwnershipFormatFixture,
  read: () throws -> Value?,
  write: (Value) throws -> Void,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> (Value, URL) {
  let url = try fixture.install(name, at: relativePath)
  let value = try #require(try read(), "\(name) did not decode", sourceLocation: sourceLocation)
  try fixture.removeInstalled(url)
  try write(value)
  try expectSameJSON(url, as: fixture.contents(name), sourceLocation: sourceLocation)
  _ = try #require(try read(), "rewritten \(name) did not decode", sourceLocation: sourceLocation)
  return (value, url)
}
