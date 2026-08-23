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
  package static let adapterRequirements = [
    KittyAdapter.id: AdapterRequirement.required,
    MacOSAppearanceAdapter.id: AdapterRequirement.required,
  ]

  private let root: URL
  private let activator: ThemeActivator
  private let appearance: MacOSAppearanceAdapter
  private let kitty: KittyAdapter
  private let reconciler: ThemeReconciler
  private let statusStore: ReconciliationStatusStore

  package init(root: URL, kittyConfigurationURL: URL) {
    let root = root.standardizedFileURL
    let statusStore = ReconciliationStatusStore(root: root)
    self.root = root
    activator = ThemeActivator(root: root)
    appearance = .live(root: root)
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
    currentAppearance: @escaping @Sendable () throws -> ThemeAppearance = { .dark },
    appearanceControlIsAvailable: @escaping @Sendable () -> Bool = { true },
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void = { _ in },
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in },
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    let root = root.standardizedFileURL
    let statusStore = ReconciliationStatusStore(root: root)
    self.root = root
    activator = ThemeActivator(
      root: root,
      faultInjector: faultInjector,
      onThemeChanged: onThemeChanged,
      postDarwinNotification: postDarwinNotification
    )
    appearance = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: appearanceControlIsAvailable,
      currentAppearance: currentAppearance,
      processRunner: processRunner
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
    _ = try appearance.preflight()
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
    _ = try appearance.preflight()
    try kitty.preflight()
    try Task.checkCancellation()
    let manifest = try activator.activate(
      package: package,
      expectedActiveGenerationID: expectedActiveGenerationID
    )

    do {
      let reconciliation = try await reconciler.reconcile(
        manifest: manifest,
        adapters: configuredAdapters(desiredAppearance: package.appearance).map {
          $0.reconciliation()
        }
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
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(
      desiredAppearance: try activeAppearance(manifest: manifest)
    )
    let selected = selectedAdapters(adapterIDs, from: adapters)
    let plan = try reconciliationPlan(
      selected: selected,
      all: adapters,
      requestedAll: adapterIDs.isEmpty,
      manifest: manifest
    )
    return (
      manifest,
      plan.adapters.map { $0.inspection() }
    )
  }

  package func inspectAdapters(_ adapterIDs: [String]) throws -> [AdapterInspection] {
    try validateSelection(adapterIDs)
    let appearanceInspection: AdapterInspection
    do {
      let manifest = try statusStore.activeManifest()
      appearanceInspection = appearance.inspection(
        desiredAppearance: try activeAppearance(manifest: manifest)
      )
    } catch ReconciliationStatusError.noActiveGeneration {
      appearanceInspection = appearance.inspection(desiredAppearance: nil)
    } catch {
      appearanceInspection = AdapterInspection(
        adapterID: MacOSAppearanceAdapter.id,
        requirement: .required,
        status: .failed,
        message: "Cannot inspect active theme appearance: \(error)"
      )
    }
    let selectedIDs = Set(adapterIDs)
    return [
      appearanceInspection,
      kitty.inspection(),
    ].filter {
      adapterIDs.isEmpty || selectedIDs.contains($0.adapterID)
    }
  }

  package func reconcile(
    adapterIDs: [String]
  ) async throws -> (manifest: GenerationManifest, record: ReconciliationRecord) {
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(desiredAppearance: nil)
    let selected = selectedAdapters(adapterIDs, from: adapters)
    let plan = try reconciliationPlan(
      selected: selected,
      all: adapters,
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

  private func selectedAdapters(
    _ adapterIDs: [String],
    from adapters: [ConfiguredAdapter]
  ) -> [ConfiguredAdapter] {
    guard !adapterIDs.isEmpty else { return adapters }
    let selectedIDs = Set(adapterIDs)
    return adapters.filter { selectedIDs.contains($0.id) }
  }

  private func validateSelection(_ adapterIDs: [String]) throws {
    var seen = Set<String>()
    for adapterID in adapterIDs {
      guard seen.insert(adapterID).inserted else {
        throw AdapterSelectionError.duplicate(adapterID)
      }
      guard Self.adapterRequirements[adapterID] != nil else {
        throw AdapterSelectionError.unknown(adapterID)
      }
    }
  }

  private func reconciliationPlan(
    selected: [ConfiguredAdapter],
    all adapters: [ConfiguredAdapter],
    requestedAll: Bool,
    manifest: GenerationManifest
  ) throws -> (adapters: [ConfiguredAdapter], preservedResults: [AdapterResult]) {
    guard !requestedAll else { return (selected, []) }
    switch try statusStore.reconciliationState(for: manifest) {
    case .current(let record):
      return (selected, record.results)
    case .missing, .stale:
      return (adapters, [])
    }
  }

  private func configuredAdapters(
    desiredAppearance: ThemeAppearance?
  ) -> [ConfiguredAdapter] {
    [
      ConfiguredAdapter(
        id: MacOSAppearanceAdapter.id,
        inspection: { appearance.inspection(desiredAppearance: desiredAppearance) },
        reconciliation: {
          appearance.reconciliation {
            let manifest = try statusStore.activeManifest()
            return try activeAppearance(manifest: manifest)
          }
        }
      ),
      ConfiguredAdapter(
        id: KittyAdapter.id,
        inspection: kitty.inspection,
        reconciliation: kitty.reconciliation
      ),
    ]
  }

  private func activeAppearance(manifest: GenerationManifest) throws -> ThemeAppearance {
    let themeURL = root.appending(
      path: "generations/\(manifest.generationID)/\(ThemeRenderer.themeOutputPath)"
    )
    let normalized = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: BoundedRegularFile.read(at: themeURL).data
    )
    guard
      normalized.generationID == manifest.generationID,
      normalized.themeID == manifest.themeID,
      normalized.schemaVersion == manifest.themeSchemaVersion
    else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "theme.json does not match the active manifest"
      )
    }
    return normalized.appearance
  }

  private static func kittyIncludeDirective(root: URL) -> String {
    "include \(root.appending(path: "current/\(KittyAdapter.outputPath)").path)"
  }
}

private struct ConfiguredAdapter: Sendable {
  let id: String
  let inspection: @Sendable () -> AdapterInspection
  let reconciliation: @Sendable () -> AdapterReconciliation
}
