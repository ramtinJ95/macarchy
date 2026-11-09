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

  package init(manifest: GenerationManifest, cause: String) {
    self.manifest = manifest
    self.cause = cause
  }

  package var description: String {
    "Theme '\(manifest.themeID)' committed as generation '\(manifest.generationID)', but reconciliation failed: \(cause)"
  }
}

package enum AdapterSelectionError: Error, CustomStringConvertible, Equatable, Sendable {
  case disabled(String)
  case duplicate(String)
  case unknown(String)

  package var description: String {
    switch self {
    case .disabled(let adapterID):
      "Adapter '\(adapterID)' is disabled in the applied environment"
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
  private let backgroundPreferences: BackgroundPreferenceStore
  private let configurationStore: MacarchyConfigurationStore
  private let enabledAdapterIDs: Set<String>
  private let reconciler: ThemeReconciler
  private let runtimeConsumers: [RuntimeAdapterKind: RuntimeConsumer]
  private let statusStore: ReconciliationStatusStore
  private let themeGenerations: ThemeGenerationReader

  package init(
    root: URL,
    consumerPaths: ThemeConsumerPaths,
    enabledAdapterIDs: Set<String>? = nil,
    herdrManagedMode: HerdrManagedMode? = nil,
    bordersManagedMode: BordersManagedMode? = nil,
    leanFocusManagedMode: BordersManagedMode? = nil,
    piSelectionIsApplied: @escaping @Sendable () throws -> Bool = { true },
    piThemeLinkRefreshIsAllowed: @escaping @Sendable () throws -> Bool = { true }
  ) {
    let root = root.standardizedFileURL
    let appearance = MacOSAppearanceAdapter.live(root: root)
    let controlIsAvailable: @Sendable (URL) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    let macarchyExecutableURL = MacarchyCommandPath.persistentURL(
      for: MacarchyCommandPath.currentExecutableURL)
    self.init(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: .live,
      wallpaperControl: .live,
      wallpaperSignal: .personal(macarchyExecutableURL: macarchyExecutableURL),
      currentAppearance: appearance.currentAppearance,
      appearanceControlIsAvailable: appearance.controlIsAvailable,
      sketchyBarControlIsAvailable: {
        controlIsAvailable(SketchyBarAdapter.liveExecutableURL)
      },
      controlIsAvailable: controlIsAvailable,
      enabledAdapterIDs: enabledAdapterIDs,
      herdrManagedMode: herdrManagedMode,
      bordersManagedMode: bordersManagedMode,
      leanFocusManagedMode: leanFocusManagedMode,
      piSelectionIsApplied: piSelectionIsApplied,
      piThemeLinkRefreshIsAllowed: piThemeLinkRefreshIsAllowed,
      spicetifyVersionProvider: {
        try SpicetifyAdapter.commandVersion(processRunner: .live)
      },
      spotifyVersionProvider: {
        try SpicetifyAdapter.spotifyBundleVersion()
      },
      spicetifyRefreshPreparation: {
        try SpicetifyAdapter.requireRefreshPreparation(
          configurationDirectoryURL: consumerPaths.spicetifyConfigurationDirectoryURL)
      }
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
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in },
    enabledAdapterIDs: Set<String>? = nil,
    herdrManagedMode: HerdrManagedMode? = nil,
    bordersManagedMode: BordersManagedMode? = nil,
    leanFocusManagedMode: BordersManagedMode? = nil,
    piSelectionIsApplied: @escaping @Sendable () throws -> Bool = { true },
    piThemeLinkRefreshIsAllowed: @escaping @Sendable () throws -> Bool = { true },
    spicetifyVersionProvider: @escaping @Sendable () throws -> String = {
      SpicetifyAdapter.minimumVersion
    },
    spotifyVersionProvider: @escaping @Sendable () throws -> String = { "1.2.97" },
    spicetifyRefreshPreparation: @escaping @Sendable () throws -> Void = {}
  ) {
    let root = root.standardizedFileURL
    let statusStore = ReconciliationStatusStore(root: root)
    let themeGenerations = ThemeGenerationReader(root: root)
    self.root = root
    activator = ThemeActivator(
      root: root,
      faultInjector: faultInjector,
      onThemeChanged: onThemeChanged,
      postDarwinNotification: postDarwinNotification
    )
    backgroundPreferences = BackgroundPreferenceStore(root: root)
    configurationStore = MacarchyConfigurationStore(root: root)
    self.enabledAdapterIDs = enabledAdapterIDs ?? ConsumerCatalog.shared.defaultEnabledAdapterIDs
    reconciler = ThemeReconciler(statusStore: statusStore)
    self.statusStore = statusStore
    self.themeGenerations = themeGenerations

    func consumer(_ kind: RuntimeAdapterKind) -> RuntimeConsumer {
      switch kind {
      case .macOSAppearance:
        let appearance = MacOSAppearanceAdapter(
          root: root,
          controlIsAvailable: appearanceControlIsAvailable,
          currentAppearance: currentAppearance,
          processRunner: processRunner
        )
        return RuntimeConsumer(
          preflight: { _ in _ = try appearance.preflight() },
          inspection: { context in
            context.appearanceInspectionOverride
              ?? appearance.inspection(desiredAppearance: context.desiredAppearance)
          },
          reconciliation: {
            appearance.reconciliation {
              let manifest = try themeGenerations.activeManifest()
              return try Self.activeAppearance(manifest: manifest, root: root)
            }
          }
        )
      case .atuin:
        return RuntimeConsumer(
          AtuinAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.atuinConfigurationDirectoryURL,
            executableURL: AtuinAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(AtuinAdapter.liveExecutableURL) },
            processRunner: processRunner
          ))
      case .bat:
        return RuntimeConsumer(
          BatAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.batConfigurationDirectoryURL,
            cacheDirectoryURL: consumerPaths.batCacheDirectoryURL,
            executableURL: BatAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(BatAdapter.liveExecutableURL) },
            processRunner: processRunner
          ))
      case .btop:
        return RuntimeConsumer(
          BtopAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.btopConfigurationDirectoryURL,
            executableURL: BtopAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(BtopAdapter.liveExecutableURL) },
            processRunner: processRunner
          ))
      case .borders:
        return RuntimeConsumer(BordersAdapter(managedMode: bordersManagedMode))
      case .leanFocus:
        return RuntimeConsumer(
          BordersAdapter(managedMode: leanFocusManagedMode, consumer: .leanFocus))
      case .codex:
        let codex = CodexAdapter(
          root: root,
          configurationDirectoryURL: consumerPaths.codexConfigurationDirectoryURL,
          executableURL: CodexAdapter.liveExecutableURL,
          controlIsAvailable: { controlIsAvailable(CodexAdapter.liveExecutableURL) },
          processRunner: processRunner
        )
        return RuntimeConsumer(
          preflight: { _ in try codex.preflight() },
          inspection: { context in
            codex.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
          },
          reconciliation: codex.reconciliation
        )
      case .eza:
        return RuntimeConsumer(
          EzaAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.ezaConfigurationDirectoryURL,
            shellConfigurationURL: consumerPaths.shellConfigurationURL,
            executableURL: EzaAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(EzaAdapter.liveExecutableURL) },
            processRunner: processRunner
          ))
      case .herdr:
        let herdr = HerdrAdapter(
          root: root,
          configurationURL: consumerPaths.herdrConfigurationURL,
          executableURL: HerdrAdapter.liveExecutableURL,
          controlIsAvailable: { controlIsAvailable(HerdrAdapter.liveExecutableURL) },
          processRunner: processRunner,
          managedMode: herdrManagedMode
        )
        return RuntimeConsumer(
          preflight: { context in try herdr.preflight(package: context.package) },
          inspection: { context in
            herdr.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
          },
          reconciliation: herdr.reconciliation
        )
      case .kitty:
        return RuntimeConsumer(
          KittyAdapter(
            root: root,
            configurationURL: consumerPaths.kittyConfigurationURL,
            includeDirective: KittyAdapter.includeDirective(stateRoot: root),
            processRunner: processRunner
          ))
      case .neovim:
        let neovim = NeovimAdapter(
          root: root,
          configurationDirectoryURL: consumerPaths.neovimConfigurationDirectoryURL,
          executableURL: NeovimAdapter.liveExecutableURL,
          controlIsAvailable: { controlIsAvailable(NeovimAdapter.liveExecutableURL) },
          processRunner: processRunner
        )
        return RuntimeConsumer(
          preflight: { context in try neovim.preflight(package: context.package) },
          inspection: { context in
            neovim.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
          },
          reconciliation: neovim.reconciliation
        )
      case .pi:
        let pi = PiAdapter(
          root: root,
          configurationDirectoryURL: consumerPaths.piConfigurationDirectoryURL,
          executableURL: PiAdapter.liveExecutableURL,
          controlIsAvailable: { controlIsAvailable(PiAdapter.liveExecutableURL) },
          processRunner: processRunner,
          selectionIsApplied: piSelectionIsApplied,
          themeLinkRefreshIsAllowed: piThemeLinkRefreshIsAllowed
        )
        return RuntimeConsumer(
          preflight: { _ in try pi.preflight() },
          inspection: { context in
            pi.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
          },
          reconciliation: pi.reconciliation,
          // An externally owned theme link is preserved, so running sessions keep the old
          // palette until /reload or a new launch.
          repaint: { (try? pi.themeLinkRefreshIsAllowed()) == false ? .freshSession : nil }
        )
      case .sketchyBar:
        let sketchyBar = SketchyBarAdapter(
          root: root,
          configurationURL: consumerPaths.sketchyBarConfigurationURL,
          executableURL: SketchyBarAdapter.liveExecutableURL,
          controlIsAvailable: sketchyBarControlIsAvailable,
          processRunner: processRunner
        )
        return RuntimeConsumer(
          preflight: { _ in try sketchyBar.preflight() },
          inspection: { context in
            sketchyBar.inspection(includeRuntimeChecks: context.includeRuntimeChecks)
          },
          reconciliation: sketchyBar.reconciliation
        )
      case .spicetify:
        return RuntimeConsumer(
          SpicetifyAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.spicetifyConfigurationDirectoryURL,
            executableURL: SpicetifyAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(SpicetifyAdapter.liveExecutableURL) },
            processRunner: processRunner,
            spicetifyVersionProvider: spicetifyVersionProvider,
            spotifyVersionProvider: spotifyVersionProvider,
            refreshPreparation: spicetifyRefreshPreparation
          ))
      case .starship:
        return RuntimeConsumer(
          StarshipAdapter(
            root: root,
            configurationURL: consumerPaths.starshipConfigurationURL,
            behaviorURL: consumerPaths.starshipBehaviorURL,
            executableURL: StarshipAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(StarshipAdapter.liveExecutableURL) },
            processRunner: processRunner
          ))
      case .tuicr:
        return RuntimeConsumer(
          TuicrAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.tuicrConfigurationDirectoryURL,
            executableURL: TuicrAdapter.liveExecutableURL,
            controlIsAvailable: { controlIsAvailable(TuicrAdapter.liveExecutableURL) }
          ))
      case .wallpaper:
        return Self.wallpaperConsumer(
          WallpaperAdapter(root: root, control: wallpaperControl),
          signal: wallpaperSignal,
          processRunner: processRunner,
          themeGenerations: themeGenerations,
          root: root
        )
      case .yazi:
        return RuntimeConsumer(
          YaziAdapter(
            root: root,
            configurationDirectoryURL: consumerPaths.yaziConfigurationDirectoryURL,
            executableURL: YaziAdapter.liveExecutableURL,
            controlURL: YaziAdapter.liveControlURL,
            controlsAreAvailable: {
              controlIsAvailable(YaziAdapter.liveExecutableURL)
                && controlIsAvailable(YaziAdapter.liveControlURL)
            },
            processRunner: processRunner
          ))
      }
    }
    runtimeConsumers = Dictionary(
      uniqueKeysWithValues: RuntimeAdapterKind.allCases.map { ($0, consumer($0)) })
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

  /// What `activate` would do, as a plan to review; nothing is written. Unlike `preflight`,
  /// every enabled consumer is checked, so the plan lists each failure.
  package func review(
    package: ThemePackage,
    requestedBackgroundID: String? = nil
  ) throws -> ThemeActivationReview {
    // Activation first remembers the active theme's background; the review does the same in
    // memory, so it plans the background activation would pick, without writing.
    let background = try resolveBackground(
      package: package,
      requestedBackgroundID: requestedBackgroundID,
      recoverActivePreference: true,
      persistsRecoveredPreference: false
    )
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "dry-run-\(package.id)",
      wallpaperData: background.data
    )
    let context = AdapterPreflightContext(
      package: package,
      hasSelectedWallpaper: background.selection != nil
    )
    let consumers = configuredAdapters(context: AdapterResolutionContext()).map { adapter in
      let preflight: ThemeActivationReview.Preflight
      do {
        try adapter.preflight(context)
        preflight = .ready
      } catch CanonicalThemeLinkError.absent(_) {
        preflight = .notSetUp
      } catch {
        preflight = .failed(String(describing: error))
      }
      let consumer = ThemeActivationReview.Consumer(
        entry: adapter.entry, preflight: preflight, repaint: adapter.repaint())
      // Without a background the wallpaper adapter leaves the desktop picture as it is.
      if adapter.entry.mode.runtimeKind == .wallpaper, background.selection == nil {
        return consumer.unchanged(because: "unchanged: the theme has no background")
      }
      return consumer
    }
    return try ThemeActivationReview(
      themeID: package.id,
      backgroundID: background.selection?.id,
      activeGenerationID: try themeGenerations.activeManifestIfPresent()?.generationID,
      inputDigest: try activator.reviewInputDigest(package: package, background: background),
      enabledAdapterIDs: enabledAdapterIDs,
      consumers: consumers,
      disabledConsumerIDs: ConsumerCatalog.shared.runtimeEntries.map(\.id.rawValue).filter {
        !enabledAdapterIDs.contains($0)
      }
    )
  }

  /// `onCommittedLocked` runs under the activation lock right after the pointer swap.
  /// A reviewed plan applies every enabled consumer it listed, so `reconcileAllConsumers`
  /// never carries results forward.
  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String? = nil,
    requestedBackgroundID: String? = nil,
    reconcileAllConsumers: Bool = false,
    onCommittedLocked: (GenerationManifest) throws -> Void = { _ in }
  ) async throws -> ThemeActivationResult {
    try await withTaskExecutorPreference(Self.activationExecutor) {
      try Task.checkCancellation()
      var backgroundNotice: String?
      var previousEvidence: PreviousReconciliationEvidence?
      let manifest = try activator.activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID,
        preparedBackground: {
          if !reconcileAllConsumers, requestedBackgroundID != nil {
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
          var preferences = try backgroundPreferences.load()
          try rememberBackground(of: manifest, in: &preferences)
          try onCommittedLocked(manifest)
        }
      )

      do {
        let adapters = configuredAdapters(
          context: AdapterResolutionContext(
            desiredAppearance: package.appearance,
            desiredWallpaperURL: Self.activeWallpaperURL(manifest: manifest, root: root),
            unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
          )
        )
        let plan =
          reconcileAllConsumers
          ? (adapters: adapters, preservedResults: [])
          : backgroundOnlyReconciliationPlan(
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
    let manifest = try themeGenerations.activeManifest()
    let adapters = configuredAdapters(
      context: AdapterResolutionContext(
        desiredAppearance: try Self.activeAppearance(manifest: manifest, root: root),
        desiredWallpaperURL: Self.activeWallpaperURL(manifest: manifest, root: root),
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
    func appearanceFailure(_ error: any Error) -> AdapterInspection {
      AdapterInspection(
        .macOSAppearance,
        status: .failed,
        message: "Cannot inspect active theme appearance: \(error)"
      )
    }
    var context = AdapterResolutionContext(includeRuntimeChecks: includeRuntimeChecks)
    do {
      let manifest = try themeGenerations.activeManifest()
      context.unsupportedAdapterIDs = try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      do {
        context.desiredAppearance = try Self.activeAppearance(manifest: manifest, root: root)
      } catch {
        context.appearanceInspectionOverride = appearanceFailure(error)
      }
      let wallpaperURL = Self.activeWallpaperURL(manifest: manifest, root: root)
      context.desiredWallpaperURL = wallpaperURL
      context.wallpaperIntentionallyUnmanaged = wallpaperURL == nil
    } catch ReconciliationStatusError.noActiveGeneration {
      context.wallpaperIntentionallyUnmanaged = false
    } catch {
      context.appearanceInspectionOverride = appearanceFailure(error)
      context.wallpaperInspectionOverride = AdapterInspection(
        .wallpaper,
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
    adapterIDs: [String],
    excludingAdapterIDs: Set<String> = []
  ) async throws -> (manifest: GenerationManifest, record: ReconciliationRecord) {
    try validateSelection(adapterIDs)
    let manifest = try themeGenerations.activeManifest()
    let adapters = configuredAdapters(
      context: AdapterResolutionContext(
        desiredWallpaperURL: Self.activeWallpaperURL(manifest: manifest, root: root),
        unsupportedAdapterIDs: try unsupportedNamedThemeAdapterIDs(manifest: manifest)
      )
    )
    // Aggregate lifecycle owners may already hold a non-reentrant runtime lock.
    // Exclusions must also constrain missing/stale-status expansion, not just selection.
    let eligible = adapters.filter { !excludingAdapterIDs.contains($0.id) }
    let selected = selectedAdapters(adapterIDs, from: eligible)
    let plan = try reconciliationPlan(
      selected: selected,
      all: eligible,
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
      guard enabledAdapterIDs.contains(adapterID) else {
        throw AdapterSelectionError.disabled(adapterID)
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
      return (
        selected,
        record.results.filter { enabledAdapterIDs.contains($0.adapterID) }
      )
    case .missing, .stale:
      return (adapters, [])
    }
  }

  private func configuredAdapters(context: AdapterResolutionContext) -> [ConfiguredAdapter] {
    ConsumerCatalog.shared.runtimeEntries.filter { entry in
      enabledAdapterIDs.contains(entry.id.rawValue)
    }.map { entry -> ConfiguredAdapter in
      // The initializer builds the table from `RuntimeAdapterKind.allCases`.
      let consumer = runtimeConsumers[entry.mode.runtimeKind!]!
      if entry.supportsNamedThemeFallback,
        context.unsupportedAdapterIDs.contains(entry.id.rawValue)
      {
        return unsupportedNamedThemeAdapter(entry, preflight: consumer.preflight)
      }
      return ConfiguredAdapter(
        entry: entry,
        preflight: consumer.preflight,
        inspection: { consumer.inspection(context) },
        reconciliation: consumer.reconciliation,
        repaint: consumer.repaint
      )
    }
  }

  private static func activeAppearance(
    manifest: GenerationManifest,
    root: URL
  ) throws -> ThemeAppearance {
    try manifest.normalizedTheme(root: root).appearance
  }

  private func prepare(
    package: ThemePackage,
    requestedBackgroundID: String?,
    recoverActivePreference: Bool
  ) throws -> PreparedThemeBackground {
    let background = try resolveBackground(
      package: package,
      requestedBackgroundID: requestedBackgroundID,
      recoverActivePreference: recoverActivePreference
    )
    let preflightContext = AdapterPreflightContext(
      package: package,
      hasSelectedWallpaper: background.selection != nil
    )
    for adapter in configuredAdapters(context: AdapterResolutionContext()) {
      do {
        try adapter.preflight(preflightContext)
      } catch CanonicalThemeLinkError.absent(_) {
        // Adapters report this only after every other check passed. An unpublished link
        // cannot break on the pointer swap, unlike a file in its place; reconciliation
        // still reports the adapter as drifted.
        continue
      }
    }
    return background
  }

  private func resolveBackground(
    package: ThemePackage,
    requestedBackgroundID: String?,
    recoverActivePreference: Bool,
    persistsRecoveredPreference: Bool = true
  ) throws -> PreparedThemeBackground {
    let effectivePackage = try configurationStore.addingPersonalBackgrounds(to: package)
    var preferences = try backgroundPreferences.load()
    if recoverActivePreference,
      let active = try themeGenerations.activeManifestIfPresent(),
      active.manifestSchemaVersion == GenerationManifest.currentSchemaVersion
    {
      if persistsRecoveredPreference {
        try rememberBackground(of: active, in: &preferences)
      } else {
        preferences[active.themeID] = active.background?.id
      }
    }
    return try BackgroundSelectionResolver.resolve(
      package: effectivePackage,
      requestedBackgroundID: requestedBackgroundID,
      preferences: preferences
    )
  }

  private static func activeWallpaperURL(manifest: GenerationManifest, root: URL) -> URL? {
    guard manifest.artifacts[WallpaperAdapter.outputPath] != nil else { return nil }
    return manifest.artifactURL(root: root, path: WallpaperAdapter.outputPath)
  }

  private static func wallpaperConsumer(
    _ wallpaper: WallpaperAdapter,
    signal wallpaperSignal: YabaiWallpaperSignal,
    processRunner: ProcessRunner,
    themeGenerations: ThemeGenerationReader,
    root: URL
  ) -> RuntimeConsumer {
    let photos = ScreenSaverImageStore(root: root)
    return RuntimeConsumer(
      preflight: { preflightContext in
        guard preflightContext.hasSelectedWallpaper else { return }
        _ = try wallpaper.preflight()
      },
      inspection: { context in
        if let inspection = context.wallpaperInspectionOverride {
          return inspection
        }
        return wallpaper.consumerInspection(
          photos: photos,
          signal: wallpaperSignal,
          processRunner: processRunner,
          desiredWallpaperURL: context.desiredWallpaperURL,
          intentionallyUnmanaged: context.wallpaperIntentionallyUnmanaged
            ?? ((try? themeGenerations.activeManifest()).map {
              Self.activeWallpaperURL(manifest: $0, root: root) == nil
            } ?? false),
          includeRuntimeChecks: context.includeRuntimeChecks
        )
      },
      reconciliation: {
        wallpaper.consumerReconciliation(photos: photos, signal: wallpaperSignal) {
          let manifest = try themeGenerations.activeManifest()
          return Self.activeWallpaperURL(manifest: manifest, root: root)
        }
      }
    )
  }

  /// Records the manifest's background choice, persisting only when it changed.
  private func rememberBackground(
    of manifest: GenerationManifest,
    in preferences: inout [String: String]
  ) throws {
    let prior = preferences
    preferences[manifest.themeID] = manifest.background?.id
    if preferences != prior {
      try backgroundPreferences.persist(preferences)
    }
  }

  private func previousReconciliationEvidence() throws -> PreviousReconciliationEvidence? {
    guard let manifest = try themeGenerations.activeManifestIfPresent() else { return nil }
    let record: ReconciliationRecord? =
      if case .current(let record)? = try? statusStore.reconciliationState(for: manifest) {
        record
      } else {
        nil
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
      isCompleteReconciliation(record, adapters: adapters)
    else { return (adapters, []) }

    let enabledIDs = Set(adapters.map(\.id))
    let enabledResults = record.results.filter { enabledIDs.contains($0.adapterID) }

    if previousEvidence.manifest.generationID == manifest.generationID {
      return (
        adapters.filter { $0.id == WallpaperAdapter.id },
        enabledResults.filter { $0.adapterID != WallpaperAdapter.id }
      )
    }

    let carried = enabledResults.filter { $0.adapterID != WallpaperAdapter.id }.map { result in
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

  private func isCompleteReconciliation(
    _ record: ReconciliationRecord,
    adapters: [ConfiguredAdapter]
  ) -> Bool {
    let requirements = Dictionary(
      uniqueKeysWithValues: adapters.map { ($0.id, $0.entry.mode.requirement!) }
    )
    let enabledResults = record.results.filter { requirements[$0.adapterID] != nil }
    guard Set(enabledResults.map(\.adapterID)) == Set(requirements.keys) else {
      return false
    }
    return enabledResults.allSatisfy { result in
      requirements[result.adapterID] == result.requirement
    }
  }

  private func unsupportedNamedThemeAdapterIDs(
    manifest: GenerationManifest
  ) throws -> Set<String> {
    guard manifest.artifacts[ThemeRenderer.capabilitiesOutputPath] != nil else {
      return []
    }
    let url = manifest.artifactURL(root: root, path: ThemeRenderer.capabilitiesOutputPath)
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

  private func unsupportedNamedThemeAdapter(
    _ entry: ConsumerCatalogEntry,
    preflight: @escaping @Sendable (AdapterPreflightContext) throws -> Void
  ) -> ConfiguredAdapter {
    let kind = entry.mode.runtimeKind!
    let message =
      "The active theme has no safe \(entry.id.rawValue) named-theme mapping; its prior appearance is retained"
    return ConfiguredAdapter(
      entry: entry,
      preflight: preflight,
      inspection: { AdapterInspection(kind, status: .unsupported, message: message) },
      reconciliation: {
        AdapterReconciliation(kind) { AdapterOutcome(status: .unsupported, message: message) }
      }
    )
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

/// Adapters whose wiring needs neither the preflight package nor resolution context.
private protocol ContextFreeThemeAdapter: Sendable {
  func preflight() throws
  func inspection() -> AdapterInspection
  func reconciliation() -> AdapterReconciliation
}

extension AtuinAdapter: ContextFreeThemeAdapter {}
extension BatAdapter: ContextFreeThemeAdapter {}
extension BtopAdapter: ContextFreeThemeAdapter {}
extension BordersAdapter: ContextFreeThemeAdapter {}
extension EzaAdapter: ContextFreeThemeAdapter {}
extension KittyAdapter: ContextFreeThemeAdapter {}
extension SpicetifyAdapter: ContextFreeThemeAdapter {}
extension StarshipAdapter: ContextFreeThemeAdapter {}
extension TuicrAdapter: ContextFreeThemeAdapter {}
extension YaziAdapter: ContextFreeThemeAdapter {}

/// One runtime consumer's adapter, built once per coordinator.
private struct RuntimeConsumer: Sendable {
  let preflight: @Sendable (AdapterPreflightContext) throws -> Void
  let inspection: @Sendable (AdapterResolutionContext) -> AdapterInspection
  let reconciliation: @Sendable () -> AdapterReconciliation
  /// The repaint boundary for the adapter's current ownership; nil for its kind's usual one.
  var repaint: @Sendable () -> ThemeRepaintBoundary? = { nil }
}

extension RuntimeConsumer {
  init(_ adapter: some ContextFreeThemeAdapter) {
    self.init(
      preflight: { _ in try adapter.preflight() },
      inspection: { _ in adapter.inspection() },
      reconciliation: { adapter.reconciliation() }
    )
  }
}

private struct ConfiguredAdapter: Sendable {
  let entry: ConsumerCatalogEntry
  private let runPreflight: @Sendable (AdapterPreflightContext) throws -> Void
  private let inspect: @Sendable () -> AdapterInspection
  private let reconcile: @Sendable () -> AdapterReconciliation
  /// The repaint boundary for the adapter's current ownership; nil for its kind's usual one.
  let repaint: @Sendable () -> ThemeRepaintBoundary?

  init(
    entry: ConsumerCatalogEntry,
    preflight: @escaping @Sendable (AdapterPreflightContext) throws -> Void,
    inspection: @escaping @Sendable () -> AdapterInspection,
    reconciliation: @escaping @Sendable () -> AdapterReconciliation,
    repaint: @escaping @Sendable () -> ThemeRepaintBoundary? = { nil }
  ) {
    self.entry = entry
    runPreflight = preflight
    inspect = inspection
    reconcile = reconciliation
    self.repaint = repaint
  }

  var id: String { entry.id.rawValue }

  func preflight(_ context: AdapterPreflightContext) throws {
    try runPreflight(context)
  }

  // Adapters take their requirement from the catalog entry for the kind they name, so only
  // the kind itself can disagree with the entry this adapter is wired to.
  func inspection() -> AdapterInspection {
    let inspection = inspect()
    precondition(
      inspection.adapterID == id,
      "Runtime inspection disagrees with the consumer catalog for '\(id)'"
    )
    return inspection
  }

  func reconciliation() -> AdapterReconciliation {
    let reconciliation = reconcile()
    precondition(
      reconciliation.id == id,
      "Runtime reconciliation disagrees with the consumer catalog for '\(id)'"
    )
    return reconciliation
  }
}
