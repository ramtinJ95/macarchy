import Foundation

package struct ThemeActivationResult: Sendable {
  package let manifest: GenerationManifest
  package let reconciliation: ReconciliationRecord
}

package struct ThemeCommittedWithReconciliationError: Error, CustomStringConvertible, Sendable {
  package let manifest: GenerationManifest
  package let cause: String

  package var description: String {
    "Theme '\(manifest.themeID)' committed as generation '\(manifest.generationID)', but reconciliation failed: \(cause)"
  }
}

package enum AdapterSelectionError: Error, CustomStringConvertible, Equatable, Sendable {
  case duplicate(String)
  case unknown(String)

  package var description: String {
    switch self {
    case .duplicate(let adapterID):
      "Adapter '\(adapterID)' was selected more than once"
    case .unknown(let adapterID):
      "Unknown adapter '\(adapterID)'; known adapters: "
        + ThemeActivationCoordinator.adapterRequirements.keys.sorted().joined(separator: ", ")
    }
  }
}

package struct ThemeActivationCoordinator: Sendable {
  package static let adapterRequirements = [KittyAdapter.id: AdapterRequirement.required]

  private let activator: ThemeActivator
  private let kitty: KittyAdapter
  private let reconciler: ThemeReconciler
  private let statusStore: ReconciliationStatusStore

  package init(root: URL, kittyConfigurationURL: URL) {
    let root = root.standardizedFileURL
    let statusStore = ReconciliationStatusStore(root: root)
    activator = ThemeActivator(root: root)
    kitty = KittyAdapter(
      configurationURL: kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: .live
    )
    reconciler = ThemeReconciler(statusStore: statusStore)
    self.statusStore = statusStore
  }

  init(
    root: URL,
    kittyConfigurationURL: URL,
    processRunner: ProcessRunner,
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void = { _ in },
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in },
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    let root = root.standardizedFileURL
    let statusStore = ReconciliationStatusStore(root: root)
    activator = ThemeActivator(
      root: root,
      faultInjector: faultInjector,
      onThemeChanged: onThemeChanged,
      postDarwinNotification: postDarwinNotification
    )
    kitty = KittyAdapter(
      configurationURL: kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: processRunner
    )
    reconciler = ThemeReconciler(statusStore: statusStore)
    self.statusStore = statusStore
  }

  package func preflight(package: ThemePackage) throws {
    try kitty.preflight()
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "dry-run-\(package.id)"
    )
  }

  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String? = nil
  ) async throws -> ThemeActivationResult {
    try Task.checkCancellation()
    try kitty.preflight()
    try Task.checkCancellation()
    let manifest = try activator.activate(
      package: package,
      expectedActiveGenerationID: expectedActiveGenerationID
    )

    do {
      let reconciliation = try await reconciler.reconcile(
        manifest: manifest,
        adapters: [kitty.reconciliation()]
      )
      return ThemeActivationResult(manifest: manifest, reconciliation: reconciliation)
    } catch {
      throw ThemeCommittedWithReconciliationError(
        manifest: manifest,
        cause: String(describing: error)
      )
    }
  }

  package func previewReconciliation(
    _ adapterIDs: [String]
  ) throws -> (manifest: GenerationManifest, inspections: [AdapterInspection]) {
    let selected = try selectedAdapters(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let plan = try reconciliationPlan(
      selected: selected,
      requestedAll: adapterIDs.isEmpty,
      manifest: manifest
    )
    return (
      manifest,
      plan.adapters.map { $0.inspection() }
    )
  }

  package func inspectAdapters(_ adapterIDs: [String]) throws -> [AdapterInspection] {
    try selectedAdapters(adapterIDs).map { $0.inspection() }
  }

  package func reconcile(
    adapterIDs: [String]
  ) async throws -> (manifest: GenerationManifest, record: ReconciliationRecord) {
    let selected = try selectedAdapters(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let plan = try reconciliationPlan(
      selected: selected,
      requestedAll: adapterIDs.isEmpty,
      manifest: manifest
    )
    let record = try await reconciler.reconcile(
      manifest: manifest,
      adapters: plan.adapters.map { $0.reconciliation() },
      preserving: plan.preservedResults
    )
    return (manifest, record)
  }

  private func selectedAdapters(_ adapterIDs: [String]) throws -> [KittyAdapter] {
    var seen = Set<String>()
    for adapterID in adapterIDs {
      guard seen.insert(adapterID).inserted else {
        throw AdapterSelectionError.duplicate(adapterID)
      }
      guard Self.adapterRequirements[adapterID] != nil else {
        throw AdapterSelectionError.unknown(adapterID)
      }
    }
    return [kitty]
  }

  private func reconciliationPlan(
    selected: [KittyAdapter],
    requestedAll: Bool,
    manifest: GenerationManifest
  ) throws -> (adapters: [KittyAdapter], preservedResults: [AdapterResult]) {
    guard !requestedAll else { return (selected, []) }
    switch try statusStore.reconciliationState(for: manifest) {
    case .current(let record):
      return (selected, record.results)
    case .missing, .stale:
      return ([kitty], [])
    }
  }

  private static func kittyIncludeDirective(root: URL) -> String {
    "include \(root.appending(path: "current/\(KittyAdapter.outputPath)").path)"
  }
}
