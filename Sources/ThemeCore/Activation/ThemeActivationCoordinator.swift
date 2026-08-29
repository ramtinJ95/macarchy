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
    let statusStore = ReconciliationStatusStore(root: root)
    self.root = root
    activator = ThemeActivator(root: root)
    appearance = .live(root: root)
    atuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.atuinConfigurationDirectoryURL,
      executableURL: AtuinAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: AtuinAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    bat = BatAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.batConfigurationDirectoryURL,
      cacheDirectoryURL: consumerPaths.batCacheDirectoryURL,
      executableURL: BatAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: BatAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    btop = BtopAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.btopConfigurationDirectoryURL,
      executableURL: BtopAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: BtopAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    codex = CodexAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.codexConfigurationDirectoryURL,
      executableURL: CodexAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: CodexAdapter.liveExecutableURL.path)
      }
    )
    configurationStore = MacarchyConfigurationStore(root: root)
    eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: consumerPaths.shellConfigurationURL,
      executableURL: EzaAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: EzaAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    herdr = HerdrAdapter(
      root: root,
      configurationURL: consumerPaths.herdrConfigurationURL,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: HerdrAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    kitty = KittyAdapter(
      root: root,
      configurationURL: consumerPaths.kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: .live
    )
    neovim = NeovimAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.neovimConfigurationDirectoryURL,
      executableURL: NeovimAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: NeovimAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    pi = PiAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.piConfigurationDirectoryURL,
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: PiAdapter.liveExecutableURL.path)
      }
    )
    processRunner = .live
    reconciler = ThemeReconciler(statusStore: statusStore)
    sketchyBar = SketchyBarAdapter(
      root: root,
      configurationURL: consumerPaths.sketchyBarConfigurationURL,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: SketchyBarAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    spicetify = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.spicetifyConfigurationDirectoryURL,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: SpicetifyAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    starship = StarshipAdapter(
      root: root,
      configurationURL: consumerPaths.starshipConfigurationURL,
      behaviorURL: consumerPaths.starshipBehaviorURL,
      executableURL: StarshipAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: StarshipAdapter.liveExecutableURL.path)
      },
      processRunner: .live
    )
    self.statusStore = statusStore
    tuicr = TuicrAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.tuicrConfigurationDirectoryURL,
      executableURL: TuicrAdapter.liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: TuicrAdapter.liveExecutableURL.path)
      }
    )
    wallpaper = WallpaperAdapter(root: root, control: .live)
    wallpaperSignal = .personal()
    yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.yaziConfigurationDirectoryURL,
      executableURL: YaziAdapter.liveExecutableURL,
      controlURL: YaziAdapter.liveControlURL,
      controlsAreAvailable: {
        FileManager.default.isExecutableFile(atPath: YaziAdapter.liveExecutableURL.path)
          && FileManager.default.isExecutableFile(atPath: YaziAdapter.liveControlURL.path)
      },
      processRunner: .live
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
    atuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.atuinConfigurationDirectoryURL,
      executableURL: AtuinAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    bat = BatAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.batConfigurationDirectoryURL,
      cacheDirectoryURL: consumerPaths.batCacheDirectoryURL,
      executableURL: BatAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    btop = BtopAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.btopConfigurationDirectoryURL,
      executableURL: BtopAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    codex = CodexAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.codexConfigurationDirectoryURL,
      executableURL: CodexAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    )
    configurationStore = MacarchyConfigurationStore(root: root)
    eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: consumerPaths.shellConfigurationURL,
      executableURL: EzaAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    herdr = HerdrAdapter(
      root: root,
      configurationURL: consumerPaths.herdrConfigurationURL,
      executableURL: HerdrAdapter.liveExecutableURL,
      controlIsAvailable: { true },
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
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    pi = PiAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.piConfigurationDirectoryURL,
      executableURL: PiAdapter.liveExecutableURL,
      controlIsAvailable: { true }
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
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    starship = StarshipAdapter(
      root: root,
      configurationURL: consumerPaths.starshipConfigurationURL,
      behaviorURL: consumerPaths.starshipBehaviorURL,
      executableURL: StarshipAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: processRunner
    )
    self.statusStore = statusStore
    tuicr = TuicrAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.tuicrConfigurationDirectoryURL,
      executableURL: TuicrAdapter.liveExecutableURL,
      controlIsAvailable: { true }
    )
    wallpaper = WallpaperAdapter(root: root, control: wallpaperControl)
    self.wallpaperSignal = wallpaperSignal
    yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: consumerPaths.yaziConfigurationDirectoryURL,
      executableURL: YaziAdapter.liveExecutableURL,
      controlURL: YaziAdapter.liveControlURL,
      controlsAreAvailable: { true },
      processRunner: processRunner
    )
  }

  package func preflight(package: ThemePackage) throws {
    let wallpaperData = try prepare(package: package)
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "dry-run-\(package.id)",
      wallpaperData: wallpaperData
    )
  }

  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String? = nil
  ) async throws -> ThemeActivationResult {
    try await withTaskExecutorPreference(Self.activationExecutor) {
      try Task.checkCancellation()
      let manifest = try activator.activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID,
        prepareWallpaperData: {
          let wallpaperData = try prepare(package: package)
          try Task.checkCancellation()
          return wallpaperData
        }
      )

      do {
        let reconciliation = try await reconciler.reconcile(
          manifest: manifest,
          adapters: configuredAdapters(
            desiredAppearance: package.appearance,
            desiredWallpaperURL: nil,
            unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
          ).map {
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
  }

  package func previewReconciliation(
    _ adapterIDs: [String]
  ) throws -> (manifest: GenerationManifest, inspections: [AdapterInspection]) {
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(
      desiredAppearance: try activeAppearance(manifest: manifest),
      desiredWallpaperURL: activeWallpaperURL(manifest: manifest),
      unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
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
    let appearanceInspection: AdapterInspection
    let wallpaperInspection: AdapterInspection
    var unsupportedAdapterIDs = Set<String>()
    do {
      let manifest = try statusStore.activeManifest()
      unsupportedAdapterIDs = try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      do {
        appearanceInspection = appearance.inspection(
          desiredAppearance: try activeAppearance(manifest: manifest)
        )
      } catch {
        appearanceInspection = AdapterInspection(
          adapterID: MacOSAppearanceAdapter.id,
          requirement: .required,
          status: .failed,
          message: "Cannot inspect active theme appearance: \(error)"
        )
      }
      wallpaperInspection = inspectWallpaper(
        desiredWallpaperURL: activeWallpaperURL(manifest: manifest),
        includeRuntimeChecks: includeRuntimeChecks
      )
    } catch ReconciliationStatusError.noActiveGeneration {
      appearanceInspection = appearance.inspection(desiredAppearance: nil)
      wallpaperInspection = inspectWallpaper(
        desiredWallpaperURL: nil,
        includeRuntimeChecks: includeRuntimeChecks
      )
    } catch {
      appearanceInspection = AdapterInspection(
        adapterID: MacOSAppearanceAdapter.id,
        requirement: .required,
        status: .failed,
        message: "Cannot inspect active theme appearance: \(error)"
      )
      wallpaperInspection = AdapterInspection(
        adapterID: WallpaperAdapter.id,
        requirement: .required,
        status: .failed,
        message: "Cannot inspect active theme wallpaper: \(error)"
      )
    }
    let selectedIDs = Set(adapterIDs)
    return configuredAdapters(
      desiredAppearance: nil,
      desiredWallpaperURL: nil,
      unsupportedAdapterIDs: unsupportedAdapterIDs,
      includeRuntimeChecks: includeRuntimeChecks
    ).map { adapter in
      switch adapter.id {
      case MacOSAppearanceAdapter.id:
        appearanceInspection
      case WallpaperAdapter.id:
        wallpaperInspection
      default:
        adapter.inspection()
      }
    }.filter {
      adapterIDs.isEmpty || selectedIDs.contains($0.adapterID)
    }
  }

  package func reconcile(
    adapterIDs: [String]
  ) async throws -> (manifest: GenerationManifest, record: ReconciliationRecord) {
    try validateSelection(adapterIDs)
    let manifest = try statusStore.activeManifest()
    let adapters = configuredAdapters(
      desiredAppearance: nil,
      desiredWallpaperURL: nil,
      unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
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

  private func configuredAdapters(
    desiredAppearance: ThemeAppearance?,
    desiredWallpaperURL: URL?,
    unsupportedAdapterIDs: Set<String>,
    includeRuntimeChecks: Bool = false
  ) -> [ConfiguredAdapter] {
    ConsumerCatalog.shared.runtimeEntries.map { entry in
      configuredAdapter(
        entry,
        desiredAppearance: desiredAppearance,
        desiredWallpaperURL: desiredWallpaperURL,
        unsupportedAdapterIDs: unsupportedAdapterIDs,
        includeRuntimeChecks: includeRuntimeChecks
      )
    }
  }

  private func configuredAdapter(
    _ entry: ConsumerCatalogEntry,
    desiredAppearance: ThemeAppearance?,
    desiredWallpaperURL: URL?,
    unsupportedAdapterIDs: Set<String>,
    includeRuntimeChecks: Bool
  ) -> ConfiguredAdapter {
    switch entry.mode.runtimeKind! {
    case .macOSAppearance:
      return ConfiguredAdapter(
        entry: entry,
        inspection: { appearance.inspection(desiredAppearance: desiredAppearance) },
        reconciliation: {
          appearance.reconciliation {
            let manifest = try statusStore.activeManifest()
            return try activeAppearance(manifest: manifest)
          }
        }
      )
    case .atuin:
      return ConfiguredAdapter(
        entry: entry, inspection: atuin.inspection, reconciliation: atuin.reconciliation)
    case .bat:
      return ConfiguredAdapter(
        entry: entry, inspection: bat.inspection, reconciliation: bat.reconciliation)
    case .btop:
      return ConfiguredAdapter(
        entry: entry, inspection: btop.inspection, reconciliation: btop.reconciliation)
    case .codex:
      return ConfiguredAdapter(
        entry: entry, inspection: codex.inspection, reconciliation: codex.reconciliation)
    case .eza:
      return ConfiguredAdapter(
        entry: entry, inspection: eza.inspection, reconciliation: eza.reconciliation)
    case .herdr:
      return configuredNamedThemeAdapter(
        entry: entry,
        unsupportedAdapterIDs: unsupportedAdapterIDs,
        inspection: herdr.inspection,
        reconciliation: herdr.reconciliation
      )
    case .kitty:
      return ConfiguredAdapter(
        entry: entry, inspection: kitty.inspection, reconciliation: kitty.reconciliation)
    case .neovim:
      return configuredNamedThemeAdapter(
        entry: entry,
        unsupportedAdapterIDs: unsupportedAdapterIDs,
        inspection: { neovim.inspection(includeRuntimeChecks: includeRuntimeChecks) },
        reconciliation: neovim.reconciliation
      )
    case .pi:
      return ConfiguredAdapter(
        entry: entry, inspection: pi.inspection, reconciliation: pi.reconciliation)
    case .sketchyBar:
      return ConfiguredAdapter(
        entry: entry,
        inspection: { sketchyBar.inspection(includeRuntimeChecks: includeRuntimeChecks) },
        reconciliation: sketchyBar.reconciliation
      )
    case .spicetify:
      return ConfiguredAdapter(
        entry: entry, inspection: spicetify.inspection, reconciliation: spicetify.reconciliation)
    case .starship:
      return ConfiguredAdapter(
        entry: entry, inspection: starship.inspection, reconciliation: starship.reconciliation)
    case .tuicr:
      return ConfiguredAdapter(
        entry: entry, inspection: tuicr.inspection, reconciliation: tuicr.reconciliation)
    case .wallpaper:
      return ConfiguredAdapter(
        entry: entry,
        inspection: {
          inspectWallpaper(
            desiredWallpaperURL: desiredWallpaperURL,
            includeRuntimeChecks: includeRuntimeChecks
          )
        },
        reconciliation: {
          wallpaper.reconciliation {
            let manifest = try statusStore.activeManifest()
            return activeWallpaperURL(manifest: manifest)
          }
        }
      )
    case .yazi:
      return ConfiguredAdapter(
        entry: entry, inspection: yazi.inspection, reconciliation: yazi.reconciliation)
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

  private func prepare(package: ThemePackage) throws -> Data {
    let configuration = try configurationStore.load()
    let wallpaperData =
      try configuration.wallpaperData(themeID: package.id)
      ?? package.defaultBackgroundData
    for entry in ConsumerCatalog.shared.runtimeEntries {
      switch entry.mode.runtimeKind! {
      case .macOSAppearance:
        _ = try appearance.preflight()
      case .atuin:
        try atuin.preflight()
      case .bat:
        try bat.preflight()
      case .btop:
        try btop.preflight()
      case .codex:
        try codex.preflight()
      case .eza:
        try eza.preflight()
      case .herdr:
        try herdr.preflight(package: package)
      case .kitty:
        try kitty.preflight()
      case .neovim:
        try neovim.preflight(package: package)
      case .pi:
        try pi.preflight()
      case .sketchyBar:
        try sketchyBar.preflight()
      case .spicetify:
        break
      case .starship:
        try starship.preflight()
      case .tuicr:
        try tuicr.preflight()
      case .wallpaper:
        _ = try wallpaper.preflight()
        try wallpaperSignal.preflight()
      case .yazi:
        try yazi.preflight()
      }
    }
    return wallpaperData
  }

  private func activeWallpaperURL(manifest: GenerationManifest) -> URL {
    root.appending(
      path: "generations/\(manifest.generationID)/\(WallpaperAdapter.outputPath)"
    )
  }

  private func inspectWallpaper(
    desiredWallpaperURL: URL?,
    includeRuntimeChecks: Bool
  ) -> AdapterInspection {
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
    inspection: @escaping @Sendable () -> AdapterInspection,
    reconciliation: @escaping @Sendable () -> AdapterReconciliation
  ) -> ConfiguredAdapter {
    let id = entry.id.rawValue
    guard unsupportedAdapterIDs.contains(id) else {
      return ConfiguredAdapter(
        entry: entry,
        inspection: inspection,
        reconciliation: reconciliation
      )
    }
    return ConfiguredAdapter(
      entry: entry,
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

private struct ConfiguredAdapter: Sendable {
  let entry: ConsumerCatalogEntry
  private let inspect: @Sendable () -> AdapterInspection
  private let reconcile: @Sendable () -> AdapterReconciliation

  init(
    entry: ConsumerCatalogEntry,
    inspection: @escaping @Sendable () -> AdapterInspection,
    reconciliation: @escaping @Sendable () -> AdapterReconciliation
  ) {
    self.entry = entry
    inspect = inspection
    reconcile = reconciliation
  }

  var id: String { entry.id.rawValue }

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
