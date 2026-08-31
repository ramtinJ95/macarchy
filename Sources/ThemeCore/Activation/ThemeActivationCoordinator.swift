import Foundation

package struct ThemeActivationResult: Sendable {
  package let manifest: GenerationManifest
  package let reconciliation: ReconciliationRecord
  package let notice: String?

  package init(
    manifest: GenerationManifest,
    reconciliation: ReconciliationRecord,
    notice: String? = nil
  ) {
    self.manifest = manifest
    self.reconciliation = reconciliation
    self.notice = notice
  }
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
  private static let activationExecutor = BlockingTaskExecutor(
    label: "io.github.ramtinj95.macarchy.activation"
  )

  package static let adapterRequirements = Dictionary(
    uniqueKeysWithValues: ConsumerCatalog.shared.runtimeEntries.map { entry in
      (entry.id.rawValue, entry.mode.requirement!)
    }
  )

  private let root: URL
  private let activator: ThemeActivator
  private let appearance: MacOSAppearanceAdapter
  private let atuin: AtuinAdapter
  private let bat: BatAdapter
  private let btop: BtopAdapter
  private let backgroundPreferences: BackgroundPreferenceStore
  private let codex: CodexAdapter
  private let configurationStore: MacarchyConfigurationStore
  private let eza: EzaAdapter
  private let herdr: HerdrAdapter
  private let kitty: KittyAdapter
  private let neovim: NeovimAdapter
  private let pi: PiAdapter
  private let processRunner: ProcessRunner
  private let reconciler: ThemeReconciler
  private let sketchyBar: SketchyBarAdapter
  private let spicetify: SpicetifyAdapter
  private let starship: StarshipAdapter
  private let statusStore: ReconciliationStatusStore
  private let wallpaper: WallpaperAdapter
  private let wallpaperSignal: YabaiWallpaperSignal
  private let yazi: YaziAdapter
  private let tuicr: TuicrAdapter

  package init(
    root: URL,
    consumerPaths: ThemeConsumerPaths
  ) {
    let root = root.standardizedFileURL
    let appearance = MacOSAppearanceAdapter.live(root: root)
    let controlIsAvailable: @Sendable (URL) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    self.init(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: .live,
      wallpaperControl: .live,
      wallpaperSignal: .personal(),
      currentAppearance: appearance.currentAppearance,
      appearanceControlIsAvailable: appearance.controlIsAvailable,
      sketchyBarControlIsAvailable: {
        controlIsAvailable(SketchyBarAdapter.liveExecutableURL)
      },
      controlIsAvailable: controlIsAvailable
    )
  }

  init(
    root: URL,
    consumerPaths: ThemeConsumerPaths,
    processRunner: ProcessRunner,
    wallpaperControl: WallpaperControl,
    wallpaperSignal: YabaiWallpaperSignal,
    currentAppearance: @escaping @Sendable () throws -> ThemeAppearance = { .dark },
    appearanceControlIsAvailable: @escaping @Sendable () -> Bool = { true },
    sketchyBarControlIsAvailable: @escaping @Sendable () -> Bool = { true },
    controlIsAvailable: @escaping @Sendable (URL) -> Bool = { _ in true },
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
    backgroundPreferences = BackgroundPreferenceStore(root: root)
    appearance = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: appearanceControlIsAvailable,
      currentAppearance: currentAppearance,
      processRunner: processRunner
    )
    atuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.atuinConfigurationDirectoryURL,
      executableURL: AtuinAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(AtuinAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    bat = BatAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.batConfigurationDirectoryURL,
      cacheDirectoryURL: consumerPaths.batCacheDirectoryURL,
      executableURL: BatAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(BatAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    btop = BtopAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.btopConfigurationDirectoryURL,
      executableURL: BtopAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(BtopAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    codex = CodexAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.codexConfigurationDirectoryURL,
      executableURL: CodexAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(CodexAdapter.liveExecutableURL) }
    )
    configurationStore = MacarchyConfigurationStore(root: root)
    eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: consumerPaths.shellConfigurationURL,
      executableURL: EzaAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(EzaAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    herdr = HerdrAdapter(
      root: root,
      configurationURL: consumerPaths.herdrConfigurationURL,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(HerdrAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    kitty = KittyAdapter(
      root: root,
      configurationURL: consumerPaths.kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: processRunner
    )
    neovim = NeovimAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.neovimConfigurationDirectoryURL,
      executableURL: NeovimAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(NeovimAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    pi = PiAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.piConfigurationDirectoryURL,
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(PiAdapter.liveExecutableURL) }
    )
    self.processRunner = processRunner
    reconciler = ThemeReconciler(statusStore: statusStore)
    sketchyBar = SketchyBarAdapter(
      root: root,
      configurationURL: consumerPaths.sketchyBarConfigurationURL,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: sketchyBarControlIsAvailable,
      processRunner: processRunner
    )
    spicetify = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.spicetifyConfigurationDirectoryURL,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(SpicetifyAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    starship = StarshipAdapter(
      root: root,
      configurationURL: consumerPaths.starshipConfigurationURL,
      behaviorURL: consumerPaths.starshipBehaviorURL,
      executableURL: StarshipAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(StarshipAdapter.liveExecutableURL) },
      processRunner: processRunner
    )
    self.statusStore = statusStore
    tuicr = TuicrAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.tuicrConfigurationDirectoryURL,
      executableURL: TuicrAdapter.liveExecutableURL,
      controlIsAvailable: { controlIsAvailable(TuicrAdapter.liveExecutableURL) }
    )
    wallpaper = WallpaperAdapter(root: root, control: wallpaperControl)
    self.wallpaperSignal = wallpaperSignal
    yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.yaziConfigurationDirectoryURL,
      executableURL: YaziAdapter.liveExecutableURL,
      controlURL: YaziAdapter.liveControlURL,
      controlsAreAvailable: {
        controlIsAvailable(YaziAdapter.liveExecutableURL)
          && controlIsAvailable(YaziAdapter.liveControlURL)
      },
      processRunner: processRunner
    )
  }

  package func preflight(
    package: ThemePackage,
    requestedBackgroundID: String? = nil
  ) throws {
    let background = try prepare(
      package: package,
      requestedBackgroundID: requestedBackgroundID,
      recoverActivePreference: false
    )
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "dry-run-\(package.id)",
      wallpaperData: background.data
    )
  }

  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String? = nil,
    requestedBackgroundID: String? = nil
  ) async throws -> ThemeActivationResult {
    try await withTaskExecutorPreference(Self.activationExecutor) {
      try Task.checkCancellation()
      var backgroundNotice: String?
      var previousEvidence: PreviousReconciliationEvidence?
      let manifest = try activator.activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID,
        preparedBackground: {
          if requestedBackgroundID != nil {
            previousEvidence = try previousReconciliationEvidence()
          }
          let background = try prepare(
            package: package,
            requestedBackgroundID: requestedBackgroundID,
            recoverActivePreference: true
          )
          backgroundNotice = background.notice
          try Task.checkCancellation()
          return background
        },
        onCommittedLocked: { manifest in
          try persistPreference(manifest: manifest)
        }
      )

      do {
        let adapters = configuredAdapters(
          context: AdapterResolutionContext(
            desiredAppearance: package.appearance,
            desiredWallpaperURL: activeWallpaperURL(manifest: manifest),
            unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
          )
        )
        let plan = backgroundOnlyReconciliationPlan(
          requestedBackgroundID: requestedBackgroundID,
          previousEvidence: previousEvidence,
          manifest: manifest,
          adapters: adapters
        )
        let reconciliation = try await reconciler.reconcile(
          manifest: manifest,
          adapters: plan.adapters.map { $0.reconciliation() },
          preserving: plan.preservedResults
        )
        return ThemeActivationResult(
          manifest: manifest,
          reconciliation: reconciliation,
          notice: backgroundNotice
        )
      } catch {
        throw ThemeCommittedWithReconciliationError(
          manifest: manifest,
          cause: String(describing: error)
        )
      }
    }
  }

  package func previewReconciliation(
    _ adapterIDs: [String]
  ) throws -> (manifest: GenerationManifest, inspections: [AdapterInspection]) {
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(
      context: AdapterResolutionContext(
        desiredAppearance: try activeAppearance(manifest: manifest),
        desiredWallpaperURL: activeWallpaperURL(manifest: manifest),
        unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      )
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

  package func inspectAdapters(
    _ adapterIDs: [String],
    includeRuntimeChecks: Bool = false
  ) throws -> [AdapterInspection] {
    try validateSelection(adapterIDs)
    var context = AdapterResolutionContext(includeRuntimeChecks: includeRuntimeChecks)
    do {
      let manifest = try statusStore.activeManifest()
      context.unsupportedAdapterIDs = try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      do {
        context.desiredAppearance = try activeAppearance(manifest: manifest)
      } catch {
        context.appearanceInspectionOverride = AdapterInspection(
          adapterID: MacOSAppearanceAdapter.id,
          requirement: .required,
          status: .failed,
          message: "Cannot inspect active theme appearance: \(error)"
        )
      }
      let wallpaperURL = activeWallpaperURL(manifest: manifest)
      context.desiredWallpaperURL = wallpaperURL
      context.wallpaperIntentionallyUnmanaged = wallpaperURL == nil
    } catch ReconciliationStatusError.noActiveGeneration {
      context.wallpaperIntentionallyUnmanaged = false
    } catch {
      context.appearanceInspectionOverride = AdapterInspection(
        adapterID: MacOSAppearanceAdapter.id,
        requirement: .required,
        status: .failed,
        message: "Cannot inspect active theme appearance: \(error)"
      )
      context.wallpaperInspectionOverride = AdapterInspection(
        adapterID: WallpaperAdapter.id,
        requirement: .required,
        status: .failed,
        message: "Cannot inspect active theme wallpaper: \(error)"
      )
    }
    let selectedIDs = Set(adapterIDs)
    return configuredAdapters(context: context).map { $0.inspection() }.filter {
      adapterIDs.isEmpty || selectedIDs.contains($0.adapterID)
    }
  }

  package func reconcile(
    adapterIDs: [String]
  ) async throws -> (manifest: GenerationManifest, record: ReconciliationRecord) {
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(
      context: AdapterResolutionContext(
        desiredWallpaperURL: activeWallpaperURL(manifest: manifest),
        unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      )
    )
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

  private func configuredAdapters(context: AdapterResolutionContext) -> [ConfiguredAdapter] {
    ConsumerCatalog.shared.runtimeEntries.map { entry in
      configuredAdapter(entry, context: context)
    }
  }

  private func configuredAdapter(
    _ entry: ConsumerCatalogEntry,
    context: AdapterResolutionContext
  ) -> ConfiguredAdapter {
    switch entry.mode.runtimeKind! {
    case .macOSAppearance:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in _ = try appearance.preflight() },
        inspection: {
          context.appearanceInspectionOverride
            ?? appearance.inspection(desiredAppearance: context.desiredAppearance)
        },
        reconciliation: {
          appearance.reconciliation {
            let manifest = try statusStore.activeManifest()
            return try activeAppearance(manifest: manifest)
          }
        }
      )
    case .atuin:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try atuin.preflight() },
        inspection: atuin.inspection,
        reconciliation: atuin.reconciliation
      )
    case .bat:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try bat.preflight() },
        inspection: bat.inspection,
        reconciliation: bat.reconciliation
      )
    case .btop:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try btop.preflight() },
        inspection: btop.inspection,
        reconciliation: btop.reconciliation
      )
    case .codex:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try codex.preflight() },
        inspection: codex.inspection,
        reconciliation: codex.reconciliation
      )
    case .eza:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try eza.preflight() },
        inspection: eza.inspection,
        reconciliation: eza.reconciliation
      )
    case .herdr:
      return configuredNamedThemeAdapter(
        entry: entry,
        unsupportedAdapterIDs: context.unsupportedAdapterIDs,
        preflight: { context in try herdr.preflight(package: context.package) },
        inspection: herdr.inspection,
        reconciliation: herdr.reconciliation
      )
    case .kitty:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try kitty.preflight() },
        inspection: kitty.inspection,
        reconciliation: kitty.reconciliation
      )
    case .neovim:
      return configuredNamedThemeAdapter(
        entry: entry,
        unsupportedAdapterIDs: context.unsupportedAdapterIDs,
        preflight: { context in try neovim.preflight(package: context.package) },
        inspection: {
          neovim.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
        },
        reconciliation: neovim.reconciliation
      )
    case .pi:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try pi.preflight() },
        inspection: pi.inspection,
        reconciliation: pi.reconciliation
      )
    case .sketchyBar:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try sketchyBar.preflight() },
        inspection: {
          sketchyBar.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
        },
        reconciliation: sketchyBar.reconciliation
      )
    case .spicetify:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in },
        inspection: spicetify.inspection,
        reconciliation: spicetify.reconciliation
      )
    case .starship:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try starship.preflight() },
        inspection: starship.inspection,
        reconciliation: starship.reconciliation
      )
    case .tuicr:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try tuicr.preflight() },
        inspection: tuicr.inspection,
        reconciliation: tuicr.reconciliation
      )
    case .wallpaper:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { preflightContext in
          guard preflightContext.hasSelectedWallpaper else { return }
          _ = try wallpaper.preflight()
          try wallpaperSignal.preflight()
        },
        inspection: {
          if let inspection = context.wallpaperInspectionOverride {
            return inspection
          }
          return inspectWallpaper(
            desiredWallpaperURL: context.desiredWallpaperURL,
            intentionallyUnmanaged: context.wallpaperIntentionallyUnmanaged
              ?? ((try? statusStore.activeManifest()).map {
                activeWallpaperURL(manifest: $0) == nil
              } ?? false),
            includeRuntimeChecks: context.includeRuntimeChecks
          )
        },
        reconciliation: {
          AdapterReconciliation(id: WallpaperAdapter.id, requirement: .required) {
            try await wallpaper.reconciliation {
              let manifest = try statusStore.activeManifest()
              return activeWallpaperURL(manifest: manifest)
            }.run()
          }
        }
      )
    case .yazi:
      return ConfiguredAdapter(
        entry: entry,
        preflight: { _ in try yazi.preflight() },
        inspection: yazi.inspection,
        reconciliation: yazi.reconciliation
      )
    }
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

  private func prepare(
    package: ThemePackage,
    requestedBackgroundID: String?,
    recoverActivePreference: Bool
  ) throws -> PreparedThemeBackground {
    let configuration = try configurationStore.load()
    let effectivePackage = try package.addingPersonalBackgrounds(
      configuration.personalBackgrounds(themeID: package.id)
    )
    var preferences = try backgroundPreferences.load()
    if recoverActivePreference,
      let active = try activeManifestIfPresent(),
      active.manifestSchemaVersion == GenerationManifest.currentSchemaVersion
    {
      let prior = preferences
      if let background = active.background {
        preferences[active.themeID] = background.id
      } else {
        preferences.removeValue(forKey: active.themeID)
      }
      if preferences != prior {
        try backgroundPreferences.persist(preferences)
      }
    }
    let background = try BackgroundSelectionResolver.resolve(
      package: effectivePackage,
      requestedBackgroundID: requestedBackgroundID,
      preferences: preferences
    )
    let preflightContext = AdapterPreflightContext(
      package: package,
      hasSelectedWallpaper: background.selection != nil
    )
    for adapter in configuredAdapters(context: AdapterResolutionContext()) {
      try adapter.preflight(preflightContext)
    }
    return background
  }

  private func activeWallpaperURL(manifest: GenerationManifest) -> URL? {
    guard manifest.artifacts[WallpaperAdapter.outputPath] != nil else { return nil }
    return root.appending(
      path: "generations/\(manifest.generationID)/\(WallpaperAdapter.outputPath)"
    )
  }

  private func inspectWallpaper(
    desiredWallpaperURL: URL?,
    intentionallyUnmanaged: Bool,
    includeRuntimeChecks: Bool
  ) -> AdapterInspection {
    guard !intentionallyUnmanaged else {
      return AdapterInspection(
        adapterID: WallpaperAdapter.id,
        requirement: .required,
        message: "The active theme has no backgrounds; macOS wallpaper is intentionally unmanaged"
      )
    }
    let wallpaperInspection = wallpaper.inspection(
      desiredWallpaperURL: desiredWallpaperURL
    )
    do {
      try wallpaperSignal.preflight()
      if includeRuntimeChecks {
        try wallpaperSignal.runtimePreflight(processRunner: processRunner)
      }
      var messages = [wallpaperInspection.message, wallpaperSignal.readyMessage].compactMap { $0 }
      if includeRuntimeChecks {
        messages.append("the yabai signal is loaded")
      }
      return AdapterInspection(
        adapterID: WallpaperAdapter.id,
        requirement: .required,
        status: wallpaperInspection.status,
        message: messages.joined(separator: "; ")
      )
    } catch {
      let signalStatus: AdapterInspectionStatus
      if case YabaiWallpaperSignalError.missingDirective = error {
        signalStatus = .drifted
      } else if case YabaiWallpaperSignalError.runtimeSignalMissing = error {
        signalStatus = .drifted
      } else {
        signalStatus = .failed
      }
      return AdapterInspection(
        adapterID: WallpaperAdapter.id,
        requirement: .required,
        status: Self.mostSevere(wallpaperInspection.status, signalStatus),
        message: [wallpaperInspection.message, String(describing: error)]
          .compactMap { $0 }
          .joined(separator: "; ")
      )
    }
  }

  private func activeManifestIfPresent() throws -> GenerationManifest? {
    do {
      return try statusStore.activeManifest()
    } catch ReconciliationStatusError.noActiveGeneration {
      return nil
    }
  }

  private func persistPreference(manifest: GenerationManifest) throws {
    var preferences = try backgroundPreferences.load()
    let prior = preferences
    if let background = manifest.background {
      preferences[manifest.themeID] = background.id
    } else {
      preferences.removeValue(forKey: manifest.themeID)
    }
    if preferences != prior {
      try backgroundPreferences.persist(preferences)
    }
  }

  private func previousReconciliationEvidence() throws -> PreviousReconciliationEvidence? {
    guard let manifest = try activeManifestIfPresent() else { return nil }
    let state: ReconciliationState
    do {
      state = try statusStore.reconciliationState(for: manifest)
    } catch {
      return PreviousReconciliationEvidence(manifest: manifest, record: nil)
    }
    guard case .current(let record) = state else {
      return PreviousReconciliationEvidence(manifest: manifest, record: nil)
    }
    return PreviousReconciliationEvidence(manifest: manifest, record: record)
  }

  private func backgroundOnlyReconciliationPlan(
    requestedBackgroundID: String?,
    previousEvidence: PreviousReconciliationEvidence?,
    manifest: GenerationManifest,
    adapters: [ConfiguredAdapter]
  ) -> (adapters: [ConfiguredAdapter], preservedResults: [AdapterResult]) {
    guard
      requestedBackgroundID != nil,
      let previousEvidence,
      previousEvidence.manifest.themeDigest == manifest.themeDigest,
      !manifest.themeDigest.isEmpty,
      let record = previousEvidence.record,
      isCompleteReconciliation(record)
    else { return (adapters, []) }

    if previousEvidence.manifest.generationID == manifest.generationID {
      return (
        adapters.filter { $0.id == WallpaperAdapter.id },
        record.results.filter { $0.adapterID != WallpaperAdapter.id }
      )
    }

    let carried = record.results.filter { $0.adapterID != WallpaperAdapter.id }.map { result in
      AdapterResult(
        adapterID: result.adapterID,
        requirement: result.requirement,
        status: result.status,
        message: result.message,
        carriedForwardFromGenerationID: previousEvidence.manifest.generationID
      )
    }
    let carriedIDs = Set(carried.map(\.adapterID))
    return (
      adapters.filter { $0.id == WallpaperAdapter.id || !carriedIDs.contains($0.id) },
      carried
    )
  }

  private func isCompleteReconciliation(_ record: ReconciliationRecord) -> Bool {
    guard Set(record.results.map(\.adapterID)) == Set(Self.adapterRequirements.keys) else {
      return false
    }
    return record.results.allSatisfy { result in
      Self.adapterRequirements[result.adapterID] == result.requirement
    }
  }

  private static func mostSevere(
    _ first: AdapterInspectionStatus,
    _ second: AdapterInspectionStatus
  ) -> AdapterInspectionStatus {
    if first == .failed || second == .failed { return .failed }
    if first == .drifted || second == .drifted { return .drifted }
    return .ready
  }

  private func unsupportedNamedThemeAdapterIDs(
    manifest: GenerationManifest
  ) throws -> Set<String> {
    guard manifest.artifacts[ThemeRenderer.capabilitiesOutputPath] != nil else {
      return []
    }
    let url = root.appending(
      path:
        "generations/\(manifest.generationID)/\(ThemeRenderer.capabilitiesOutputPath)"
    )
    do {
      let capabilities = try JSONDecoder().decode(
        GeneratedThemeCapabilities.self,
        from: BoundedRegularFile.read(at: url).data
      )
      return Set(try capabilities.validated().unsupportedAdapters)
    } catch {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "generated capabilities are invalid: \(error)"
      )
    }
  }

  private func configuredNamedThemeAdapter(
    entry: ConsumerCatalogEntry,
    unsupportedAdapterIDs: Set<String>,
    preflight: @escaping @Sendable (AdapterPreflightContext) throws -> Void,
    inspection: @escaping @Sendable () -> AdapterInspection,
    reconciliation: @escaping @Sendable () -> AdapterReconciliation
  ) -> ConfiguredAdapter {
    let id = entry.id.rawValue
    guard unsupportedAdapterIDs.contains(id) else {
      return ConfiguredAdapter(
        entry: entry,
        preflight: preflight,
        inspection: inspection,
        reconciliation: reconciliation
      )
    }
    return ConfiguredAdapter(
      entry: entry,
      preflight: preflight,
      inspection: {
        AdapterInspection(
          adapterID: id,
          requirement: entry.mode.requirement!,
          status: .unsupported,
          message: unsupportedNamedThemeMessage(adapterID: id)
        )
      },
      reconciliation: {
        AdapterReconciliation(id: id, requirement: entry.mode.requirement!) {
          AdapterOutcome(
            status: .unsupported,
            message: unsupportedNamedThemeMessage(adapterID: id)
          )
        }
      }
    )
  }

  private func unsupportedNamedThemeMessage(adapterID: String) -> String {
    "The active theme has no safe \(adapterID) named-theme mapping; its prior appearance is retained"
  }

  package static func kittyIncludeDirective(root: URL) -> String {
    "include \(root.appending(path: KittyAdapter.bridgePath).path)"
  }
}

private struct PreviousReconciliationEvidence: Sendable {
  let manifest: GenerationManifest
  let record: ReconciliationRecord?
}

private struct AdapterResolutionContext: Sendable {
  var desiredAppearance: ThemeAppearance? = nil
  var desiredWallpaperURL: URL? = nil
  var unsupportedAdapterIDs = Set<String>()
  var includeRuntimeChecks = false
  var appearanceInspectionOverride: AdapterInspection?
  var wallpaperInspectionOverride: AdapterInspection?
  var wallpaperIntentionallyUnmanaged: Bool?
}

private struct AdapterPreflightContext: Sendable {
  let package: ThemePackage
  let hasSelectedWallpaper: Bool
}

private struct ConfiguredAdapter: Sendable {
  let entry: ConsumerCatalogEntry
  private let runPreflight: @Sendable (AdapterPreflightContext) throws -> Void
  private let inspect: @Sendable () -> AdapterInspection
  private let reconcile: @Sendable () -> AdapterReconciliation

  init(
    entry: ConsumerCatalogEntry,
    preflight: @escaping @Sendable (AdapterPreflightContext) throws -> Void,
    inspection: @escaping @Sendable () -> AdapterInspection,
    reconciliation: @escaping @Sendable () -> AdapterReconciliation
  ) {
    self.entry = entry
    runPreflight = preflight
    inspect = inspection
    reconcile = reconciliation
  }

  var id: String { entry.id.rawValue }

  func preflight(_ context: AdapterPreflightContext) throws {
    try runPreflight(context)
  }

  func inspection() -> AdapterInspection {
    let inspection = inspect()
    precondition(
      inspection.adapterID == id && inspection.requirement == entry.mode.requirement,
      "Runtime inspection disagrees with the consumer catalog for '\(id)'"
    )
    return inspection
  }

  func reconciliation() -> AdapterReconciliation {
    let reconciliation = reconcile()
    precondition(
      reconciliation.id == id && reconciliation.requirement == entry.mode.requirement,
      "Runtime reconciliation disagrees with the consumer catalog for '\(id)'"
    )
    return reconciliation
  }
}
