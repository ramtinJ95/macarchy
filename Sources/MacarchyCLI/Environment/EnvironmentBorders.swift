import Foundation
import ThemeCore

struct EnvironmentBordersOwnership: Codable, Equatable, Sendable {
  let originalServiceWasRunning: Bool
  /// Native 1.9.0 falls back to ~/.bordersrc. It stays external and is never edited.
  let fallbackConfiguration: EnvironmentEntryEvidence
  let fallbackTargetDigest: String?

  var hasValidShape: Bool {
    let evidence = fallbackConfiguration
    guard evidence.inventory.isEmpty,
      (evidence.kind == .symbolicLink) == (fallbackTargetDigest != nil)
    else { return false }
    switch evidence.kind {
    case .absent:
      return evidence.device == nil && evidence.inode == nil && evidence.mode == nil
        && evidence.size == nil && evidence.linkDestination == nil
        && evidence.contentDigest == nil && evidence.metadataDigest == nil
    case .regularFile, .symbolicLink:
      return evidence.device != nil && evidence.inode != nil && evidence.mode != nil
        && evidence.size != nil && evidence.metadataDigest != nil
        && (evidence.kind == .regularFile
          ? evidence.contentDigest != nil && evidence.linkDestination == nil
          : evidence.linkDestination != nil && evidence.contentDigest == nil)
    }
  }
}

extension EnvironmentProviderInspector {
  func inspectIncludingBordersRuntime(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    runtime: EnvironmentBordersRuntime
  ) -> EnvironmentProviderInspection {
    do {
      let service = try observedBordersService(
        desiredEnabled: composition.profile.focusRing == .borders,
        stateRoot: stateRoot, homeDirectory: homeDirectory, runtime: runtime)
      return inspect(
        composition: composition, homeDirectory: homeDirectory,
        stateRoot: stateRoot, bordersService: service)
    } catch { return .blocked(error) }
  }

  func inspectBorders(
    enabled: Bool,
    previous: EnvironmentBordersOwnership?,
    homeDirectory: URL,
    service: BordersServiceInspection?
  ) throws -> (ownership: EnvironmentBordersOwnership?, entries: [EnvironmentEntryInspection]) {
    guard enabled || previous != nil else { return (nil, []) }
    let fallback = homeDirectory.appending(path: ".bordersrc")
    let evidence = try capture(fallback, directoryLink: nil)
    let targetDigest =
      try evidence.kind == .symbolicLink
      ? sha256Digest(BoundedRegularFile.read(at: fallback.resolvingSymlinksInPath()).data) : nil
    if previous == nil, service?.isRunning == true {
      try verifyRestoredBordersStartup(homeDirectory: homeDirectory)
    }
    if let previous {
      guard previous.fallbackConfiguration == evidence,
        previous.fallbackTargetDigest == targetDigest
      else {
        throw EnvironmentLifecycleError.drift(
          "the external ~/.bordersrc fallback changed while Borders was managed")
      }
    }
    let baseline: EnvironmentBordersOwnership?
    if let previous {
      baseline = previous
    } else if let service {
      baseline = EnvironmentBordersOwnership(
        originalServiceWasRunning: service.isRunning,
        fallbackConfiguration: evidence,
        fallbackTargetDigest: targetDigest)
    } else {
      return (
        nil,
        [
          EnvironmentEntryInspection(
            id: "borders_service",
            path: homeDirectory.appending(
              path: "Library/LaunchAgents/\(BordersService.label).plist"
            ).path,
            status: .unsupported, ownership: "unknown",
            message: "Borders service evidence was not inspected; no apply is authorized.",
            evidence: nil)
        ]
      )
    }
    let status: EnvironmentInspectionStatus
    let message: String
    if !enabled {
      status = .restorationRequired
      message =
        baseline?.originalServiceWasRunning == true
        ? "Restore the retained native configuration and restart the original Borders service."
        : "Stop and unregister the managed Borders service; preserve the external fallback configuration."
    } else if previous != nil {
      status = service?.isRunning == false ? .drifted : .managed
      message =
        service?.isRunning == false
        ? "The applied Borders service is stopped."
        : "Borders configuration is owned; live palette requests have no native settings or pixel readback."
    } else if service?.isRunning == true || evidence.kind != .absent {
      status = .adoptionRequired
      message =
        service?.isRunning == true
        ? "Adopt the supported Homebrew service; restart Borders to replace arbitrary native options. Teardown restarts the retained configuration."
        : "Start Borders with the managed configuration, shadowing but never editing ~/.bordersrc; teardown restores the stopped service state."
    } else {
      status = .installRequired
      message =
        "Start and register the Homebrew Borders service with the canonical theme. No Accessibility permission is requested."
    }
    return (
      enabled ? baseline : nil,
      [
        EnvironmentEntryInspection(
          id: "borders_service",
          path: homeDirectory.appending(path: "Library/LaunchAgents/\(BordersService.label).plist")
            .path,
          status: status, ownership: previous == nil ? "external" : "macarchy",
          message: message, evidence: evidence)
      ]
    )
  }
}

private func verifyRestoredBordersStartup(homeDirectory: URL) throws {
  let primary = homeDirectory.appending(path: ".config/borders/bordersrc")
  let fallback = homeDirectory.appending(path: ".bordersrc")
  let startup = FileManager.default.fileExists(atPath: primary.path) ? primary : fallback
  if FileManager.default.fileExists(atPath: startup.path),
    try BoundedRegularFile.read(at: startup.resolvingSymlinksInPath()).permissions & 0o100 == 0
  {
    throw EnvironmentLifecycleError.blocked(
      "the original Borders startup file is not owner-executable; native restoration would chmod it, violating exact retained metadata"
    )
  }
}

/// Injected native boundary. Call it outside the canonical activation lock.
struct EnvironmentBordersRuntime: Sendable {
  let inspect: @Sendable (URL) throws -> BordersServiceInspection
  let preflight: @Sendable (URL) throws -> BordersServiceInspection
  let recoveryPreflight: @Sendable (URL) throws -> BordersServiceInspection
  let start: @Sendable (URL) throws -> Void
  let restart: @Sendable (URL) throws -> Void
  let stop: @Sendable (URL) throws -> Void
  let request: @Sendable (URL, URL) throws -> String

  static let live = Self(
    inspect: { try BordersService(homeDirectory: $0).inspectForPlan() },
    preflight: { try BordersService(homeDirectory: $0).preflight() },
    recoveryPreflight: {
      try BordersService(homeDirectory: $0).preflight(allowInterruptedRegistration: true)
    },
    start: { try BordersService(homeDirectory: $0).start() },
    restart: { try BordersService(homeDirectory: $0).restart() },
    stop: { try BordersService(homeDirectory: $0).stop() },
    request: { stateRoot, home in
      try BordersService(homeDirectory: home).request(BordersPalette.read(root: stateRoot))
    }
  )
}

extension EnvironmentTransaction {
  var pendingBordersRuntimeTarget: EnvironmentBordersRuntimeTarget? {
    bordersRuntimeVerified == true ? nil : bordersRuntimeTarget
  }

  var bordersRuntimeIsValid: Bool {
    let expected: EnvironmentBordersRuntimeTarget? =
      [.herdrTheme, .neovimMigration].contains(operation)
      ? nil
      : direction == .forward
        ? .required(from: previousOwnership, to: proposedOwnership)
        : .required(from: proposedOwnership, to: previousOwnership)
    guard bordersRuntimeTarget == expected,
      bordersRuntimeAttempted != false, bordersRuntimeVerified != false,
      bordersRuntimeVerified != true || bordersRuntimeAttempted == true
    else { return false }
    if expected == nil {
      return bordersRuntimeAttempted == nil && bordersRuntimeVerified == nil
        && bordersPreviousRuntime == nil
    }
    guard let baseline = bordersPreviousRuntime else { return false }
    // First-adoption snapshots are always fully running or unregistered.
    return baseline.hasValidShape && (baseline.isRunning || !baseline.isRegistered)
  }
}

extension EnvironmentTransactionCoordinator {
  func pendingBordersRuntimeTargetLocked() throws -> EnvironmentBordersRuntimeTarget? {
    try EnvironmentStateStore(stateRoot: stateRoot).readTransaction()?.pendingBordersRuntimeTarget
  }

  func markBordersRuntimeVerifiedLocked(_ target: EnvironmentBordersRuntimeTarget) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard var transaction = try store.readTransaction(),
      transaction.pendingBordersRuntimeTarget == target,
      transaction.bordersRuntimeAttempted == true
    else {
      throw EnvironmentLifecycleError.blocked("no matching Borders runtime transition is pending")
    }
    transaction.bordersRuntimeVerified = true
    try store.writeTransaction(transaction)
  }

  func verifyManagedBordersConfiguration() throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let ownership = try store.readOwnership(), let borders = ownership.borders,
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(ownership.generationID)"
    else { throw EnvironmentLifecycleError.blocked("Borders has no applied environment ownership") }
    let inspector = EnvironmentProviderInspector()
    let entries = ownership.records.filter {
      [.bordersDirectory, .bordersConfiguration].contains($0.id)
    }
    guard entries.count == 1, let entry = entries.first,
      let allowed = inspector.allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .first(where: { $0.id == entry.id }),
      entry.publicPath == allowed.url.path, entry.managedTarget == allowed.target,
      entry.managedKind == allowed.kind.rawValue,
      try inspector.managedEntryIsExact(allowed)
    else { throw EnvironmentLifecycleError.drift("the managed Borders entry changed") }
    _ = try EnvironmentGenerationStore(stateRoot: stateRoot).validatedArtifact(
      generationID: ownership.generationID, path: BordersConfiguration.artifactPath)
    _ = try inspector.inspectBorders(
      enabled: true, previous: borders, homeDirectory: homeDirectory, service: nil)
  }
}

/// The environment lifecycle lock must cover this entire function. Native service
/// work stays outside ActivationLock; the existing transaction carries its intent.
func verifyPendingBordersRuntime(
  coordinator: EnvironmentTransactionCoordinator,
  runtime: EnvironmentBordersRuntime
) throws -> DesktopThemeAdapterStatus? {
  let root = coordinator.stateRoot
  let home = coordinator.homeDirectory
  let lock = ActivationLock(root: root)
  let store = EnvironmentStateStore(stateRoot: root)
  guard let transaction = try lock.withLock({ try store.readTransaction() }),
    let target = transaction.pendingBordersRuntimeTarget
  else { return nil }

  let current =
    try transaction.bordersRuntimeAttempted == true
    ? runtime.recoveryPreflight(home) : runtime.preflight(home)
  if transaction.bordersRuntimeAttempted != true {
    guard current == transaction.bordersPreviousRuntime else {
      throw EnvironmentLifecycleError.drift(
        "Borders service identity changed after the reviewed pre-mutation inspection")
    }
  }
  let originalServiceUnchanged =
    transaction.direction == .rollback && transaction.bordersRuntimeAttempted != true
  let destination =
    transaction.direction == .forward
    ? transaction.proposedOwnership : transaction.previousOwnership
  let source =
    transaction.direction == .forward
    ? transaction.previousOwnership : transaction.proposedOwnership
  if target == .managed {
    try coordinator.verifyManagedBordersConfiguration()
  } else if let baseline = source?.borders {
    _ = try EnvironmentProviderInspector().inspectBorders(
      enabled: false, previous: baseline, homeDirectory: home, service: nil)
    if baseline.originalServiceWasRunning && !originalServiceUnchanged {
      try verifyRestoredBordersStartup(homeDirectory: home)
    }
  } else {
    throw EnvironmentLifecycleError.blocked("Borders restoration has no original service state")
  }
  let statusStore = ReconciliationStatusStore(root: root)
  let manifest = try target == .managed ? statusStore.activeManifest() : nil

  try lock.withLock {
    guard var pending = try store.readTransaction(), pending == transaction else {
      throw EnvironmentLifecycleError.blocked(
        "Borders runtime transaction changed before native work")
    }
    pending.bordersRuntimeAttempted = true
    try store.writeTransaction(pending)
  }
  let message: String
  if target == .managed {
    guard destination?.borders != nil else {
      throw EnvironmentLifecycleError.blocked("Borders runtime target has no managed ownership")
    }
    if !current.isRunning {
      if current.isRegistered { try runtime.restart(home) } else { try runtime.start(home) }
    } else if source?.borders == nil {
      try runtime.restart(home)
    }
    message = try runtime.request(root, home)
  } else {
    guard let baseline = source?.borders else {
      throw EnvironmentLifecycleError.blocked("Borders restoration lost its original state")
    }
    let wasRunning = baseline.originalServiceWasRunning
    if originalServiceUnchanged {
      // No native request was attempted and the exact original PID/job survived.
      message = "Borders configuration restored; the original service state was unchanged."
    } else if wasRunning {
      if current.isRegistered { try runtime.restart(home) } else { try runtime.start(home) }
      message =
        "Restarted Borders with the retained native configuration; arbitrary settings have no readback."
    } else {
      if current.isRegistered { try runtime.stop(home) }
      message = "Restored the original stopped, unregistered Borders service state."
    }
    guard try runtime.inspect(home).isRunning == wasRunning else {
      throw EnvironmentLifecycleError.blocked("Borders original service state did not restore")
    }
  }
  try lock.withLock {
    if let manifest {
      var results: [AdapterResult] = []
      if case .current(let record) = try statusStore.reconciliationState(for: manifest) {
        results = record.results.filter { $0.adapterID != BordersAdapter.id }
      }
      results.append(
        AdapterResult(
          adapterID: BordersAdapter.id, requirement: .required, status: .applied, message: message))
      _ = try statusStore.persist(manifest: manifest, results: results)
    }
    try coordinator.markBordersRuntimeVerifiedLocked(target)
  }
  return DesktopThemeAdapterStatus(
    adapterID: BordersAdapter.id, requirement: "required", status: "applied", message: message)
}

func observedBordersService(
  desiredEnabled: Bool,
  stateRoot: URL,
  homeDirectory: URL,
  runtime: EnvironmentBordersRuntime,
  preflight: Bool = false
) throws -> BordersServiceInspection? {
  let store = EnvironmentStateStore(stateRoot: stateRoot)
  let ownership = try store.readOwnership()
  let transaction = try store.readTransaction()
  guard
    desiredEnabled || ownership?.borders != nil
      || transaction?.previousOwnership?.borders != nil
      || transaction?.proposedOwnership?.borders != nil
  else { return nil }
  return try preflight ? runtime.preflight(homeDirectory) : runtime.inspect(homeDirectory)
}
