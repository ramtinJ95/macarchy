import Darwin
import Foundation
import ThemeCore

struct EnvironmentLeanObservation: Sendable {
  let configuration: LeanFocusServiceConfiguration?
  let current: LeanFocusServiceInspection
}

extension ThemeRuntimeSelection {
  static func managedLeanMode(
    stateRoot: URL, homeDirectory: URL, runtime: EnvironmentLeanRuntime
  ) -> BordersManagedMode {
    let coordinator = EnvironmentTransactionCoordinator(
      homeDirectory: homeDirectory, stateRoot: stateRoot)
    return BordersManagedMode(
      preflight: { _ = try coordinator.managedLeanConfiguration() },
      inspect: {
        let configuration = try coordinator.managedLeanConfiguration()
        return try runtime.acknowledge(homeDirectory, configuration, false)
      },
      reconcile: {
        let lock = EnvironmentLifecycleLock(stateRoot: stateRoot)
        let descriptor = try lock.acquire()
        defer { lock.release(descriptor) }
        guard try EnvironmentStateStore(stateRoot: stateRoot).readTransaction() == nil else {
          throw EnvironmentLifecycleError.blocked(
            "Focus handoff recovery must finish before lean theme reconciliation")
        }
        let configuration = try coordinator.managedLeanConfiguration()
        // The helper observes the canonical pointer itself. This verifies the
        // live runloop acknowledgement; it never writes a competing palette.
        return try runtime.acknowledge(homeDirectory, configuration, true)
      }
    )
  }
}

/// Native calls are observed outside ActivationLock and injected for lifecycle tests.
struct EnvironmentLeanRuntime: Sendable {
  let configuration: @Sendable (URL) -> LeanFocusServiceConfiguration
  let inspect:
    @Sendable (URL, [LeanFocusServiceConfiguration]) throws
      -> (LeanFocusServiceInspection, LeanFocusServiceConfiguration?)
  let start: @Sendable (URL, LeanFocusServiceConfiguration) throws -> Void
  let stop: @Sendable (URL, LeanFocusServiceConfiguration) throws -> Void
  let acknowledge: @Sendable (URL, LeanFocusServiceConfiguration, Bool) throws -> String

  static let live = Self(
    configuration: {
      LeanFocusServiceConfiguration(
        stateRoot: $0,
        executableURL: LeanBordersPreview.helperURL(beside: RuntimeEnvironment.live.executableURL))
    },
    inspect: { home, known in
      let service = LeanFocusService(homeDirectory: home)
      if known.isEmpty { return (try service.inspect(configuration: nil), nil) }
      // Only journal/ownership configurations are candidates, never arbitrary
      // on-disk bytes. An upgrade interruption can leave either exact owned job.
      var failures: [String] = []
      for configuration in known {
        do { return (try service.inspect(configuration: configuration), configuration) } catch {
          failures.append(String(describing: error))
        }
      }
      throw EnvironmentLifecycleError.blocked(failures.joined(separator: "; "))
    },
    start: { home, configuration in
      try LeanFocusService(homeDirectory: home).start(configuration)
    },
    stop: { home, configuration in
      try LeanFocusService(homeDirectory: home).stop(configuration)
    },
    acknowledge: { home, configuration, settle in
      let service = LeanFocusService(homeDirectory: home)
      var last = "no live canonical-palette acknowledgement"
      for attempt in 0..<(settle ? 30 : 1) {
        do {
          let before = try service.inspect(configuration: configuration)
          guard let pid = before.processID else {
            throw EnvironmentLifecycleError.drift("the owned lean service is stopped")
          }
          let palette = try BordersPalette.read(root: URL(filePath: configuration.stateRoot))
          let report = try LeanFocusRuntime.read(configuration: configuration)
          guard report.matches(configuration: configuration, processID: pid, palette: palette),
            try service.inspect(configuration: configuration) == before
          else {
            throw EnvironmentLifecycleError.drift("lean palette/process acknowledgement is stale")
          }
          return
            "Lean AppKit runloop acknowledged canonical generation \(palette.generationID) and accent \(palette.accent); not pixel or exact-focus proof. Physical/display/Spaces/app/soak limits remain."
        } catch { last = String(describing: error) }
        if settle, attempt < 29 { Thread.sleep(forTimeInterval: 0.1) }
      }
      throw EnvironmentLifecycleError.drift(last)
    }
  )
}

func observedLeanService(
  desiredEnabled: Bool, stateRoot: URL, homeDirectory: URL, runtime: EnvironmentLeanRuntime
) throws -> EnvironmentLeanObservation? {
  let previous = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()?.borders?
    .leanService
  guard desiredEnabled || previous != nil else { return nil }
  let (current, _) = try runtime.inspect(homeDirectory, previous.map { [$0] } ?? [])
  let desired = desiredEnabled ? runtime.configuration(stateRoot) : nil
  if previous == nil, let desired {
    // A fresh managed claim may not overwrite an unrelated status file.
    var metadata = stat()
    if lstat(desired.runtimeURL.path, &metadata) == 0 {
      throw EnvironmentLifecycleError.blocked(
        "unowned lean runtime evidence exists; inspect it before selecting lean")
    }
    guard errno == ENOENT else {
      throw EnvironmentLifecycleError.blocked(
        "cannot inspect lean runtime evidence (errno \(errno))")
    }
  }
  return EnvironmentLeanObservation(configuration: desired, current: current)
}

extension EnvironmentTransactionCoordinator {
  func managedLeanConfiguration() throws -> LeanFocusServiceConfiguration {
    let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership()
    guard let ownership, let configuration = ownership.borders?.leanService,
      configuration.isValid, configuration.stateRoot == stateRoot.standardizedFileURL.path,
      try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination()
        == "generations/\(ownership.generationID)"
    else { throw EnvironmentLifecycleError.blocked("Lean has no matching applied ownership") }
    if ownership.borders?.retainsBorders == true {
      try verifyManagedBordersConfiguration()
    }
    return configuration
  }
}

/// One existing environment journal covers both renderers. Stop the owned source
/// before starting the destination; retry only either exact retained configuration.
func verifyPendingLeanHandoff(
  coordinator: EnvironmentTransactionCoordinator, runtime: EnvironmentBordersRuntime,
  transaction: EnvironmentTransaction, target: EnvironmentBordersRuntimeTarget
) throws -> DesktopThemeAdapterStatus? {
  let root = coordinator.stateRoot
  let home = coordinator.homeDirectory
  let lock = ActivationLock(root: root)
  let store = EnvironmentStateStore(stateRoot: root)
  let source =
    transaction.direction == .forward
    ? transaction.previousOwnership?.borders : transaction.proposedOwnership?.borders
  let destination =
    transaction.direction == .forward
    ? transaction.proposedOwnership?.borders : transaction.previousOwnership?.borders
  let sourceLean = source?.leanService
  let destinationLean = destination?.leanService
  let attempted = transaction.bordersRuntimeAttempted == true
  let known =
    attempted
    ? [sourceLean, destinationLean].compactMap { $0 }
    : [transaction.previousOwnership?.borders?.leanService].compactMap { $0 }
  let (leanState, currentLean) = try runtime.lean.inspect(home, known)
  let needsBorders = source?.retainsBorders == true || destination?.retainsBorders == true
  let currentBorders =
    try needsBorders
    ? (attempted ? runtime.recoveryPreflight(home) : runtime.preflight(home))
    : runtime.inspectIncumbent(home)
  if !attempted, currentBorders != transaction.bordersPreviousRuntime {
    throw EnvironmentLifecycleError.drift("Borders changed after reviewed focus inspection")
  }
  if !needsBorders, currentBorders != .stopped {
    throw EnvironmentLifecycleError.blocked(
      "Unmanaged JankyBorders blocks lean; no process was stopped")
  }
  if let destinationLean {
    guard try coordinator.managedLeanConfiguration() == destinationLean else {
      throw EnvironmentLifecycleError.drift("lean launch configuration changed")
    }
  } else if target == .managed {
    try coordinator.verifyManagedBordersConfiguration()
  } else if let source, source.retainsBorders {
    _ = try EnvironmentProviderInspector().inspectBorders(
      enabled: false, previous: source, homeDirectory: home, service: nil)
  }
  try lock.withLock {
    guard var pending = try store.readTransaction(), pending == transaction else {
      throw EnvironmentLifecycleError.blocked(
        "focus handoff transaction changed before native work")
    }
    pending.bordersRuntimeAttempted = true
    try store.writeTransaction(pending)
  }

  if leanState.registered, currentLean != destinationLean, let currentLean {
    try runtime.lean.stop(home, currentLean)
  }
  let message: String
  if let destinationLean {
    if currentBorders.isRegistered {
      guard source?.retainsBorders == true || destination?.retainsBorders == true else {
        throw EnvironmentLifecycleError.blocked("no retained Borders ownership permits stopping it")
      }
      try runtime.stop(home)
    }
    guard try runtime.inspectIncumbent(home) == .stopped else {
      throw EnvironmentLifecycleError.blocked("Borders must be absent before starting lean")
    }
    try runtime.lean.start(home, destinationLean)
    message = try runtime.lean.acknowledge(home, destinationLean, true)
  } else if target == .managed {
    if !currentBorders.isRunning {
      if currentBorders.isRegistered { try runtime.restart(home) } else { try runtime.start(home) }
    }
    message = try runtime.request(root, home)
  } else if let source, source.retainsBorders {
    if transaction.direction == .rollback, !attempted {
      message = "Restored focus configuration; the original Borders runtime was unchanged."
    } else if source.originalServiceWasRunning {
      try verifyRestoredBordersStartup(homeDirectory: home)
      if currentBorders.isRegistered { try runtime.restart(home) } else { try runtime.start(home) }
      message = "Stopped owned lean and restored the retained original Borders service."
    } else {
      if currentBorders.isRegistered { try runtime.stop(home) }
      message = "Stopped owned lean and restored the original unregistered Borders state."
    }
    guard try runtime.inspectIncumbent(home).isRunning == source.originalServiceWasRunning else {
      throw EnvironmentLifecycleError.blocked("original Borders runtime did not restore")
    }
  } else {
    message = "Stopped and unregistered owned lean; no Borders state was adopted or changed."
  }

  let adapterID = destination?.adapterID ?? source?.adapterID ?? BordersAdapter.leanID
  try lock.withLock {
    if let destination {
      let status = ReconciliationStatusStore(root: root)
      let manifest = try status.activeManifest()
      var results: [AdapterResult] = []
      if case .current(let record) = try status.reconciliationState(for: manifest) {
        results = record.results.filter {
          ![BordersAdapter.id, BordersAdapter.leanID].contains($0.adapterID)
        }
      }
      results.append(
        AdapterResult(
          adapterID: destination.adapterID, requirement: .required, status: .applied,
          message: message))
      _ = try status.persist(manifest: manifest, results: results)
    }
    try coordinator.markBordersRuntimeVerifiedLocked(target)
  }
  return DesktopThemeAdapterStatus(
    adapterID: adapterID, requirement: "required", status: "applied", message: message)
}
