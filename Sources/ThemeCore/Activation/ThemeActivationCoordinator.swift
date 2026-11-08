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
      for: Bundle.main.executableURL
        ?? URL(filePath: CommandLine.arguments.first ?? "macarchy")
    )
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
    spotifyVersionProvider: @escaping @Sendable () throws -> String = { "1.2.97" }
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
    self.enabledAdapterIDs =
      enabledAdapterIDs
      ?? Set(Self.adapterRequirements.keys).subtracting([BordersAdapter.id, BordersAdapter.leanID])
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
            includeDirective: Self.kittyIncludeDirective(root: root),
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
          reconciliation: pi.reconciliation
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
            spotifyVersionProvider: spotifyVersionProvider
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

  /// `onCommittedLocked` runs under the activation lock right after the pointer swap.
  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String? = nil,
    requestedBackgroundID: String? = nil,
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
        reconciliation: consumer.reconciliation
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
    let configuration = try configurationStore.load()
    let effectivePackage = try package.addingPersonalBackgrounds(
      configuration.personalBackgrounds(themeID: package.id)
    )
    var preferences = try backgroundPreferences.load()
    if recoverActivePreference,
      let active = try themeGenerations.activeManifestIfPresent(),
      active.manifestSchemaVersion == GenerationManifest.currentSchemaVersion
    {
      try rememberBackground(of: active, in: &preferences)
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
    RuntimeConsumer(
      preflight: { preflightContext in
        guard preflightContext.hasSelectedWallpaper else { return }
        _ = try wallpaper.preflight()
      },
      inspection: { context in
        if let inspection = context.wallpaperInspectionOverride {
          return inspection
        }
        return Self.inspectWallpaper(
          wallpaper,
          signal: wallpaperSignal,
          processRunner: processRunner,
          root: root,
          desiredWallpaperURL: context.desiredWallpaperURL,
          intentionallyUnmanaged: context.wallpaperIntentionallyUnmanaged
            ?? ((try? themeGenerations.activeManifest()).map {
              Self.activeWallpaperURL(manifest: $0, root: root) == nil
            } ?? false),
          includeRuntimeChecks: context.includeRuntimeChecks
        )
      },
      reconciliation: {
        AdapterReconciliation(.wallpaper) {
          let wallpaperOutcome = try await wallpaper.reconciliation {
            let manifest = try themeGenerations.activeManifest()
            return Self.activeWallpaperURL(manifest: manifest, root: root)
          }.run()
          // The Photos folder is a projection of this same wallpaper consumer,
          // not another environment role or a native screensaver settings owner.
          // Prepare it only after the native desktop repaint path has finished.
          var messages = [wallpaperOutcome.message].compactMap { $0 }
          do {
            messages.append(try ScreenSaverImageStore(root: root).reconcile())
          } catch {
            messages.append("Photos source failed: \(error)")
            return AdapterOutcome(
              status: .failed,
              message: "Desktop wallpaper: \(wallpaperOutcome.status.rawValue); "
                + messages.joined(separator: "; ")
            )
          }
          guard wallpaperOutcome.status == .applied else {
            return AdapterOutcome(
              status: wallpaperOutcome.status, message: messages.joined(separator: "; "))
          }
          do {
            try wallpaperSignal.preflight()
            return AdapterOutcome(status: .applied, message: messages.joined(separator: "; "))
          } catch {
            let status: AdapterStatus = Self.isSignalDrift(error) ? .drifted : .failed
            messages.append(String(describing: error))
            return AdapterOutcome(status: status, message: messages.joined(separator: "; "))
          }
        }
      }
    )
  }

  private static func inspectWallpaper(
    _ wallpaper: WallpaperAdapter,
    signal wallpaperSignal: YabaiWallpaperSignal,
    processRunner: ProcessRunner,
    root: URL,
    desiredWallpaperURL: URL?,
    intentionallyUnmanaged: Bool,
    includeRuntimeChecks: Bool
  ) -> AdapterInspection {
    guard !intentionallyUnmanaged else {
      return AdapterInspection(
        .wallpaper,
        message:
          "The active theme has no backgrounds; desktop wallpaper and the Photos source retain their previous images"
      )
    }
    let desktopInspection = wallpaper.inspection(
      desiredWallpaperURL: desiredWallpaperURL
    )
    let photosInspection = ScreenSaverImageStore(root: root).inspection()
    let wallpaperInspection = AdapterInspection(
      .wallpaper,
      status: Self.mostSevere(desktopInspection.status, photosInspection.status),
      message: [desktopInspection.message, photosInspection.message].compactMap { $0 }.joined(
        separator: "; ")
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
        .wallpaper,
        status: wallpaperInspection.status,
        message: messages.joined(separator: "; ")
      )
    } catch {
      return AdapterInspection(
        .wallpaper,
        status: Self.mostSevere(
          wallpaperInspection.status, Self.isSignalDrift(error) ? .drifted : .failed),
        message: [wallpaperInspection.message, String(describing: error)]
          .compactMap { $0 }
          .joined(separator: "; ")
      )
    }
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

  /// A missing directive or unloaded signal is repairable drift, not a failure.
  private static func isSignalDrift(_ error: any Error) -> Bool {
    switch error {
    case YabaiWallpaperSignalError.missingDirective, YabaiWallpaperSignalError.runtimeSignalMissing:
      true
    default:
      false
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
