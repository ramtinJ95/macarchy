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
      #expect(published)
      if request.executableURL == URL(filePath: "/usr/bin/osascript") {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      if request.executableURL == BatAdapter.liveExecutableURL
        || request.executableURL == EzaAdapter.liveExecutableURL
      {
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
        return ProcessResult(terminationStatus: 0, output: "")
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
            requirement: .optional,
            status: .applied,
            message: "Spotify will use the active palette on next launch"
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
            status: .applied
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

  @Test
  func requiredAdapterPreflightFailuresPreserveThePreviousGeneration() async throws {
    for adapterID in ["bat", "eza", "kitty", "sketchybar"] {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
      let kittyConfiguration = root.appending(path: "kitty.conf")
      try "include \(root.path)/state/adapters/kitty.conf\n".write(
        to: kittyConfiguration,
        atomically: true,
        encoding: .utf8
      )
      let sketchyBarConfiguration = try Self.sketchyBarConfiguration(root: root)
      let consumerPaths = try Self.consumerPaths(
        root: root,
        kittyConfigurationURL: kittyConfiguration,
        sketchyBarConfigurationURL: sketchyBarConfiguration
      )
      if adapterID == "bat" {
        try "--theme=\"other\"\n".write(
          to: consumerPaths.batConfigurationDirectoryURL.appending(path: "config"),
          atomically: true,
          encoding: .utf8
        )
      } else if adapterID == "eza" {
        try "export EZA_CONFIG_DIR=\"other\"\n".write(
          to: consumerPaths.shellConfigurationURL,
          atomically: true,
          encoding: .utf8
        )
      } else if adapterID == "kitty" {
        try "include bindings.conf\n".write(
          to: kittyConfiguration,
          atomically: true,
          encoding: .utf8
        )
      } else {
        try "-- missing init import\n".write(
          to: sketchyBarConfiguration,
          atomically: true,
          encoding: .utf8
        )
      }
      let calls = Mutex(0)
      let coordinator = ThemeActivationCoordinator(
        root: root,
        consumerPaths: consumerPaths,
        processRunner: ProcessRunner { _ in
          calls.withLock { $0 += 1 }
          return ProcessResult(terminationStatus: 0, output: "")
        },
        wallpaperControl: Self.wallpaperControl(),
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        onThemeChanged: { _ in calls.withLock { $0 += 1 } }
      )

      do {
        _ = try await coordinator.activate(package: catppuccinPackage())
        Issue.record("Expected \(adapterID) preflight to fail")
      } catch is BatAdapterError {
        #expect(adapterID == "bat")
      } catch is EzaAdapterError {
        #expect(adapterID == "eza")
      } catch is KittyAdapterError {
        #expect(adapterID == "kitty")
      } catch is SketchyBarAdapterError {
        #expect(adapterID == "sketchybar")
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
  func cancellationBeforeActivationDoesNotCommit() async throws {
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
      processRunner: ProcessRunner { _ in
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

    await #expect(throws: AdapterSelectionError.unknown("tmux")) {
      _ = try await coordinator.reconcile(adapterIDs: ["tmux"])
    }
    await #expect(throws: AdapterSelectionError.duplicate("kitty")) {
      _ = try await coordinator.reconcile(adapterIDs: ["kitty", "kitty"])
    }

    #expect(processCalls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state").path))
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
        root: root,
        kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
      ),
      processRunner: ProcessRunner { request in
        processCalls.withLock { $0 += 1 }
        if request.executableURL == HerdrAdapter.liveExecutableURL {
          return ProcessResult(terminationStatus: 0, output: "")
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
      wallpaperSignal: try Self.wallpaperSignal(root: root)
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
    #expect(processCalls.withLock { $0 } == 2)
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
