import Darwin
import Foundation
import ThemeCore

enum EnvironmentLifecycleError: Error, CustomStringConvertible, Sendable {
  case adoptionRequired(String)
  case blocked(String)
  case drift(String)
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .adoptionRequired(let digest):
      "environment adoption requires the reviewed evidence digest \(digest)"
    case .blocked(let reason):
      "environment lifecycle is blocked: \(reason)"
    case .drift(let reason):
      "environment ownership drifted: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(errnoDescription(code))"
    }
  }
}

enum EnvironmentTransactionCheckpoint: Equatable, Sendable {
  case authorityPublished
}

/// Whether recovery moved journaled files, and which provider runtimes must still be restored
/// before the journal can be removed.
struct EnvironmentRecoveryPreparation: Sendable {
  var recovered: Bool
  var herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget? = nil
  var spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget? = nil
  var bordersRuntimeTarget: EnvironmentBordersRuntimeTarget? = nil

  static let noTransaction = Self(recovered: false)
  static let finished = Self(recovered: true)

  var awaitsProviderRuntime: Bool {
    herdrRuntimeTarget != nil || spicetifyRuntimeTarget != nil || bordersRuntimeTarget != nil
  }
}

struct EnvironmentTransactionCoordinator: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  var faultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void
  private let inspector: EnvironmentProviderInspector

  init(
    homeDirectory: URL,
    stateRoot: URL,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in },
    inspector: EnvironmentProviderInspector = EnvironmentProviderInspector()
  ) {
    self.homeDirectory = homeDirectory
    self.stateRoot = stateRoot
    self.faultInjector = faultInjector
    self.inspector = inspector
  }

  private var providerEntries: EnvironmentProviderEntries {
    EnvironmentProviderEntries(homeDirectory: homeDirectory, inspector: inspector)
  }

  func recoverLocked() throws -> Bool {
    let result = try prepareRecoveryLocked()
    guard !result.awaitsProviderRuntime else {
      throw EnvironmentLifecycleError.blocked(
        "interrupted provider runtime restoration must finish before recovery can finish"
      )
    }
    return result.recovered
  }

  func prepareRecoveryLocked() throws -> EnvironmentRecoveryPreparation {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else { return .noTransaction }
    if transaction.operation.nativeConnectionProvider != nil {
      try finishNativeFileConnectionLocked(transaction)
      return .finished
    }
    if transaction.operation == .neovimConnection {
      try finishNeovimConnectionLocked(transaction)
      return .finished
    }
    if transaction.operation == .standardMigration {
      try finishStandardMigrationLocked(transaction)
      return .finished
    }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    switch transaction.direction {
    case .forward:
      switch transaction.operation {
      case .standardMigration, .neovimConnection, .atuinConnection, .starshipConnection,
        .zshConnection, .kittyConnection:
        throw EnvironmentLifecycleError.blocked("standard migration requires scoped recovery")
      case .apply, .herdrTheme, .neovimMigration, .atuinMigration, .starshipMigration:
        guard let proposed = transaction.proposedOwnership else {
          throw EnvironmentLifecycleError.blocked("apply recovery has no proposed ownership")
        }
        if transaction.operation == .apply {
          _ = try EnvironmentGenerationStore(stateRoot: stateRoot).manifest(
            generationID: proposed.generationID
          )
        }
        try transition(
          from: transaction.previousOwnership,
          to: proposed,
          replacementNames: transaction.replacementNames,
          herdrThemeOnly: transaction.operation == .herdrTheme,
          neovimOnly: transaction.operation == .neovimMigration,
          nativeFileOnly: transaction.operation.nativeFileProvider
        )
        if transaction.operation == .apply {
          try restoreReleasedThemeBridges(from: transaction.previousOwnership, to: proposed)
          try EnvironmentGenerationStore(stateRoot: stateRoot).select(proposed.generationID)
        }
        try store.writeOwnership(proposed)
      case .teardown:
        try transition(
          from: transaction.previousOwnership,
          to: nil,
          replacementNames: transaction.replacementNames
        )
      }
    case .rollback:
      let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
      try transition(
        from: transaction.proposedOwnership,
        to: transaction.previousOwnership,
        replacementNames: transaction.replacementNames,
        preserveLegacyHerdrOnRemoval: preserveLegacyHerdr,
        herdrThemeOnly: transaction.operation == .herdrTheme,
        neovimOnly: transaction.operation == .neovimMigration,
        nativeFileOnly: transaction.operation.nativeFileProvider
      )
      if !transaction.operation.isNativeMigration {
        try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
          transaction.previousCurrentDestination
        )
        try restoreRollbackThemeBridges(transaction)
      }
      try store.writeOwnership(transaction.previousOwnership)
    }

    if let target = transaction.herdrRuntimeTarget,
      transaction.herdrRuntimeVerified != true
    {
      return EnvironmentRecoveryPreparation(
        recovered: true, herdrRuntimeTarget: target,
        spicetifyRuntimeTarget: pendingSpicetifyRuntimeTarget(transaction),
        bordersRuntimeTarget: transaction.pendingBordersRuntimeTarget)
    }
    if let target = pendingSpicetifyRuntimeTarget(transaction) {
      return EnvironmentRecoveryPreparation(
        recovered: true, spicetifyRuntimeTarget: target,
        bordersRuntimeTarget: transaction.pendingBordersRuntimeTarget)
    }
    if let target = transaction.pendingBordersRuntimeTarget {
      return EnvironmentRecoveryPreparation(recovered: true, bordersRuntimeTarget: target)
    }

    switch (transaction.direction, transaction.operation) {
    case (.forward, .standardMigration), (.forward, .neovimConnection),
      (.forward, .atuinConnection), (.forward, .starshipConnection),
      (.forward, .zshConnection), (.forward, .kittyConnection),
      (.forward, .neovimMigration), (.forward, .atuinMigration),
      (.forward, .starshipMigration):
      break
    case (.forward, .apply), (.forward, .herdrTheme):
      if let proposed = transaction.proposedOwnership,
        proposed.herdr?.migratedLegacy == true, !proposed.herdrEnabled
      {
        try discardHerdrLegacyEvidence()
      }
    case (.forward, .teardown):
      try EnvironmentThemeBridgeState(
        entries: transaction.previousOwnership?.originalThemeBridges ?? []
      ).restore()
      try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
      try store.writeOwnership(nil)
      if transaction.previousOwnership?.herdr?.migratedLegacy == true {
        try discardHerdrLegacyEvidence()
      }
    case (.rollback, _):
      break
    }
    if transaction.spicetifyRuntimeDeferred == true {
      try store.recordUnverifiedSpicetifyRecovery()
    }
    try store.removeTransaction()
    return .finished
  }

  private func pendingSpicetifyRuntimeTarget(
    _ transaction: EnvironmentTransaction
  ) -> EnvironmentSpicetifyRuntimeTarget? {
    transaction.spicetifyRuntimeVerified == true || transaction.spicetifyRuntimeDeferred == true
      ? nil : transaction.spicetifyRuntimeTarget
  }

  private func pendingHerdrRuntimeTarget(
    _ transaction: EnvironmentTransaction
  ) -> EnvironmentHerdrRuntimeTarget? {
    transaction.herdrRuntimeVerified == true ? nil : transaction.herdrRuntimeTarget
  }

  func pendingHerdrRuntimeTargetLocked() throws -> EnvironmentHerdrRuntimeTarget? {
    guard let transaction = try EnvironmentStateStore(stateRoot: stateRoot).readTransaction()
    else { return nil }
    return pendingHerdrRuntimeTarget(transaction)
  }

  func markHerdrRuntimeVerifiedLocked(_ target: EnvironmentHerdrRuntimeTarget) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction(),
      transaction.herdrRuntimeTarget == target,
      transaction.herdrRuntimeVerified != true
    else {
      throw EnvironmentLifecycleError.blocked(
        "no matching Herdr runtime restoration is pending"
      )
    }
    try store.writeTransaction(transaction.withHerdrRuntimeVerified)
  }

  func pendingSpicetifyRuntimeTargetLocked() throws -> EnvironmentSpicetifyRuntimeTarget? {
    guard let transaction = try EnvironmentStateStore(stateRoot: stateRoot).readTransaction()
    else { return nil }
    return pendingSpicetifyRuntimeTarget(transaction)
  }

  func markSpicetifyRuntimeVerifiedLocked(
    _ target: EnvironmentSpicetifyRuntimeTarget
  ) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction(),
      transaction.spicetifyRuntimeTarget == target,
      transaction.spicetifyRuntimeVerified != true,
      transaction.spicetifyRuntimeDeferred != true
    else {
      throw EnvironmentLifecycleError.blocked(
        "no matching Spicetify runtime restoration is pending"
      )
    }
    try store.writeTransaction(transaction.withSpicetifyRuntimeVerified)
    try store.clearUnverifiedSpicetifyRecovery()
  }

  /// Explicit recovery only: never relax managed restoration or a forward apply.
  /// File restoration must succeed before acknowledging that native state is unknown.
  func deferOriginalSpicetifyRuntimeLocked() throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard var transaction = try store.readTransaction(),
      transaction.operation == .apply, transaction.direction == .rollback,
      transaction.spicetifyRuntimeTarget == .original,
      transaction.spicetifyRuntimeVerified == nil
    else {
      throw EnvironmentLifecycleError.blocked(
        "only an interrupted apply rolling back to original Spicetify may defer runtime restoration"
      )
    }
    if transaction.spicetifyRuntimeDeferred == true {
      try store.recordUnverifiedSpicetifyRecovery()
      return
    }
    _ = try prepareRecoveryLocked()
    transaction.spicetifyRuntimeDeferred = true
    // Persist visible uncertainty before recording permission to finish the journal.
    try store.recordUnverifiedSpicetifyRecovery()
    try store.writeTransaction(transaction)
  }

  func preflightManagedHerdr(
    _ desired: GeneratedHerdrTheme,
    requireActiveMatch: Bool
  ) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard try store.readTransaction() == nil else {
      throw EnvironmentLifecycleError.blocked(
        "an interrupted environment transaction must be recovered first"
      )
    }
    guard let ownership = try store.readOwnership(), ownership.herdrEnabled,
      let herdr = ownership.herdr
    else {
      throw EnvironmentLifecycleError.blocked("aggregate Herdr ownership is not active")
    }
    _ = try desired.validated()
    try EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    ).preflight(herdr)
    if requireActiveMatch, herdr.managedTheme != desired {
      throw EnvironmentLifecycleError.drift(
        "Herdr ownership does not match the active theme generation"
      )
    }
  }

  func applyLocked(
    composition: EnvironmentComposition,
    inspection: EnvironmentProviderInspection,
    adoptionDigest: String?,
    previousThemeGenerationID: String? = nil,
    themeBridges: EnvironmentThemeBridgeState,
    enabledThemeAdapterIDs: [String]? = nil
  ) throws -> (changed: Bool, generationID: String) {
    if try recoverLocked() {
      throw EnvironmentLifecycleError.blocked(
        "interrupted environment state was recovered; review plan and apply again"
      )
    }
    guard !inspection.isBlocked else {
      throw EnvironmentLifecycleError.blocked(
        inspection.blockedMessage ?? "provider ownership drifted"
      )
    }
    if let expected = inspection.adoptionEvidenceDigest, adoptionDigest != expected {
      throw EnvironmentLifecycleError.adoptionRequired(expected)
    }
    if inspection.adoptionEvidenceDigest == nil, adoptionDigest != nil {
      throw EnvironmentLifecycleError.blocked("no environment adoption is currently required")
    }

    // Revalidate every external seam before staging or publishing any state.
    if composition.profile.focusRing != .disabled || inspection.ownership?.borders != nil {
      guard inspection.bordersServiceInspection != nil,
        composition.profile.focusRing == .disabled || inspection.proposedBordersOwnership != nil
      else {
        throw EnvironmentLifecycleError.blocked("Borders apply requires observed service evidence")
      }
      _ = try inspector.inspectBorders(
        enabled: composition.profile.focusRing == .borders,
        previous: inspection.proposedBordersOwnership ?? inspection.ownership?.borders,
        homeDirectory: homeDirectory,
        service: inspection.bordersServiceInspection,
        lean: inspection.leanServiceInspection?.configuration,
        leanInspection: inspection.leanServiceInspection?.current)
    }
    for (id, expected) in inspection.externalEvidence {
      guard let entry = inspection.desiredEntries.first(where: { $0.id == id }),
        try inspector.capture(entry.url, directoryLink: entry.id.directoryLinkKind) == expected
      else {
        throw EnvironmentLifecycleError.blocked(
          "provider entry changed after planning; run environment plan again"
        )
      }
    }
    for file in EnvironmentKeyOwnedFile.allCases {
      try revalidate(
        inspection.keyOwnedExternalEvidence[file], at: file.configurationPath,
        file.revalidationLabel
      ) { evidence in
        guard file.revalidatesExternalTuple, let linked = file.linkedPreset else { return true }
        return try inspection.proposesOwnership(of: file)
          || inspector.externalTupleIsExact(
            linked, homeDirectory: homeDirectory, stateRoot: stateRoot,
            configurationEvidence: evidence)
      }
    }

    let generationStore = EnvironmentGenerationStore(stateRoot: stateRoot)
    let previousCurrent = try generationStore.currentDestination()
    let staged = try generationStore.stage(composition)
    let previous = inspection.ownership
    let previousByID = Dictionary(
      uniqueKeysWithValues: (previous?.records ?? []).map { ($0.id, $0) })
    var records = [EnvironmentOwnershipRecord]()
    for entry in inspection.desiredEntries {
      if let existing = previousByID[entry.id] {
        records.append(existing)
        continue
      }
      guard let evidence = inspection.externalEvidence[entry.id] else {
        // Exact externally owned seams below symlink-owned parents remain outside ownership.
        continue
      }
      records.append(
        EnvironmentOwnershipRecord(
          id: entry.id,
          publicPath: entry.url.path,
          managedKind: entry.kind.rawValue,
          managedTarget: entry.target,
          original: evidence,
          retainedPath: evidence.kind == .absent
            ? nil
            : providerEntries.retainedURL(for: entry).path
        )
      )
    }
    let desiredBridgePaths = Set(
      EnvironmentThemeBridgeState.paths(
        ids: Set(inspection.desiredEntries.map(\.id)),
        stateRoot: stateRoot
      )
    )
    let previousBridges = Dictionary(
      uniqueKeysWithValues: (previous?.originalThemeBridges ?? []).map { ($0.path, $0) }
    )
    let capturedBridges = Dictionary(
      uniqueKeysWithValues: themeBridges.entries.map { ($0.path, $0) }
    )
    let originalThemeBridges = try desiredBridgePaths.sorted().map { path in
      guard let entry = previousBridges[path] ?? capturedBridges[path] else {
        throw EnvironmentLifecycleError.blocked(
          "the original theme bridge was not captured: \(path)"
        )
      }
      return entry
    }
    let proposed = EnvironmentOwnership(
      generationID: staged.manifest.generationID,
      records: records,
      createdDirectories: Array(
        Set(
          (previous?.createdDirectories ?? []).filter { directory in
            inspection.desiredEntries.contains {
              $0.url.path.hasPrefix(directory + "/")
            }
          }
        ).union(inspection.createdDirectories)
      ),
      originalThemeBridges: originalThemeBridges,
      btop: inspection.proposedBtopOwnership,
      borders: inspection.proposedBordersOwnership,
      codex: inspection.proposedCodexOwnership,
      herdr: inspection.proposedHerdrOwnership,
      pi: inspection.proposedPiOwnership,
      spicetify: inspection.proposedSpicetifyOwnership,
      tuicr: inspection.proposedTuicrOwnership,
      codexEnabled: composition.profile.presets.codex,
      herdrEnabled: composition.profile.presets.herdr,
      piEnabled: composition.profile.presets.pi,
      slackEnabled: composition.profile.presets.slack,
      spicetifyEnabled: composition.profile.presets.spicetify,
      tuicrEnabled: composition.profile.presets.tuicr,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs
        ?? composition.profile.selectedThemeAdapterIDs,
      standardNativeEntries: inspection.standardNativeEntries
    )
    let generationChanged = previous?.generationID != proposed.generationID
    let ownershipChanged =
      previous?.records != proposed.records || previous?.btop != proposed.btop
      || previous?.borders != proposed.borders
      || previous?.codex != proposed.codex
      || previous?.herdr != proposed.herdr
      || previous?.pi != proposed.pi
      || previous?.spicetify != proposed.spicetify
      || previous?.tuicr != proposed.tuicr
      || previous?.codexEnabled != proposed.codexEnabled
      || previous?.herdrEnabled != proposed.herdrEnabled
      || previous?.piEnabled != proposed.piEnabled
      || previous?.slackEnabled != proposed.slackEnabled
      || previous?.spicetifyEnabled != proposed.spicetifyEnabled
      || previous?.tuicrEnabled != proposed.tuicrEnabled
      || previous?.enabledThemeAdapterIDs != proposed.enabledThemeAdapterIDs
      || previous?.standardNativeEntries != proposed.standardNativeEntries
    let changed = generationChanged || ownershipChanged

    let replacementNames = EnvironmentReplacementNames(from: previous, to: proposed)
    let transaction = EnvironmentTransaction(
      operation: .apply,
      previousOwnership: previous,
      proposedOwnership: proposed,
      previousCurrentDestination: previousCurrent,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: themeBridges.entries,
      replacementNames: replacementNames,
      herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget.required(from: previous, to: proposed),
      herdrLegacyMigration:
        previous?.herdr == nil && proposed.herdr?.migratedLegacy == true ? true : nil,
      spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget.required(
        from: previous, to: proposed),
      bordersPreviousRuntime: inspection.bordersServiceInspection,
      bordersRuntimeTarget: EnvironmentBordersRuntimeTarget.required(from: previous, to: proposed)
    )
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    // finishApplyLocked or rollbackApplyLocked settles the journal after runtime work.
    return try store.runJournaled(
      transaction,
      commit: .deferred,
      forward: {
        if changed {
          try generationStore.select(proposed.generationID)
          try transition(
            from: previous,
            to: proposed,
            replacementNames: replacementNames
          )
          try restoreReleasedThemeBridges(from: previous, to: proposed)
          try store.writeOwnership(proposed)
        }
        return (changed, proposed.generationID)
      },
      reverse: { _ in
        let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
        try transition(
          from: proposed,
          to: previous,
          replacementNames: replacementNames,
          preserveLegacyHerdrOnRemoval: preserveLegacyHerdr
        )
        try generationStore.restoreCurrent(previousCurrent)
        try EnvironmentThemeBridgeState(entries: themeBridges.entries).restore()
        try store.writeOwnership(previous)
      },
      rollbackFailure: .requiresRecoveryNamingDirection(failed: "apply failed"),
      rolledBack: { $0 }
    )
  }

  /// Requires a planned preset file's evidence, and its external tuple when one applies, to be
  /// unchanged since planning.
  private func revalidate(
    _ expected: EnvironmentEntryEvidence?,
    at relativePath: String,
    _ label: String,
    tupleIsExact: (EnvironmentEntryEvidence) throws -> Bool
  ) throws {
    guard let expected else { return }
    let url = homeDirectory.appending(path: relativePath)
    let tupleMatches = try tupleIsExact(expected)
    guard try inspector.capture(url, directoryLink: nil) == expected, tupleMatches else {
      throw EnvironmentLifecycleError.blocked(
        "\(label) changed after planning; run environment plan again"
      )
    }
  }

  func finishApplyLocked(composition: EnvironmentComposition) throws {
    if let transaction = try EnvironmentStateStore(stateRoot: stateRoot).readTransaction() {
      if transaction.pendingBordersRuntimeTarget != nil {
        throw EnvironmentLifecycleError.blocked("Borders runtime transition is not verified")
      }
      if pendingHerdrRuntimeTarget(transaction) != nil {
        throw EnvironmentLifecycleError.blocked("Herdr runtime activation is not verified")
      }
      if pendingSpicetifyRuntimeTarget(transaction) != nil {
        throw EnvironmentLifecycleError.blocked("Spicetify runtime refresh is not verified")
      }
    }
    let inspection = inspector.inspect(
      composition: composition,
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    guard !inspection.isBlocked,
      inspection.entries.allSatisfy({ [.managed, .external].contains($0.status) })
    else {
      throw EnvironmentLifecycleError.drift(
        inspection.blockedMessage ?? "provider verification failed before transaction completion"
      )
    }
    if let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership(),
      ownership.herdr?.migratedLegacy == true, !ownership.herdrEnabled
    {
      try discardHerdrLegacyEvidence()
    }
    try faultInjector(.authorityPublished)
    try EnvironmentStateStore(stateRoot: stateRoot).removeTransaction()
  }

  func rollbackApplyLocked() throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else {
      throw EnvironmentLifecycleError.blocked("no environment transaction can be rolled back")
    }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
    let rollback = transaction.rollingBack
    try store.writeTransaction(rollback)
    try transition(
      from: rollback.proposedOwnership,
      to: rollback.previousOwnership,
      replacementNames: rollback.replacementNames,
      preserveLegacyHerdrOnRemoval: preserveLegacyHerdr
    )
    try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
      rollback.previousCurrentDestination
    )
    try restoreRollbackThemeBridges(rollback)
    try store.writeOwnership(rollback.previousOwnership)
    if rollback.herdrRuntimeTarget == nil, rollback.spicetifyRuntimeTarget == nil,
      rollback.bordersRuntimeTarget == nil
    {
      try store.removeTransaction()
    }
  }

  func teardownLocked(
    dryRun: Bool, bordersService: BordersServiceInspection? = nil
  ) throws -> (changed: Bool, message: String) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    if dryRun {
      guard try store.readTransaction() == nil else {
        throw EnvironmentLifecycleError.blocked(
          "an interrupted environment transaction must be recovered before teardown preview"
        )
      }
      guard let ownership = try store.readOwnership() else {
        guard try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() == nil
        else {
          throw EnvironmentLifecycleError.drift(
            "an environment generation is selected without ownership"
          )
        }
        return (false, "No managed environment ownership exists.")
      }
      try validate(ownership)
      try preflight(ownership)
      return (false, "Managed provider entries are ready for exact restoration.")
    }
    let recovered = try recoverLocked()
    guard let ownership = try store.readOwnership() else {
      guard try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() == nil else {
        throw EnvironmentLifecycleError.drift(
          "an environment generation is selected without ownership"
        )
      }
      return (
        recovered,
        recovered
          ? "The interrupted environment teardown was recovered."
          : "No managed environment ownership exists."
      )
    }
    try validate(ownership)
    try preflight(ownership)
    if ownership.borders != nil, bordersService == nil {
      throw EnvironmentLifecycleError.blocked("Borders teardown requires observed service evidence")
    }
    let transaction = EnvironmentTransaction(
      operation: .teardown,
      previousOwnership: ownership,
      proposedOwnership: nil,
      previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination(),
      rollbackThemeBridges: try EnvironmentThemeBridgeState.capture(
        ids: Set(ownership.records.map(\.id)),
        stateRoot: stateRoot
      ).entries,
      replacementNames: EnvironmentReplacementNames(from: ownership, to: nil),
      herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget.required(from: ownership, to: nil),
      spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget.required(from: ownership, to: nil),
      bordersPreviousRuntime: bordersService,
      bordersRuntimeTarget: EnvironmentBordersRuntimeTarget.required(from: ownership, to: nil)
    )
    try store.writeTransaction(transaction)
    try transition(
      from: ownership,
      to: nil,
      replacementNames: transaction.replacementNames
    )
    if transaction.herdrRuntimeTarget == nil, transaction.spicetifyRuntimeTarget == nil,
      transaction.bordersRuntimeTarget == nil
    {
      _ = try prepareRecoveryLocked()
    }
    return (true, "The exact adopted provider entries were restored.")
  }

  func beginHerdrThemeTransitionLocked(_ desired: GeneratedHerdrTheme) throws -> Bool {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard try store.readTransaction() == nil else {
      throw EnvironmentLifecycleError.blocked(
        "an interrupted environment transaction must be recovered first"
      )
    }
    guard let previous = try store.readOwnership(), previous.herdrEnabled,
      let herdr = previous.herdr
    else {
      throw EnvironmentLifecycleError.blocked("aggregate Herdr ownership is not active")
    }
    try EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    ).preflight(herdr)
    let desired = try desired.validated()
    guard herdr.managedTheme != desired else { return false }
    let proposed = previous.replacingHerdr(herdr.replacingManagedTheme(desired))
    let transaction = EnvironmentTransaction(
      operation: .herdrTheme,
      previousOwnership: previous,
      proposedOwnership: proposed,
      previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination(),
      replacementNames: EnvironmentReplacementNames([
        .herdr: EnvironmentReplacementNames.reserve(EnvironmentKeyOwnedFile.herdr.rawValue)
      ]),
      herdrRuntimeTarget: .managed
    )
    // The caller settles the journal once Herdr's runtime reload is verified or rolled back.
    return try store.runJournaled(
      transaction,
      commit: .deferred,
      forward: {
        try transition(
          from: previous,
          to: proposed,
          replacementNames: transaction.replacementNames,
          herdrThemeOnly: true
        )
        try store.writeOwnership(proposed)
        return true
      },
      reverse: { _ in
        try transition(
          from: proposed,
          to: previous,
          replacementNames: transaction.replacementNames,
          herdrThemeOnly: true
        )
        try store.writeOwnership(previous)
      },
      rollbackFailure: .requiresRecovery(failed: "Herdr theme transition failed"),
      rolledBack: { $0 }
    )
  }

  private func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementNames: EnvironmentReplacementNames,
    preserveLegacyHerdrOnRemoval: Bool = false,
    herdrThemeOnly: Bool = false,
    neovimOnly: Bool = false,
    nativeFileOnly: EnvironmentNativeFileMigration.Provider? = nil
  ) throws {
    if let provider = nativeFileOnly {
      guard let old, let new else {
        throw EnvironmentLifecycleError.blocked(
          "native migration requires both ownership snapshots")
      }
      try EnvironmentNativeFileMigration(
        provider: provider, homeDirectory: homeDirectory, stateRoot: stateRoot
      )
      .transition(from: old, to: new)
      return
    }
    if neovimOnly {
      guard let old, let new else {
        throw EnvironmentLifecycleError.blocked(
          "Neovim migration requires both ownership snapshots")
      }
      try EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .transition(from: old, to: new)
      return
    }
    if herdrThemeOnly {
      // A theme transaction carries the full aggregate receipt but authorizes
      // only Herdr's generated surface, including forward/rollback recovery.
      guard let old, let new, old.herdrEnabled, new.herdrEnabled,
        let previous = old.herdr, let proposed = new.herdr,
        old.replacingHerdr(previous.replacingManagedTheme(proposed.managedTheme)) == new,
        let herdrReplacementName = replacementNames[.herdr]
      else {
        throw EnvironmentLifecycleError.blocked(
          "Herdr theme transaction changes unrelated ownership")
      }
      try EnvironmentHerdrFileTransaction(
        homeDirectory: homeDirectory, stateRoot: stateRoot
      ).transition(from: old, to: new, replacementName: herdrReplacementName)
      return
    }
    let oldByID = Dictionary(uniqueKeysWithValues: (old?.records ?? []).map { ($0.id, $0) })
    let newByID = Dictionary(uniqueKeysWithValues: (new?.records ?? []).map { ($0.id, $0) })
    // A previously owned preset file moves before the provider links change; every other
    // key-owned file moves after them.
    let beforeLinks = EnvironmentKeyOwnedFile.allCases.filter {
      $0.transitionsBeforeLinks && $0.isOwned(by: old)
    }
    for file in beforeLinks {
      try transition(
        file, from: old, to: new, replacementNames: replacementNames,
        preserveLegacyHerdrOnRemoval: preserveLegacyHerdrOnRemoval)
    }

    for record in old?.records.reversed() ?? [] where newByID[record.id] == nil {
      do {
        try providerEntries.restore(record)
      } catch {
        throw EnvironmentLifecycleError.blocked(
          "restore \(record.id.rawValue) failed: \(error)"
        )
      }
    }
    for record in new?.records ?? [] {
      if oldByID[record.id] == nil {
        try providerEntries.install(record)
      } else {
        let entry = inspector.managedEntry(from: record)
        if try !inspector.managedEntryIsExact(entry) {
          // A rollback can encounter the restored original at the public path.
          if try providerEntries.evidence(
            at: entry.url,
            matches: record.original,
            directoryLink: record.id.directoryLinkKind
          ) {
            try providerEntries.retainOriginal(record)
            try providerEntries.publishManaged(entry)
          } else {
            throw EnvironmentLifecycleError.drift(entry.url.path)
          }
        }
      }
    }
    for file in EnvironmentKeyOwnedFile.allCases
    where !beforeLinks.contains(file) && (file.isOwned(by: old) || file.isOwned(by: new)) {
      try transition(file, from: old, to: new, replacementNames: replacementNames)
    }
    let obsoleteDirectories = Set(old?.createdDirectories ?? [])
      .subtracting(new?.createdDirectories ?? [])
    try providerEntries.removeCreatedDirectories(Array(obsoleteDirectories))
  }

  /// Moves one key-owned configuration file between the ownership snapshots.
  private func transition(
    _ file: EnvironmentKeyOwnedFile,
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementNames: EnvironmentReplacementNames,
    preserveLegacyHerdrOnRemoval: Bool = false
  ) throws {
    guard let replacementName = replacementNames[file] else {
      throw EnvironmentLifecycleError.blocked(
        "\(file.label) transaction has no replacement identity")
    }
    switch file {
    case .btop:
      try EnvironmentBtopFileTransaction(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .transition(from: old, to: new, replacementName: replacementName)
    case .codex:
      try EnvironmentCodexFileTransaction(homeDirectory: homeDirectory)
        .transition(from: old, to: new, replacementName: replacementName)
    case .herdr:
      try EnvironmentHerdrFileTransaction(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .transition(
          from: old, to: new, replacementName: replacementName,
          preserveLegacyManagedOnRemoval: preserveLegacyHerdrOnRemoval)
    case .pi:
      try EnvironmentPiFileTransaction(homeDirectory: homeDirectory)
        .transition(from: old, to: new, replacementName: replacementName)
    case .spicetify:
      try EnvironmentSpicetifyFileTransaction(homeDirectory: homeDirectory)
        .transition(from: old, to: new, replacementName: replacementName)
    case .tuicr:
      try EnvironmentTuicrFileTransaction(homeDirectory: homeDirectory)
        .transition(from: old, to: new, replacementName: replacementName)
    }
  }

  private func shouldPreserveLegacyHerdr(_ transaction: EnvironmentTransaction) throws -> Bool {
    guard transaction.herdrLegacyMigration == true,
      transaction.operation == .apply,
      transaction.previousOwnership?.herdr == nil,
      transaction.proposedOwnership?.herdrEnabled == true,
      transaction.proposedOwnership?.herdr?.migratedLegacy == true
    else { return false }
    return try HerdrAdapter.environment(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .authenticatedLegacyOwnershipMatchesCurrentGeneration()
  }

  private func discardHerdrLegacyEvidence() throws {
    try HerdrAdapter.environment(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .discardLegacyOwnershipEvidence()
  }

  private func restoreReleasedThemeBridges(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?
  ) throws {
    let retainedPaths = Set(new?.originalThemeBridges.map(\.path) ?? [])
    try EnvironmentThemeBridgeState(
      entries: old?.originalThemeBridges.filter { !retainedPaths.contains($0.path) } ?? []
    ).restore()
  }

  private func restoreRollbackThemeBridges(_ transaction: EnvironmentTransaction) throws {
    if let previousThemeGenerationID = transaction.previousThemeGenerationID {
      let active = try ThemeGenerationReader(root: stateRoot).activeManifest()
      guard active.generationID == previousThemeGenerationID else { return }
    }
    try EnvironmentThemeBridgeState(entries: transaction.rollbackThemeBridges).restore()
  }

  private func validate(_ ownership: EnvironmentOwnership?) throws {
    guard let ownership else { return }
    guard ownership.hasValidShape else {
      throw EnvironmentLifecycleError.blocked("environment ownership has an invalid structure")
    }
    let allowed = Dictionary(
      uniqueKeysWithValues: EnvironmentManagedEntry.all(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).map { ($0.id, $0) }
    )
    for record in ownership.records {
      guard let entry = allowed[record.id],
        EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
          .allows(record, entry: entry)
          || EnvironmentNativeFileMigration(
            provider: .atuin, homeDirectory: homeDirectory, stateRoot: stateRoot
          )
          .allows(record, entry: entry)
          || EnvironmentNativeFileMigration(
            provider: .starship, homeDirectory: homeDirectory, stateRoot: stateRoot
          )
          .allows(record, entry: entry)
      else {
        throw EnvironmentLifecycleError.blocked(
          "ownership for \(record.id.rawValue) contains an unexpected provider path or target"
        )
      }
      if let retained = record.retainedPath {
        let retainedURL = URL(filePath: retained).standardizedFileURL
        let expectedPrefix = ".macarchy-environment-\(record.id.rawValue)-"
        guard retainedURL.deletingLastPathComponent() == entry.url.deletingLastPathComponent(),
          retainedURL.lastPathComponent.hasPrefix(expectedPrefix),
          retainedURL.lastPathComponent.hasSuffix(".retained")
        else {
          throw EnvironmentLifecycleError.blocked(
            "ownership for \(record.id.rawValue) contains an unexpected retained path"
          )
        }
      }
    }
    for file in EnvironmentKeyOwnedFile.allCases {
      if let path = file.ownedPath(in: ownership),
        path != homeDirectory.appending(path: file.configurationPath).path
      {
        throw EnvironmentLifecycleError.blocked(
          "ownership contains an unexpected \(file.label) path")
      }
    }
    let allowedDirectories = Set(
      allowed.values.map { $0.url.deletingLastPathComponent().path }
        + allowed.values.flatMap { entry -> [String] in
          var paths = [String]()
          var parent = entry.url.deletingLastPathComponent()
          while parent.path != homeDirectory.path, parent.path.hasPrefix(homeDirectory.path + "/") {
            paths.append(parent.path)
            parent.deleteLastPathComponent()
          }
          return paths
        }
        + [
          homeDirectory.appending(path: ".config").path,
          homeDirectory.appending(path: ConsumerHomePath.herdrDirectory).path,
        ]
    )
    guard Set(ownership.createdDirectories).isSubset(of: allowedDirectories) else {
      throw EnvironmentLifecycleError.blocked("ownership contains an unexpected created directory")
    }
    guard
      EnvironmentThemeBridgeState.pathsAreValid(
        ownership.originalThemeBridges,
        stateRoot: stateRoot
      )
    else {
      throw EnvironmentLifecycleError.blocked("ownership contains an unexpected theme bridge")
    }
  }

  private func preflight(_ ownership: EnvironmentOwnership) throws {
    if let borders = ownership.borders, borders.retainsBorders {
      _ = try inspector.inspectBorders(
        enabled: true, previous: borders, homeDirectory: homeDirectory, service: nil)
    }
    for record in ownership.records {
      let entry = inspector.managedEntry(from: record)
      guard try inspector.managedEntryIsExact(entry) else {
        throw EnvironmentLifecycleError.drift(entry.url.path)
      }
      if let retained = record.retainedPath {
        guard
          try providerEntries.evidence(
            at: URL(filePath: retained),
            matches: record.original,
            directoryLink: record.id.directoryLinkKind
          )
        else {
          throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
        }
      }
    }
    if let btop = ownership.btop {
      let url = URL(filePath: btop.path)
      let evidence = try inspector.capture(url, directoryLink: nil)
      let state = try EnvironmentBtopFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).generationState(ownership.generationID)
      guard evidence.kind == .regularFile,
        try EnvironmentBtopDocument.matchesManaged(
          String(data: BoundedRegularFile.read(at: url).data, encoding: .utf8) ?? "",
          values: state.values,
          source: url
        )
      else {
        throw EnvironmentLifecycleError.drift(url.path)
      }
    }
    if let codex = ownership.codex {
      try EnvironmentCodexFileTransaction(homeDirectory: homeDirectory).preflight(codex)
    } else {
      try preflightExternalTuple(.codex, in: ownership)
    }
    if let herdr = ownership.herdr {
      let transaction = EnvironmentHerdrFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      )
      if ownership.herdrEnabled {
        try transaction.preflight(herdr)
      } else {
        try transaction.preflightOriginal(herdr)
      }
    }
    if let pi = ownership.pi {
      try EnvironmentPiFileTransaction(homeDirectory: homeDirectory).preflight(pi)
    } else {
      try preflightExternalTuple(.pi, in: ownership)
    }
    if let spicetify = ownership.spicetify {
      try EnvironmentSpicetifyFileTransaction(homeDirectory: homeDirectory).preflight(spicetify)
    } else {
      try preflightExternalTuple(.spicetify, in: ownership)
    }
    if let tuicr = ownership.tuicr {
      try EnvironmentTuicrFileTransaction(homeDirectory: homeDirectory).preflight(tuicr)
    } else {
      try preflightExternalTuple(.tuicr, in: ownership)
    }
  }

  /// An enabled linked preset that owns neither its file nor its theme links must still find its
  /// exact external tuple.
  private func preflightExternalTuple(
    _ linked: EnvironmentLinkedPreset,
    in ownership: EnvironmentOwnership
  ) throws {
    guard linked.preset.isEnabled(in: ownership),
      !ownership.records.contains(where: { linked.themeLinks.contains($0.id) })
    else { return }
    guard
      try inspector.externalTupleIsExact(
        linked, homeDirectory: homeDirectory, stateRoot: stateRoot)
    else {
      throw EnvironmentLifecycleError.drift("externally owned \(linked.file.label) tuple")
    }
  }
}
