import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func activationPublishesBeforeAdapterProcessesAndPersistsTheirResults() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let includeDirective = "include \(root.path)/state/adapters/kitty.conf"
    let configurationURL = root.appending(path: "kitty.conf")
    try "\(includeDirective)\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let state = Mutex(
      (
        typedPublished: false,
        darwinPublished: false,
        appearance: ThemeAppearance.light,
        requests: [ProcessRequest]()
      )
    )
    let runner = ProcessRunner { request in
      let published = state.withLock { state in
        state.requests.append(request)
        if request.executableURL == URL(filePath: "/usr/bin/osascript") {
          state.appearance = .dark
        }
        return state.typedPublished && state.darwinPublished
      }
      if request.executableURL != PiAdapter.liveExecutableURL
        && request.executableURL != CodexAdapter.liveExecutableURL
        && request.executableURL != HerdrAdapter.liveExecutableURL
        || request.arguments != ["--version"]
      {
        #expect(published)
      }
      if request.executableURL == URL(filePath: "/usr/bin/osascript") {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      if request.executableURL == BatAdapter.liveExecutableURL {
        return ProcessResult(terminationStatus: 0, output: BatAdapter.themeName)
      }
      if request.executableURL == EzaAdapter.liveExecutableURL {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      if request.executableURL == AtuinAdapter.liveExecutableURL {
        return ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
      }
      if request.executableURL == NeovimAdapter.liveExecutableURL {
        let active = try ReconciliationStatusStore(root: root).activeManifest()
        return ProcessResult(
          terminationStatus: 0,
          output: "MACARCHY_THEME=\(active.generationID):\(active.themeID)"
        )
      }
      if request.executableURL == StarshipAdapter.liveExecutableURL {
        return ProcessResult(
          terminationStatus: 0,
          output: "palette = \"\(StarshipAdapter.paletteName)\""
        )
      }
      if request.executableURL == HerdrAdapter.liveExecutableURL {
        return request.arguments == ["--version"]
          ? ProcessResult(terminationStatus: 0, output: "herdr 0.8.2")
          : ProcessResult(
            terminationStatus: 0,
            output: herdrReloadSuccess
          )
      }
      if request.executableURL == PiAdapter.liveExecutableURL,
        request.arguments == ["--version"]
      {
        return ProcessResult(terminationStatus: 0, output: PiAdapter.minimumVersion)
      }
      if request.executableURL == CodexAdapter.liveExecutableURL,
        request.arguments == ["--version"]
      {
        return ProcessResult(
          terminationStatus: 0,
          output: "codex-cli \(CodexAdapter.minimumVersion)"
        )
      }
      if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
        return ProcessResult(terminationStatus: 1, output: "")
      }
      if request.executableURL == SpicetifyAdapter.liveExecutableURL {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      if request.arguments == ["-0", "kitty"] {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 1, output: "reload denied")
    }
    let store = ReconciliationStatusStore(root: root)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: runner,
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      currentAppearance: { state.withLock { $0.appearance } },
      onThemeChanged: { _ in state.withLock { $0.typedPublished = true } },
      postDarwinNotification: { _ in state.withLock { $0.darwinPublished = true } }
    )

    let activation = try await coordinator.activate(package: catppuccinPackage())
    let generatedKitty = try Data(
      contentsOf: root.appending(
        path: "generations/\(activation.manifest.generationID)/generated/kitty.conf"
      )
    )
    let kittyBridge = root.appending(path: KittyAdapter.bridgePath)
    #expect(try Data(contentsOf: kittyBridge) == generatedKitty)

    let requests = state.withLock { $0.requests }
    #expect(
      requests.filter { $0.executableURL == URL(filePath: "/usr/bin/osascript") }
        == [
          Self.appearanceRequest(dark: true)
        ]
    )
    #expect(
      requests.filter { $0.executableURL == SketchyBarAdapter.liveExecutableURL }
        == [
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: [
              "--reload",
              root.appending(path: "sketchybar/sketchybarrc").path,
            ],
            timeout: 2
          )
        ]
    )
    #expect(
      activation.reconciliation.results
        == [
          AdapterResult(
            adapterID: "atuin",
            requirement: .required,
            status: .applied,
            message: "Fresh Atuin search interfaces use the active palette"
          ),
          AdapterResult(
            adapterID: "bat",
            requirement: .required,
            status: .applied,
            message: "bat rebuilt its cache for the active palette"
          ),
          AdapterResult(
            adapterID: "btop",
            requirement: .required,
            status: .applied,
            message: "btop will use the active palette on next launch"
          ),
          AdapterResult(
            adapterID: "codex",
            requirement: .required,
            status: .restartRequired,
            message: "Restart Codex TUI sessions to use the active syntax palette"
          ),
          AdapterResult(
            adapterID: "eza",
            requirement: .required,
            status: .applied,
            message: "Fresh eza invocations use the active palette"
          ),
          AdapterResult(
            adapterID: "herdr",
            requirement: .required,
            status: .applied,
            message: "Herdr reloaded the active theme"
          ),
          AdapterResult(
            adapterID: "kitty",
            requirement: .required,
            status: .failed,
            message: "reload denied"
          ),
          AdapterResult(
            adapterID: "macos-appearance",
            requirement: .required,
            status: .applied
          ),
          AdapterResult(
            adapterID: "neovim",
            requirement: .required,
            status: .applied,
            message:
              "Neovim validated the active colorscheme; running sessions repaint through the pointer watcher"
          ),
          AdapterResult(
            adapterID: "pi",
            requirement: .required,
            status: .applied,
            message: "Running Pi sessions reloaded the active palette"
          ),
          AdapterResult(
            adapterID: "sketchybar",
            requirement: .required,
            status: .failed,
            message: "reload denied"
          ),
          AdapterResult(
            adapterID: "spicetify",
            requirement: .required,
            status: .applied,
            message: "Spicetify refreshed the palette; closed Spotify will use it on next launch"
          ),
          AdapterResult(
            adapterID: "starship",
            requirement: .required,
            status: .applied,
            message: "Starship prompts use the active palette"
          ),
          AdapterResult(
            adapterID: "tuicr",
            requirement: .required,
            status: .restartRequired,
            message: "Restart tuicr to use the active palette"
          ),
          AdapterResult(
            adapterID: "wallpaper",
            requirement: .required,
            status: .applied,
            message: ScreenSaverImageStore(root: root).inspection().message
          ),
          AdapterResult(
            adapterID: "yazi",
            requirement: .required,
            status: .applied,
            message: "Yazi will use the active palette on next launch"
          ),
        ]
    )
    #expect(try store.read() == .current(activation.reconciliation))

    let retryRequests = Mutex([ProcessRequest]())
    let retryKitty = KittyAdapter(
      root: root,
      configurationURL: configurationURL,
      includeDirective: includeDirective,
      processRunner: ProcessRunner { request in
        retryRequests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      }
    )
    try Data("stale bridge\n".utf8).write(to: kittyBridge, options: .atomic)
    #expect(retryKitty.inspection().status == .drifted)
    let recovered = try await ThemeReconciler(statusStore: store).reconcile(
      manifest: activation.manifest,
      adapters: [retryKitty.reconciliation()]
    )
    #expect(
      recovered.results
        == [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )
    #expect(
      retryRequests.withLock { $0 }.map(\.arguments)
        == [["-USR1", "kitty"], ["-0", "kitty"]]
    )
    #expect(retryKitty.inspection().status == .ready)
    #expect(try store.read() == .current(recovered))
  }

  @Test(arguments: PreflightFailure.allCases)
  func requiredAdapterPreflightFailurePreservesThePreviousGeneration(
    _ failure: PreflightFailure
  ) async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
      let calls = Mutex(0)
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: try failure.consumerPaths(root: root),
        processRunner: ProcessRunner { _ in
          calls.withLock { $0 += 1 }
          return ProcessResult(terminationStatus: 0, output: "")
        },
        wallpaperControl: failure == .wallpaper
          ? WallpaperControl(inspect: { [] }, set: { _, _ in }) : Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        appearanceControlIsAvailable: { failure != .macOSAppearance },
        onThemeChanged: { _ in calls.withLock { $0 += 1 } },
        enabledAdapterIDs: failure.enabledAdapterIDs
      )

      do {
        _ = try await coordinator.activate(package: catppuccinPackage())
        Issue.record("Expected \(failure) preflight to fail")
      } catch {
        #expect(failure.isExpected(error), "unexpected error: \(error)")
      }

      #expect(calls.withLock { $0 } == 0)
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appending(path: "current").path
        ) == "generations/\(previous.generationID)"
      )
    }
  }

  @Test
  func disabledConsumersWithMissingOrInvalidConfigurationDoNotBlockActivation() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let consumerPaths = try Self.consumerPaths(root: root, adapterIDs: [KittyAdapter.id])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == ["kitty.conf"]
    )
    let disabledConfiguration = consumerPaths.batConfigurationDirectoryURL.appending(path: "config")
    try FileManager.default.createDirectory(
      at: consumerPaths.batConfigurationDirectoryURL, withIntermediateDirectories: true)
    let invalidBytes = Data("--theme=\"other\"\n".utf8)
    try invalidBytes.write(to: disabledConfiguration)
    let requests = Mutex([ProcessRequest]())
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      enabledAdapterIDs: [KittyAdapter.id]
    )

    let activation = try await coordinator.activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)

    let active = try store.activeManifest()
    #expect(active.generationID == activation.manifest.generationID)
    #expect(active.themeID == activation.manifest.themeID)
    #expect(
      activation.reconciliation.results
        == [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )
    #expect(try store.read() == .current(activation.reconciliation))
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-USR1", "kitty"]),
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-0", "kitty"]),
        ]
    )
    #expect(try Data(contentsOf: disabledConfiguration) == invalidBytes)
    #expect(try coordinator.inspectAdapters([]).map(\.adapterID) == [KittyAdapter.id])
  }

  @Test(arguments: ["absent", "regular_file"])
  func onlyAnAbsentCanonicalLinkLetsActivationCommitAsDrift(linkState: String) async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
      let consumerPaths = try Self.consumerPaths(root: root, adapterIDs: [AtuinAdapter.id])
      let link = consumerPaths.atuinConfigurationDirectoryURL.appending(
        path: "themes/\(AtuinAdapter.themeName).toml")
      try FileManager.default.removeItem(at: link)
      if linkState == "regular_file" {
        try "[colors]\n".write(to: link, atomically: true, encoding: .utf8)
      }
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: consumerPaths,
        processRunner: ProcessRunner { _ in
          ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
        },
        wallpaperControl: Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        enabledAdapterIDs: [AtuinAdapter.id]
      )
      let current = {
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appending(path: "current").path)
      }

      if linkState == "absent" {
        let activation = try await coordinator.activate(package: catppuccinPackage())
        #expect(try current() == "generations/\(activation.manifest.generationID)")
        #expect(activation.manifest.generationID != previous.generationID)
        #expect(activation.reconciliation.results.map(\.adapterID) == [AtuinAdapter.id])
        #expect(activation.reconciliation.results.first?.status == .drifted)
        #expect(!FileManager.default.fileExists(atPath: link.path))
      } else {
        do {
          _ = try await coordinator.activate(package: catppuccinPackage())
          Issue.record("A regular file at the theme link must block activation")
        } catch CanonicalThemeLinkError.notSymbolicLink(_) {}
        #expect(try current() == "generations/\(previous.generationID)")
        #expect(try String(contentsOf: link, encoding: .utf8) == "[colors]\n")
      }
    }
  }

  @Test(arguments: ["regular_file_link", "missing_selection"])
  func anAbsentCanonicalLinkDoesNotSkipLaterBlockingChecks(laterFailure: String) async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
      let consumerPaths = try Self.consumerPaths(root: root, adapterIDs: [YaziAdapter.id])
      let flavor = consumerPaths.yaziConfigurationDirectoryURL.appending(
        path: "flavors/\(YaziAdapter.flavorName).yazi", directoryHint: .isDirectory)
      try FileManager.default.removeItem(at: flavor.appending(path: "flavor.toml"))
      if laterFailure == "regular_file_link" {
        let syntax = flavor.appending(path: "tmtheme.xml")
        try FileManager.default.removeItem(at: syntax)
        try "<plist/>\n".write(to: syntax, atomically: true, encoding: .utf8)
      } else {
        try "[flavor]\n".write(
          to: consumerPaths.yaziConfigurationDirectoryURL.appending(path: "theme.toml"),
          atomically: true, encoding: .utf8)
      }
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: consumerPaths,
        processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") },
        wallpaperControl: Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        enabledAdapterIDs: [YaziAdapter.id]
      )

      do {
        _ = try await coordinator.activate(package: catppuccinPackage())
        Issue.record("An absent first link must not let activation skip a later failure")
      } catch CanonicalThemeLinkError.notSymbolicLink(_) where laterFailure == "regular_file_link" {
      } catch YaziAdapterError.missingFlavorSelection(_) where laterFailure == "missing_selection" {
      }
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appending(path: "current").path) == "generations/\(previous.generationID)")
    }
  }

  @Test
  func cancellationBeforeActivationDoesNotCommit() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let configurationURL = root.appending(path: "kitty.conf")
      try "include \(root.path)/state/adapters/kitty.conf\n".write(
        to: configurationURL,
        atomically: true,
        encoding: .utf8
      )
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: try Self.consumerPaths(
          root: root, kittyConfigurationURL: configurationURL,
          sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
        processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") },
        wallpaperControl: Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root)
      )

      let activation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await coordinator.activate(package: catppuccinPackage())
      }
      await #expect(throws: CancellationError.self) {
        _ = try await activation.value
      }
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: "current").path))
    }
  }

  @Test
  func supersedingActivationReturnsTheCommittedManifestWithPostcommitFailure() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/state/adapters/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let tokyoNight = try tokyoNightPackage()
    let supersedingManifest = Mutex<GenerationManifest?>(nil)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { request in
        if request.executableURL == CodexAdapter.liveExecutableURL,
          request.arguments == ["--version"]
        {
          return ProcessResult(
            terminationStatus: 0,
            output: "codex-cli \(CodexAdapter.minimumVersion)"
          )
        }
        if request.executableURL == PiAdapter.liveExecutableURL,
          request.arguments == ["--version"]
        {
          return ProcessResult(terminationStatus: 0, output: PiAdapter.minimumVersion)
        }
        if request.executableURL == HerdrAdapter.liveExecutableURL,
          request.arguments == ["--version"]
        {
          return ProcessResult(
            terminationStatus: 0,
            output: "herdr \(HerdrAdapter.minimumVersion)"
          )
        }
        let manifest = try ThemeActivator(root: root, faultInjector: { _ in }).activate(
          package: tokyoNight
        )
        supersedingManifest.withLock { $0 = manifest }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    let error: ThemeCommittedWithReconciliationError
    do {
      _ = try await coordinator.activate(package: catppuccinPackage())
      throw ReconciliationTestError.expectedCommittedError
    } catch let committed as ThemeCommittedWithReconciliationError {
      error = committed
    }

    let active = try #require(supersedingManifest.withLock { $0 })
    #expect(error.manifest.themeID == "catppuccin-mocha")
    #expect(
      try ReconciliationStatusStore(root: root).read()
        == .missing(activeGenerationID: active.generationID)
    )
  }

  @Test
  func selectedReconciliationRejectsInvalidIDsBeforeProcessesOrStatusWrites() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let configurationURL = root.appending(path: "kitty.conf")
      try "include \(root.path)/state/adapters/kitty.conf\n".write(
        to: configurationURL,
        atomically: true,
        encoding: .utf8
      )
      let processCalls = Mutex(0)
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: try Self.consumerPaths(
          root: root, kittyConfigurationURL: configurationURL,
          sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
        processRunner: ProcessRunner { _ in
          processCalls.withLock { $0 += 1 }
          return ProcessResult(terminationStatus: 0, output: "")
        },
        wallpaperControl: Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        enabledAdapterIDs: Set(ThemeActivationCoordinator.adapterRequirements.keys)
          .subtracting([BordersAdapter.id, BordersAdapter.leanID, TuicrAdapter.id])
      )

      await #expect(throws: AdapterSelectionError.unknown("tmux")) {
        _ = try await coordinator.reconcile(adapterIDs: ["tmux"])
      }
      await #expect(throws: AdapterSelectionError.duplicate("kitty")) {
        _ = try await coordinator.reconcile(adapterIDs: ["kitty", "kitty"])
      }
      await #expect(throws: AdapterSelectionError.disabled(TuicrAdapter.id)) {
        _ = try await coordinator.reconcile(adapterIDs: [TuicrAdapter.id])
      }

      #expect(processCalls.withLock { $0 } == 0)
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state").path))
    }
  }

  @Test
  func importedHerdrAndNeovimPalettesReconcileAsRequiredAdapters() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = packageWithoutNamedThemeMappings(try catppuccinPackage())
    let manifest = try testActivator(root: root).activate(package: package)
    let store = ReconciliationStatusStore(root: root)
    _ = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)
      ]
    )
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root,
        adapterIDs: [HerdrAdapter.id, KittyAdapter.id, NeovimAdapter.id]
      ),
      processRunner: ProcessRunner { request in
        if request.executableURL == HerdrAdapter.liveExecutableURL {
          return request.arguments == ["--version"]
            ? ProcessResult(terminationStatus: 0, output: "herdr 0.8.2")
            : ProcessResult(
              terminationStatus: 0,
              output: herdrReloadSuccess
            )
        }
        if request.executableURL == NeovimAdapter.liveExecutableURL {
          return ProcessResult(
            terminationStatus: 0,
            output: "MACARCHY_THEME=\(manifest.generationID):\(manifest.themeID)"
          )
        }
        return ProcessResult(terminationStatus: 1, output: "unexpected process")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      enabledAdapterIDs: [HerdrAdapter.id, KittyAdapter.id, NeovimAdapter.id]
    )

    try coordinator.preflight(package: package)
    let inspections = try coordinator.inspectAdapters(["herdr", "neovim"])
    let reconciliation = try await coordinator.reconcile(adapterIDs: ["herdr", "neovim"])

    #expect(inspections.map(\.status) == [.drifted, .ready])
    #expect(
      reconciliation.record.results
        == [
          AdapterResult(
            adapterID: "herdr",
            requirement: .required,
            status: .applied,
            message: "Herdr reloaded the active theme"
          ),
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
          AdapterResult(
            adapterID: "neovim",
            requirement: .required,
            status: .applied,
            message:
              "Neovim validated the active colorscheme; running sessions repaint through the pointer watcher"
          ),
        ]
    )
    #expect(
      try coordinator.inspectAdapters(["herdr", "neovim"]).map(\.status) == [.ready, .ready]
    )
  }

  @Test
  func reconcileDryRunInspectsWithoutProcessesOrStatusWrites() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include other.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let processCalls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { _ in
        processCalls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    let preview = try coordinator.previewReconciliation([])

    #expect(preview.manifest.generationID == manifest.generationID)
    #expect(preview.manifest.themeID == manifest.themeID)
    #expect(
      preview.inspections.map(\.adapterID)
        == [
          "macos-appearance", "atuin", "bat", "btop", "codex", "eza", "herdr",
          "kitty", "neovim", "pi", "sketchybar", "spicetify", "starship", "tuicr",
          "wallpaper", "yazi",
        ]
    )
    let appearanceInspection = try #require(preview.inspections.first)
    let kittyInspection = try #require(
      preview.inspections.first { $0.adapterID == "kitty" }
    )
    #expect(appearanceInspection.status == .ready)
    #expect(kittyInspection.status == .drifted)
    #expect(kittyInspection.message?.contains("must contain") == true)
    #expect(processCalls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state").path))

    try FileManager.default.removeItem(at: configurationURL)
    let unreadable = try coordinator.inspectAdapters([])
    #expect(unreadable.first { $0.adapterID == "kitty" }?.status == .failed)

    try FileManager.default.removeItem(at: root.appending(path: "current"))
    try "invalid\n".write(
      to: root.appending(path: "current"),
      atomically: true,
      encoding: .utf8
    )
    let invalidCanonical = try coordinator.inspectAdapters([])
    let appearanceFailure = try #require(
      invalidCanonical.first { $0.adapterID == "macos-appearance" }
    )
    let wallpaperFailure = try #require(
      invalidCanonical.first { $0.adapterID == "wallpaper" }
    )
    #expect(appearanceFailure.status == .failed)
    #expect(appearanceFailure.message?.contains("active theme appearance") == true)
    #expect(wallpaperFailure.status == .failed)
    #expect(wallpaperFailure.message?.contains("active theme wallpaper") == true)
  }

  @Test
  func repeatedSelectedReconciliationPreservesOtherResultsAndIsIdempotent() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/state/adapters/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let statusStore = ReconciliationStatusStore(root: root)
    _ = try statusStore.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .failed),
        AdapterResult(
          adapterID: "wallpaper",
          requirement: .required,
          status: .failed,
          message: "apply failed"
        ),
      ]
    )
    let requests = Mutex([ProcessRequest]())
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    let first = try await coordinator.reconcile(adapterIDs: ["kitty"])
    let statusURL = root.appending(path: "state/reconciliation.json")
    let firstData = try Data(contentsOf: statusURL)
    let second = try await coordinator.reconcile(adapterIDs: ["kitty"])

    #expect(first.record == second.record)
    #expect(first.record.results.map(\.adapterID) == ["kitty", "wallpaper"])
    #expect(first.record.results[1].message == "apply failed")
    #expect(try Data(contentsOf: statusURL) == firstData)
    #expect(
      requests.withLock { $0 }.map(\.arguments)
        == [
          ["-USR1", "kitty"], ["-0", "kitty"],
          ["-USR1", "kitty"], ["-0", "kitty"],
        ]
    )
  }

  @Test
  func reconciliationRejectsCorruptActiveArtifactsBeforeProcessesRun() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationURL = root.appending(path: "kitty.conf")
    try "include \(root.path)/state/adapters/kitty.conf\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let artifactURL = root.appending(
      path: "generations/\(manifest.generationID)/generated/kitty.conf"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: artifactURL.path)
    try "corrupt\n".write(to: artifactURL, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: artifactURL.path)
    let processCalls = Mutex(0)
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { _ in
        processCalls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    await #expect(throws: ReconciliationStatusError.self) {
      _ = try await coordinator.reconcile(adapterIDs: [])
    }
    #expect(processCalls.withLock { $0 } == 0)
  }

}

/// A required adapter whose preflight refuses activation before anything is published.
enum PreflightFailure: String, CaseIterable, Sendable {
  case bat, eza, kitty, sketchybar
  /// Every adapter enabled while the appearance control is unavailable.
  case macOSAppearance
  /// Only wallpaper enabled while no display is reported.
  case wallpaper

  var enabledAdapterIDs: Set<String>? {
    switch self {
    case .macOSAppearance: nil
    case .wallpaper: [WallpaperAdapter.id]
    case .bat, .eza, .kitty, .sketchybar: [rawValue]
    }
  }

  func consumerPaths(root: URL) throws -> ThemeConsumerPaths {
    switch self {
    case .macOSAppearance, .wallpaper:
      let kittyConfiguration = root.appending(path: "kitty.conf")
      try "include \(root.path)/state/adapters/kitty.conf\n".write(
        to: kittyConfiguration, atomically: true, encoding: .utf8)
      return try AdapterContractTests.consumerPaths(
        root: root, kittyConfigurationURL: kittyConfiguration,
        sketchyBarConfigurationURL: try AdapterContractTests.sketchyBarConfiguration(root: root))
    case .bat, .eza, .kitty, .sketchybar:
      let paths = try AdapterContractTests.consumerPaths(root: root, adapterIDs: [rawValue])
      let (contents, url): (String, URL) =
        switch self {
        case .bat:
          ("--theme=\"other\"\n", paths.batConfigurationDirectoryURL.appending(path: "config"))
        case .eza: ("export EZA_CONFIG_DIR=\"other\"\n", paths.shellConfigurationURL)
        case .kitty: ("include bindings.conf\n", paths.kittyConfigurationURL)
        default: ("-- missing init import\n", paths.sketchyBarConfigurationURL)
        }
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return paths
    }
  }

  func isExpected(_ error: any Error) -> Bool {
    switch self {
    case .bat: error is BatAdapterError
    case .eza: error is EzaAdapterError
    case .kitty: error is KittyAdapterError
    case .sketchybar: error is SketchyBarAdapterError
    case .macOSAppearance: error is MacOSAppearanceAdapterError
    case .wallpaper: error as? WallpaperAdapterError == .noDisplays
    }
  }
}
