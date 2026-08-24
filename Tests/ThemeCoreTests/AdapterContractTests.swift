import Foundation
import Synchronization
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct AdapterContractTests {
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
            adapterID: "eza",
            requirement: .required,
            status: .applied,
            message: "Fresh eza invocations use the active palette"
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
            adapterID: "sketchybar",
            requirement: .required,
            status: .failed,
            message: "reload denied"
          ),
          AdapterResult(
            adapterID: "starship",
            requirement: .required,
            status: .applied,
            message: "Starship prompts use the active palette"
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
  func kittyRejectsInvalidBridgeFilesAndRebuildsSymlinks() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let includeDirective = "include \(root.path)/state/adapters/kitty.conf"
    let configurationURL = root.appending(path: "kitty.conf")
    try "\(includeDirective)\n".write(
      to: configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let bridgeURL = root.appending(path: KittyAdapter.bridgePath)
    try FileManager.default.createDirectory(
      at: bridgeURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let generatedURL = root.appending(
      path: "generations/\(manifest.generationID)/generated/kitty.conf"
    )
    try FileManager.default.createSymbolicLink(
      at: bridgeURL,
      withDestinationURL: generatedURL
    )
    let adapter = KittyAdapter(
      root: root,
      configurationURL: configurationURL,
      includeDirective: includeDirective,
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "no matching process")
      }
    )

    #expect(adapter.inspection().status == .failed)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let values = try bridgeURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    #expect(values.isRegularFile == true)
    #expect(values.isSymbolicLink != true)
    #expect(adapter.inspection().status == .ready)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: bridgeURL.path
    )
    #expect(adapter.inspection().status == .failed)
  }

  @Test
  func sketchyBarReloadsTheExactEntryConfigAndDetectsABrokenPaletteSeam() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let requests = Mutex([ProcessRequest]())
    let queryCount = Mutex(0)
    let settleCount = Mutex(0)
    let presentationCount = Mutex(0)
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments == ["--query", "bar"] {
          let count = queryCount.withLock { count in
            count += 1
            return count
          }
          return ProcessResult(
            terminationStatus: 0,
            output: count < 2
              ? #"{"drawing":"off","color":"0x44000000","items":[]}"#
              : #"{"drawing":"on","color":"0xf01e1e2e","items":["macarchy.theme.ready"]}"#
          )
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitForSettle: { settleCount.withLock { $0 += 1 } },
      waitForPresentation: { presentationCount.withLock { $0 += 1 } }
    )

    #expect(adapter.inspection().status == .ready)
    #expect(requests.withLock { $0 }.isEmpty)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(settleCount.withLock { $0 } == 1)
    #expect(presentationCount.withLock { $0 } == 1)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--reload", configuration.path],
            timeout: 2
          ),
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.1
          ),
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.1
          ),
        ]
    )

    try "return {}\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "colors.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(adapter.inspection().status == .drifted)
    #expect(try await adapter.reconciliation().run().status == .drifted)
    #expect(requests.withLock { $0 }.count == 3)

    try "\(SketchyBarAdapter.paletteImport(root: root))\nreturn colors\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "colors.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "-- missing ready marker\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(adapter.inspection().status == .drifted)
    #expect(try await adapter.reconciliation().run().status == .drifted)
    #expect(requests.withLock { $0 }.count == 3)
  }

  @Test
  func sketchyBarRuntimeInspectionIsExplicitAndNonMutating() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let requests = Mutex([ProcessRequest]())
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(
          terminationStatus: 0,
          output: #"{"drawing":"off","color":"0x44000000","items":[]}"#
        )
      }
    )

    #expect(adapter.inspection().status == .ready)
    #expect(requests.withLock { $0 }.isEmpty)
    #expect(adapter.inspection(includeRuntimeChecks: true).status == .drifted)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.2
          )
        ]
    )
  }

  @Test
  func sketchyBarReportsUnavailableControlAndReloadFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try Self.sketchyBarConfiguration(root: root)

    let unavailable = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { false },
      processRunner: ProcessRunner { _ in
        Issue.record("Unavailable SketchyBar control must not run")
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )
    #expect(unavailable.inspection().status == .failed)
    #expect(try await unavailable.reconciliation().run().status == .failed)

    let rejected = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "reload denied")
      }
    )
    let outcome = try await rejected.reconciliation().run()
    #expect(outcome.status == .failed)
    #expect(outcome.message == "reload denied")
  }

  @Test
  func sketchyBarStopsPollingWhenTheSettleWindowIsExhausted() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let queryCount = Mutex(0)
    let settleCount = Mutex(0)
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.arguments == ["--query", "bar"] {
          queryCount.withLock { $0 += 1 }
          return ProcessResult(
            terminationStatus: 0,
            output: #"{"drawing":"off","color":"0x44000000","items":[]}"#
          )
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitForSettle: { settleCount.withLock { $0 += 1 } },
      waitForPresentation: {
        Issue.record("Presentation wait must not run for drift")
      }
    )

    let outcome = try await adapter.reconciliation().run()

    #expect(outcome.status == .drifted)
    #expect(queryCount.withLock { $0 } == 11)
    #expect(settleCount.withLock { $0 } == 10)
  }

  @Test
  func sketchyBarEscapesCustomStateRootsInLuaImports() {
    let root = URL(filePath: "/tmp/quote\"back\\slash\nline")
    #expect(
      SketchyBarAdapter.paletteImport(root: root)
        == #"local colors = dofile("/tmp/quote\"back\\slash\nline/current/generated/sketchybar.lua")"#
    )
  }

  @Test
  func invocationBoundAdaptersUseCanonicalLinksAndExpectedProcesses() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kittyConfiguration = root.appending(path: "kitty.conf")
    try "include fixture.conf\n".write(
      to: kittyConfiguration,
      atomically: true,
      encoding: .utf8
    )
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: kittyConfiguration,
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
    let requests = Mutex([ProcessRequest]())
    let runner = ProcessRunner { request in
      requests.withLock { $0.append(request) }
      return ProcessResult(terminationStatus: 0, output: "")
    }
    let ezaExecutable = URL(filePath: "/test/eza")
    let batExecutable = URL(filePath: "/test/bat")
    let eza = EzaAdapter(
      root: root,
      configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: ezaExecutable,
      controlIsAvailable: { true },
      processRunner: runner
    )
    let bat = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: batExecutable,
      controlIsAvailable: { true },
      processRunner: runner
    )

    #expect(eza.inspection().status == .ready)
    #expect(bat.inspection().status == .ready)
    #expect(try await eza.reconciliation().run().status == .applied)
    #expect(try await bat.reconciliation().run().status == .applied)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: ezaExecutable,
            arguments: [
              "--color=always", "--oneline",
              paths.ezaConfigurationDirectoryURL.appending(path: "theme.yml").path,
            ],
            timeout: 1,
            environmentOverrides: [
              "EZA_CONFIG_DIR": paths.ezaConfigurationDirectoryURL.path
            ]
          ),
          ProcessRequest(
            executableURL: batExecutable,
            arguments: ["cache", "--build"],
            timeout: 5,
            environmentOverrides: [
              "BAT_CACHE_PATH": paths.batCacheDirectoryURL.path,
              "BAT_CONFIG_DIR": paths.batConfigurationDirectoryURL.path,
            ]
          ),
        ]
    )

    let ezaTheme = paths.ezaConfigurationDirectoryURL.appending(path: "theme.yml")
    try FileManager.default.removeItem(at: ezaTheme)
    try FileManager.default.createSymbolicLink(
      at: ezaTheme,
      withDestinationURL: root.appending(path: "wrong/eza.yml")
    )
    #expect(eza.inspection().status == .drifted)
    #expect(eza.inspection().message?.contains("must point to") == true)
  }

  @Test
  func invocationBoundAdaptersExposeUnavailableControlsAndRejectedCacheBuilds() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "kitty.conf"),
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
    let unavailable = EzaAdapter(
      root: root,
      configurationDirectoryURL: paths.ezaConfigurationDirectoryURL,
      shellConfigurationURL: paths.shellConfigurationURL,
      executableURL: URL(filePath: "/test/eza"),
      controlIsAvailable: { false },
      processRunner: ProcessRunner { _ in throw ReconciliationTestError.expectedFailure }
    )
    #expect(unavailable.inspection().status == .failed)
    #expect(unavailable.inspection().message?.contains("not executable") == true)

    let rejected = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: URL(filePath: "/test/bat"),
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 2, output: "invalid tmTheme")
      }
    )
    let outcome = try await rejected.reconciliation().run()
    #expect(outcome.status == .failed)
    #expect(outcome.message == "invalid tmTheme")
  }

  @Test
  func tuiAdaptersUseCanonicalThemesAndTheirHighestAvailableUpdateBoundaries() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "unused-kitty.conf"),
      sketchyBarConfigurationURL: root.appending(path: "unused-sketchybarrc")
    )
    let btopDirectory = paths.btopConfigurationDirectoryURL
    let yaziDirectory = paths.yaziConfigurationDirectoryURL
    let atuinDirectory = paths.atuinConfigurationDirectoryURL
    let btopLink = btopDirectory.appending(
      path: "themes/\(BtopAdapter.themeName).theme")

    let calls = Mutex([ProcessRequest]())
    let runner = ProcessRunner { request in
      calls.withLock { $0.append(request) }
      if request.executableURL == URL(filePath: "/test/atuin") {
        return ProcessResult(terminationStatus: 0, output: AtuinAdapter.themeName)
      }
      return ProcessResult(terminationStatus: 0, output: "")
    }
    let btop = BtopAdapter(
      root: root,
      configurationDirectoryURL: btopDirectory,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: runner
    )
    let yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: yaziDirectory,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: runner
    )
    let atuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: atuinDirectory,
      executableURL: URL(filePath: "/test/atuin"),
      controlIsAvailable: { true },
      processRunner: runner
    )

    #expect(try await btop.reconciliation().run().status == .applied)
    #expect(try await yazi.reconciliation().run().status == .applied)
    #expect(try await atuin.reconciliation().run().status == .applied)
    #expect(
      calls.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-USR2", "btop"]
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/killall"),
            arguments: ["-0", "yazi"]
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/test/ya"),
            arguments: ["emit-to", "0", "theme"],
            timeout: 1
          ),
          ProcessRequest(
            executableURL: URL(filePath: "/test/atuin"),
            arguments: ["config", "get", "theme.name"],
            timeout: 1,
            environmentOverrides: ["ATUIN_CONFIG_DIR": atuinDirectory.path]
          ),
        ]
    )

    try FileManager.default.removeItem(at: btopLink)
    try FileManager.default.createSymbolicLink(
      at: btopLink, withDestinationURL: root.appending(path: "wrong/btop.theme"))
    #expect(btop.inspection().status == .drifted)
    try FileManager.default.removeItem(at: btopLink)
    try FileManager.default.createSymbolicLink(
      at: btopLink,
      withDestinationURL: root.appending(path: "current/\(BtopAdapter.outputPath)"))
    try "color_theme = \"\"\(BtopAdapter.themeName)\"\"\n".write(
      to: btopDirectory.appending(path: "btop.conf"), atomically: true, encoding: .utf8)
    #expect(btop.inspection().status == .drifted)
    try "[flavor]\ndark = \"other\"\n".write(
      to: yaziDirectory.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    #expect(yazi.inspection().status == .drifted)
    try "[theme]\nname = \"other\"\n".write(
      to: atuinDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    #expect(atuin.inspection().status == .drifted)

    #expect(
      BtopAdapter(
        root: root,
        configurationDirectoryURL: btopDirectory,
        executableURL: URL(filePath: "/test/btop"),
        controlIsAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
    #expect(
      YaziAdapter(
        root: root,
        configurationDirectoryURL: yaziDirectory,
        executableURL: URL(filePath: "/test/yazi"),
        controlURL: URL(filePath: "/test/ya"),
        controlsAreAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
    #expect(
      AtuinAdapter(
        root: root,
        configurationDirectoryURL: atuinDirectory,
        executableURL: URL(filePath: "/test/atuin"),
        controlIsAvailable: { false },
        processRunner: runner
      ).inspection().status == .failed
    )
  }

  @Test
  func tuiAdaptersExposeReloadRejectionAndProcessExit() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "unused-kitty.conf"),
      sketchyBarConfigurationURL: root.appending(path: "unused-sketchybarrc")
    )
    let denied = ProcessRunner { request in
      if request.executableURL == URL(filePath: "/usr/bin/killall"),
        request.arguments.first == "-0"
      {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 1, output: "reload denied")
    }
    let deniedBtop = BtopAdapter(
      root: root,
      configurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: denied
    )
    let deniedYazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: denied
    )
    let deniedAtuin = AtuinAdapter(
      root: root,
      configurationDirectoryURL: paths.atuinConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/atuin"),
      controlIsAvailable: { true },
      processRunner: denied
    )

    let btopFailure = try await deniedBtop.reconciliation().run()
    let yaziFailure = try await deniedYazi.reconciliation().run()
    let atuinFailure = try await deniedAtuin.reconciliation().run()
    #expect(btopFailure.status == .failed)
    #expect(btopFailure.message == "reload denied")
    #expect(yaziFailure.status == .failed)
    #expect(yaziFailure.message == "reload denied")
    #expect(atuinFailure.status == .failed)
    #expect(atuinFailure.message == "reload denied")

    let yaziProbes = Mutex(0)
    let exited = ProcessRunner { request in
      if request.arguments == ["-0", "yazi"] {
        return yaziProbes.withLock { count in
          count += 1
          return ProcessResult(terminationStatus: count == 1 ? 0 : 1, output: "")
        }
      }
      return ProcessResult(terminationStatus: 1, output: "no matching process")
    }
    let exitedBtop = BtopAdapter(
      root: root,
      configurationDirectoryURL: paths.btopConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/btop"),
      controlIsAvailable: { true },
      processRunner: exited
    )
    let exitedYazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: exited
    )

    let btopExit = try await exitedBtop.reconciliation().run()
    let yaziExit = try await exitedYazi.reconciliation().run()
    #expect(btopExit.status == .applied)
    #expect(btopExit.message == "btop will use the active palette on next launch")
    #expect(yaziExit.status == .applied)
    #expect(yaziExit.message == "Yazi will use the active palette on next launch")
  }

  @Test
  func namedApplicationAdaptersPreserveBehaviorAndUpdateAtTheirBoundaries() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let neovimPlugins = neovimDirectory.appending(
      path: "lua/plugins", directoryHint: .isDirectory)
    let neovimMacarchy = neovimDirectory.appending(
      path: "lua/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: neovimPlugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimMacarchy, withIntermediateDirectories: true)
    try
      "local macarchy = require(\"config.macarchy-theme\")\n\(NeovimAdapter.integrationDirective)\n"
      .write(
        to: neovimPlugins.appending(path: "colorscheme.lua"),
        atomically: true,
        encoding: .utf8
      )
    try FileManager.default.createSymbolicLink(
      at: neovimMacarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "current/\(NeovimAdapter.outputPath)")
    )

    let starshipDirectory = root.appending(path: "starship", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: starshipDirectory, withIntermediateDirectories: true)
    let behaviorURL = starshipDirectory.appending(path: "behavior.toml")
    let behavior = "format = \"$directory$character\"\n\n[directory]\nstyle = \"blue\"\n"
    try behavior.write(to: behaviorURL, atomically: true, encoding: .utf8)
    let starshipConfigurationURL = root.appending(path: "starship.toml")
    let starshipStowSource = root.appending(path: "dotfiles/starship.toml")
    try FileManager.default.createDirectory(
      at: starshipStowSource.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: starshipStowSource,
      withDestinationURL: root.appending(path: StarshipAdapter.bridgePath)
    )
    try FileManager.default.createSymbolicLink(
      at: starshipConfigurationURL,
      withDestinationURL: starshipStowSource
    )

    let validatedStarshipConfigs = Mutex([String]())
    let runner = ProcessRunner { request in
      if request.executableURL == NeovimAdapter.liveExecutableURL {
        return ProcessResult(
          terminationStatus: 0,
          output: "MACARCHY_THEME=\(manifest.generationID):\(manifest.themeID)"
        )
      }
      validatedStarshipConfigs.withLock {
        $0.append(request.environmentOverrides["STARSHIP_CONFIG"] ?? "")
      }
      return ProcessResult(
        terminationStatus: 0,
        output: "palette = \"\(StarshipAdapter.paletteName)\""
      )
    }
    let neovim = NeovimAdapter(
      root: root,
      configurationDirectoryURL: neovimDirectory,
      executableURL: NeovimAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: runner
    )
    let starship = StarshipAdapter(
      root: root,
      configurationURL: starshipConfigurationURL,
      behaviorURL: behaviorURL,
      executableURL: StarshipAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: runner
    )

    #expect(neovim.inspection().status == .ready)
    #expect(starship.inspection().status == .drifted)
    #expect(try await neovim.reconciliation().run().status == .applied)
    #expect(try await starship.reconciliation().run().status == .applied)
    #expect(starship.inspection().status == .ready)

    let bridge = try String(
      contentsOf: root.appending(path: StarshipAdapter.bridgePath),
      encoding: .utf8
    )
    #expect(bridge.contains("palette = \"\(StarshipAdapter.paletteName)\""))
    #expect(bridge.contains(behavior.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(bridge.contains("[palettes.\(StarshipAdapter.paletteName)]"))
    #expect(
      validatedStarshipConfigs.withLock { $0 }
        == [root.appending(path: StarshipAdapter.bridgePath).path]
    )

    try "palette = \"user-owned\"\n".write(
      to: behaviorURL,
      atomically: true,
      encoding: .utf8
    )
    #expect(starship.inspection().status == .drifted)
    try "return {}\n".write(
      to: neovimPlugins.appending(path: "colorscheme.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(neovim.inspection().status == .drifted)
  }

  @Test
  func neovimGeneratedMappingCannotInjectLua() throws {
    let base = try catppuccinPackage()
    let unsafe = ThemePackage(
      packageURL: base.packageURL,
      schemaVersion: base.schemaVersion,
      id: base.id,
      displayName: base.displayName,
      appearance: base.appearance,
      semantic: base.semantic,
      terminal: base.terminal,
      wallpaper: base.wallpaper,
      wallpaperData: base.wallpaperData,
      mappings: ["neovim": "theme\"; os.execute('unsafe')"]
    )
    #expect(throws: NeovimAdapterError.self) {
      _ = try NeovimAdapter.render(package: unsafe, generationID: "g-test")
    }
  }

  @Test
  func macOSAppearanceAppliesDarkAndLightLiveAndVerifiesObservedState() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = Mutex(ThemeAppearance.light)
    let requests = Mutex([ProcessRequest]())
    let adapter = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: { true },
      currentAppearance: { state.withLock { $0 } },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments.last?.hasSuffix("true") == true {
          state.withLock { $0 = .dark }
        } else if request.arguments.last?.hasSuffix("false") == true {
          state.withLock { $0 = .light }
        }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    #expect(adapter.inspection(desiredAppearance: .dark).status == .drifted)
    #expect(
      try await adapter.reconciliation(desiredAppearance: { .dark }).run().status == .applied
    )
    #expect(
      try await adapter.reconciliation(desiredAppearance: { .dark }).run().status == .applied
    )
    #expect(
      try await adapter.reconciliation(desiredAppearance: { .light }).run().status == .applied
    )

    #expect(
      requests.withLock { $0 }
        == [
          Self.appearanceRequest(dark: true),
          Self.appearanceRequest(dark: false),
        ]
    )
    #expect(adapter.inspection(desiredAppearance: .light).status == .ready)
  }

  @Test
  func macOSAppearanceReportsCommandFailurePostApplyDriftAndUnavailableControl() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = Mutex(ThemeAppearance.light)
    let failed = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: { true },
      currentAppearance: { state.withLock { $0 } },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "Not authorized to send Apple events")
      }
    )
    let failure = try await failed.reconciliation(desiredAppearance: { .dark }).run()
    #expect(failure.status == .failed)
    #expect(failure.message == "Not authorized to send Apple events")

    let drifted = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: { true },
      currentAppearance: { state.withLock { $0 } },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    )
    let drift = try await drifted.reconciliation(desiredAppearance: { .dark }).run()
    #expect(drift.status == .drifted)
    #expect(drift.message?.contains("remains light; expected dark") == true)

    let unavailable = MacOSAppearanceAdapter(
      root: root,
      controlIsAvailable: { false },
      currentAppearance: { .dark },
      processRunner: ProcessRunner { _ in
        Issue.record("Unavailable control must fail before process execution")
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )
    #expect(unavailable.inspection(desiredAppearance: .dark).status == .failed)
    #expect(
      try await unavailable.reconciliation(desiredAppearance: { .dark }).run().status == .failed
    )
  }

  @Test
  func wallpaperAppliesEveryDriftedDisplayAndVerifiesTheResult() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let desired = root.appending(path: "desired.png")
    let displays = Mutex([
      WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: desired),
      WallpaperDisplay(id: 2, name: "External", wallpaperURL: root.appending(path: "old.png")),
    ])
    let applied = Mutex([UInt32]())
    let pending = Mutex<URL?>(nil)
    let adapter = WallpaperAdapter(
      root: root,
      control: WallpaperControl(
        inspect: { displays.withLock { $0 } },
        set: { wallpaperURL, displayID in
          applied.withLock { $0.append(displayID) }
          pending.withLock { $0 = wallpaperURL }
        }
      ),
      waitForSettle: {
        guard
          let wallpaperURL = pending.withLock({ value in
            defer { value = nil }
            return value
          })
        else { return }
        displays.withLock { displays in
          guard let index = displays.firstIndex(where: { $0.id == 2 }) else { return }
          displays[index] = WallpaperDisplay(
            id: displays[index].id,
            name: displays[index].name,
            wallpaperURL: wallpaperURL
          )
        }
      }
    )

    #expect(adapter.inspection(desiredWallpaperURL: desired).status == .drifted)
    #expect(
      try await adapter.reconciliation(desiredWallpaperURL: { desired }).run().status == .applied
    )
    #expect(
      try await adapter.reconciliation(desiredWallpaperURL: { desired }).run().status == .applied
    )
    #expect(applied.withLock { $0 } == [2])
    #expect(adapter.inspection(desiredWallpaperURL: desired).status == .ready)
  }

  @Test
  func wallpaperReportsPartialFailureAndPostApplyDrift() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let desired = root.appending(path: "desired.png")
    let existing = root.appending(path: "old.png")
    let display = WallpaperDisplay(id: 7, name: "External", wallpaperURL: existing)

    let failed = WallpaperAdapter(
      root: root,
      control: WallpaperControl(
        inspect: { [display] },
        set: { _, _ in throw CocoaError(.fileWriteNoPermission) }
      )
    )
    let failure = try await failed.reconciliation(desiredWallpaperURL: { desired }).run()
    #expect(failure.status == .failed)
    #expect(failure.message?.contains("External") == true)

    let drifted = WallpaperAdapter(
      root: root,
      control: WallpaperControl(
        inspect: { [display] },
        set: { _, _ in }
      ),
      waitForSettle: {}
    )
    let drift = try await drifted.reconciliation(desiredWallpaperURL: { desired }).run()
    #expect(drift.status == .drifted)
    #expect(drift.message?.contains("External") == true)
    #expect(
      WallpaperAdapter(
        root: root,
        control: WallpaperControl(inspect: { [] }, set: { _, _ in })
      ).inspection(desiredWallpaperURL: desired).status == .failed
    )
  }

  @Test
  func yabaiWallpaperSignalRequiresTheStableExecutableAndExactDirective() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "macarchy")
    try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let configuration = root.appending(path: "yabairc")
    let signal = YabaiWallpaperSignal(
      configurationURL: configuration,
      macarchyExecutableURL: executable,
      yabaiExecutableURL: executable
    )
    try "\(signal.directive)\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )

    try signal.preflight()
    let runtime = try JSONSerialization.data(withJSONObject: [
      [
        "label": "macarchy-wallpaper",
        "event": "space_changed",
        "action": "\(executable.path) reconcile wallpaper",
      ]
    ])
    let requests = Mutex([ProcessRequest]())
    try signal.runtimePreflight(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(
          terminationStatus: 0,
          output: String(decoding: runtime, as: UTF8.self)
        )
      }
    )
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: executable,
            arguments: ["-m", "signal", "--list"],
            timeout: 2
          )
        ]
    )
    #expect(throws: YabaiWallpaperSignalError.runtimeSignalMissing) {
      try signal.runtimePreflight(
        processRunner: ProcessRunner { _ in
          ProcessResult(terminationStatus: 0, output: "[]")
        }
      )
    }

    try "yabai -m config layout bsp\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    #expect(throws: YabaiWallpaperSignalError.self) {
      try signal.preflight()
    }

    try FileManager.default.removeItem(at: executable)
    #expect(throws: YabaiWallpaperSignalError.self) {
      try signal.preflight()
    }
  }

  @Test
  func wallpaperInspectionDoesNotHideDisplayFailureBehindSignalDrift() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kittyConfiguration = root.appending(path: "kitty.conf")
    try "include other.conf\n".write(
      to: kittyConfiguration,
      atomically: true,
      encoding: .utf8
    )
    let signal = try Self.wallpaperSignal(root: root)
    try "yabai -m config layout bsp\n".write(
      to: signal.configurationURL,
      atomically: true,
      encoding: .utf8
    )
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: kittyConfiguration,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") },
      wallpaperControl: WallpaperControl(inspect: { [] }, set: { _, _ in }),
      wallpaperSignal: signal
    )

    let inspection = try #require(coordinator.inspectAdapters(["wallpaper"]).first)

    #expect(inspection.status == .failed)
    #expect(inspection.message?.contains("did not return any current displays") == true)
    #expect(inspection.message?.contains("must contain") == true)
  }

  @Test
  func processRunnerTerminatesTimedOutCommands() throws {
    let executable = URL(filePath: "/bin/sleep")
    do {
      _ = try ProcessRunner.live.run(
        ProcessRequest(executableURL: executable, arguments: ["10"], timeout: 0.05)
      )
      Issue.record("Expected the process to time out")
    } catch let error as ProcessRunnerError {
      #expect(error == .timedOut(executable, 0.05))
    }
  }

  @Test
  func processRunnerAppliesEnvironmentOverrides() throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/printenv"),
        arguments: ["MACARCHY_PROCESS_TEST"],
        environmentOverrides: ["MACARCHY_PROCESS_TEST": "expected-value"]
      )
    )

    #expect(result.terminationStatus == 0)
    #expect(result.output == "expected-value")
  }

  @Test
  func macOSAppearancePreflightFailurePreservesThePreviousGeneration() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
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
      appearanceControlIsAvailable: { false }
    )

    await #expect(throws: MacOSAppearanceAdapterError.self) {
      _ = try await coordinator.activate(package: catppuccinPackage())
    }

    #expect(processCalls.withLock { $0 } == 0)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(previous.generationID)"
    )
  }

  @Test
  func wallpaperPreflightFailurePreservesThePreviousGeneration() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let previous = try testActivator(root: root).activate(package: tokyoNightPackage())
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
      wallpaperControl: WallpaperControl(inspect: { [] }, set: { _, _ in }),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    await #expect(throws: WallpaperAdapterError.noDisplays) {
      _ = try await coordinator.activate(package: catppuccinPackage())
    }
    #expect(processCalls.withLock { $0 } == 0)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: "current").path
      ) == "generations/\(previous.generationID)"
    )
  }

  @Test
  func configuredWallpaperBytesFlowThroughActivationIntoTheGeneration() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = try catppuccinPackage()
    var override = package.wallpaperData
    override.append(Data(repeating: 0, count: BoundedRegularFile.maximumSize))
    let overrideURL = root.appending(path: "personal.png")
    try override.write(to: overrideURL)

    let behaviorRoot = root.appending(path: "behavior", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: behaviorRoot, withIntermediateDirectories: true)
    let behaviorConfiguration = behaviorRoot.appending(path: "config.toml")
    try """
    schema_version = 1

    [wallpaper_overrides]
    catppuccin-mocha = "\(overrideURL.path)"
    """.write(to: behaviorConfiguration, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "config.toml"),
      withDestinationURL: behaviorConfiguration
    )

    let kittyConfiguration = root.appending(path: "kitty.conf")
    try "include \(root.path)/state/adapters/kitty.conf\n".write(
      to: kittyConfiguration,
      atomically: true,
      encoding: .utf8
    )
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: kittyConfiguration,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "no matching process")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root)
    )

    let result = try await coordinator.activate(package: package)
    let generated = try Data(
      contentsOf: root.appending(
        path: "generations/\(result.manifest.generationID)/generated/wallpaper.png"
      )
    )

    #expect(generated == override)
    #expect(generated.count > BoundedRegularFile.maximumSize)
  }

  @Test
  func selectedMacOSAppearanceReconciliationPreservesKittyEvidence() async throws {
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
    let store = ReconciliationStatusStore(root: root)
    _ = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "macos-appearance",
          requirement: .required,
          status: .drifted
        ),
      ]
    )
    let state = Mutex(ThemeAppearance.light)
    let requests = Mutex([ProcessRequest]())
    let coordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: try Self.consumerPaths(
        root: root, kittyConfigurationURL: configurationURL,
        sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)),
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        state.withLock { $0 = .dark }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      currentAppearance: { state.withLock { $0 } }
    )

    let result = try await coordinator.reconcile(adapterIDs: ["macos-appearance"])

    #expect(
      requests.withLock { $0 }
        == [
          Self.appearanceRequest(dark: true)
        ]
    )
    #expect(
      result.record.results
        == [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
          AdapterResult(
            adapterID: "macos-appearance",
            requirement: .required,
            status: .applied
          ),
        ]
    )
    #expect(try store.read() == .current(result.record))
  }

  @Test
  func overlappingActivationsLeaveAppearanceMatchingCanonicalState() async throws {
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
    let state = Mutex(
      (
        appearance: ThemeAppearance.dark,
        lightCommandEntered: false,
        darkPreflightEntered: false,
        releaseLightCommand: false,
        appearanceRequests: [ProcessRequest]()
      )
    )
    let runner = ProcessRunner { request in
      guard request.executableURL == URL(filePath: "/usr/bin/osascript") else {
        return ProcessResult(terminationStatus: 1, output: "no matching process")
      }
      state.withLock { state in
        state.appearanceRequests.append(request)
        if request.arguments.last?.hasSuffix("false") == true {
          state.lightCommandEntered = true
        }
      }
      if request.arguments.last?.hasSuffix("false") == true {
        while !state.withLock({ $0.releaseLightCommand }) {
          Thread.sleep(forTimeInterval: 0.001)
        }
        state.withLock { $0.appearance = .light }
      } else {
        state.withLock { $0.appearance = .dark }
      }
      return ProcessResult(terminationStatus: 0, output: "")
    }
    let consumerPaths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: configurationURL,
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
    let lightCoordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: runner,
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      currentAppearance: { state.withLock { $0.appearance } }
    )
    let darkCoordinator = ThemeActivationCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: runner,
      wallpaperControl: Self.wallpaperControl(),
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      currentAppearance: {
        state.withLock { state in
          state.darkPreflightEntered = true
          return state.appearance
        }
      }
    )
    let basePackage = try catppuccinPackage()
    let lightPackage = package(basePackage, appearance: .light)

    let lightActivation = Task {
      try await lightCoordinator.activate(package: lightPackage)
    }
    try await waitUntil { state.withLock { $0.lightCommandEntered } }

    let darkActivation = Task {
      try await darkCoordinator.activate(package: basePackage)
    }
    try await waitUntil { state.withLock { $0.darkPreflightEntered } }
    let committedBeforeRelease = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: Data(contentsOf: root.appending(path: "current/theme.json"))
    )
    #expect(committedBeforeRelease.appearance == .light)
    state.withLock { $0.releaseLightCommand = true }

    if case .failure(let error) = await lightActivation.result {
      #expect(error is ThemeCommittedWithReconciliationError)
    }
    let dark = try await darkActivation.value
    let normalized = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: Data(contentsOf: root.appending(path: "current/theme.json"))
    )

    #expect(normalized.appearance == .dark)
    #expect(state.withLock { $0.appearance } == .dark)
    #expect(
      state.withLock { $0.appearanceRequests }
        == [
          Self.appearanceRequest(dark: false),
          Self.appearanceRequest(dark: true),
        ]
    )
    #expect(try ReconciliationStatusStore(root: root).read() == .current(dark.reconciliation))
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
  func independentAdaptersReconcileConcurrentlyAndPersistDeterministically() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)
    let reconciler = ThemeReconciler(statusStore: store)
    let entered = Mutex(Set<String>())

    let first = AdapterReconciliation(id: "zeta", requirement: .optional) {
      _ = entered.withLock { $0.insert("zeta") }
      try await Self.waitForBothAdapters(entered)
      return AdapterOutcome(status: .pending)
    }
    let second = AdapterReconciliation(id: "alpha", requirement: .required) {
      _ = entered.withLock { $0.insert("alpha") }
      try await Self.waitForBothAdapters(entered)
      throw ReconciliationTestError.expectedFailure
    }

    let record = try await reconciler.reconcile(manifest: manifest, adapters: [first, second])
    #expect(
      record.results
        == [
          AdapterResult(
            adapterID: "alpha",
            requirement: .required,
            status: .failed,
            message: "expectedFailure"
          ),
          AdapterResult(adapterID: "zeta", requirement: .optional, status: .pending),
        ]
    )
    #expect(try store.read() == .current(record))

    let duplicateCalls = Mutex(0)
    await #expect(throws: ReconciliationStatusError.duplicateAdapterID) {
      _ = try await reconciler.reconcile(
        manifest: manifest,
        adapters: ["duplicate", "duplicate"].map { id in
          AdapterReconciliation(id: id, requirement: .required) {
            duplicateCalls.withLock { $0 += 1 }
            return AdapterOutcome(status: .applied)
          }
        }
      )
    }
    #expect(duplicateCalls.withLock { $0 } == 0)

    let supersedingPackage = try tokyoNightPackage()
    let supersedingActivator = testActivator(root: root)
    let superseding = AdapterReconciliation(id: "kitty", requirement: .required) {
      _ = try supersedingActivator.activate(package: supersedingPackage)
      return AdapterOutcome(status: .applied)
    }
    do {
      _ = try await reconciler.reconcile(manifest: manifest, adapters: [superseding])
      Issue.record("Expected reconciliation persistence failure")
    } catch let error as ReconciliationPersistenceError {
      #expect(error.manifest.generationID == manifest.generationID)
      #expect(
        error.results == [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)
        ])
      #expect(error.cause.contains("Cannot persist reconciliation"))
    }
  }

  @Test
  func reconciliationFaultsExposeWhetherCompletedResultsWerePersisted() async throws {
    for checkpoint in [
      ReconciliationCheckpoint.adaptersCompleted,
      .statusPersisted,
    ] {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
      let store = ReconciliationStatusStore(root: root)
      let calls = Mutex(0)
      let adapter = AdapterReconciliation(id: "kitty", requirement: .required) {
        calls.withLock { $0 += 1 }
        return AdapterOutcome(status: .applied)
      }
      let reconciler = ThemeReconciler(
        statusStore: store,
        faultInjector: { reached in
          if reached == checkpoint { throw ReconciliationTestError.expectedFailure }
        }
      )

      let interruption: ReconciliationInterruptedError
      do {
        _ = try await reconciler.reconcile(manifest: manifest, adapters: [adapter])
        throw ReconciliationTestError.expectedInterruption
      } catch let error as ReconciliationInterruptedError {
        interruption = error
      }

      #expect(interruption.statusPersisted == (checkpoint == .statusPersisted))
      #expect(
        interruption.results
          == [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
      )
      if checkpoint == .adaptersCompleted {
        #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))
      } else {
        guard case .current(let record) = try store.read() else {
          throw ReconciliationTestError.expectedCurrentStatus
        }
        #expect(record.results == interruption.results)
      }

      let recovered = try await ThemeReconciler(statusStore: store).reconcile(
        manifest: manifest,
        adapters: [adapter]
      )
      #expect(try store.read() == .current(recovered))
      #expect(calls.withLock { $0 } == 2)
    }

    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let cancelled = ThemeReconciler(
      statusStore: ReconciliationStatusStore(root: root),
      faultInjector: { _ in throw CancellationError() }
    )
    await #expect(throws: CancellationError.self) {
      _ = try await cancelled.reconcile(
        manifest: manifest,
        adapters: [
          AdapterReconciliation(id: "kitty", requirement: .required) {
            AdapterOutcome(status: .applied)
          }
        ]
      )
    }
  }

  @Test
  func spicetifyOneShotIsAwaitedAndItsOptionalFailureIsPersisted() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)
    let state = Mutex((requests: [ProcessRequest](), finished: false))
    let executable = URL(filePath: "/opt/homebrew/bin/spicetify")
    let adapter = SpicetifyAdapter(
      executableURL: executable,
      processRunner: ProcessRunner { request in
        state.withLock { $0.requests.append(request) }
        Thread.sleep(forTimeInterval: 0.1)
        state.withLock { $0.finished = true }
        return ProcessResult(terminationStatus: 1, output: "apply failed")
      }
    )

    let reconciliation = Task {
      try await ThemeReconciler(statusStore: store).reconcile(
        manifest: manifest,
        adapters: [adapter.reconciliation()]
      )
    }
    try await waitUntil { state.withLock { !$0.requests.isEmpty } }
    #expect(!state.withLock { $0.finished })
    #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))

    let record = try await reconciliation.value
    #expect(
      state.withLock { $0.requests }
        == [ProcessRequest(executableURL: executable, arguments: ["apply"])]
    )
    #expect(
      record.results
        == [
          AdapterResult(
            adapterID: "spicetify",
            requirement: .optional,
            status: .failed,
            message: "apply failed"
          )
        ]
    )
    #expect(try store.read() == .current(record))
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
          "macos-appearance", "atuin", "bat", "btop", "eza", "kitty", "neovim",
          "sketchybar", "starship", "wallpaper", "yazi",
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

  @Test
  func typedResultsArePersistedDeterministicallyForTheActiveGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)

    let persisted = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(
          adapterID: "wallpaper",
          requirement: .required,
          status: .failed,
          message: "Desktop image could not be updated"
        ),
        AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
        AdapterResult(
          adapterID: "sketchybar",
          requirement: .required,
          status: .drifted,
          message: "Observed palette differs from the active generation"
        ),
      ]
    )

    #expect(persisted.generationID == manifest.generationID)
    #expect(persisted.themeID == manifest.themeID)
    #expect(persisted.results.map(\.adapterID) == ["kitty", "sketchybar", "wallpaper"])
    #expect(
      persisted.results.map(\.status)
        == [.applied, .drifted, .failed]
    )
    #expect(try store.read() == .current(persisted))

    let statusData = try Data(contentsOf: root.appending(path: "state/reconciliation.json"))
    #expect(statusData.last == 0x0a)
    let permissions = try #require(
      FileManager.default.attributesOfItem(
        atPath: root.appending(path: "state/reconciliation.json").path
      )[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o077 == 0)

    _ = try store.persist(manifest: manifest, results: Array(persisted.results.reversed()))
    #expect(
      try Data(contentsOf: root.appending(path: "state/reconciliation.json")) == statusData
    )
  }

  @Test
  func statusCannotOverrideOrConcealTheActiveGeneration() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let store = ReconciliationStatusStore(root: root)
    let catppuccin = try testActivator(root: root).activate(package: catppuccinPackage())
    let record = try store.persist(
      manifest: catppuccin,
      results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .applied)]
    )

    let tokyoNight = try testActivator(root: root).activate(package: tokyoNightPackage())
    #expect(
      try store.read()
        == .stale(activeGenerationID: tokyoNight.generationID, record: record)
    )

    #expect(
      throws: ReconciliationStatusError.generationChanged(
        expected: catppuccin.generationID,
        active: tokyoNight.generationID
      )
    ) {
      _ = try store.persist(
        manifest: catppuccin,
        results: [AdapterResult(adapterID: "kitty", requirement: .required, status: .failed)]
      )
    }
  }

  @Test
  func missingAndMalformedStatusAreExplicit() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)

    #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))
    let statusURL = root.appending(path: "state/reconciliation.json")
    try FileManager.default.createDirectory(
      at: statusURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let redirectedStatus = root.appending(path: "redirected-status.json")
    try "{}".write(to: redirectedStatus, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: statusURL.path,
      withDestinationPath: redirectedStatus.path
    )
    #expect(throws: ReconciliationStatusError.self) {
      _ = try store.read()
    }
    try FileManager.default.removeItem(at: statusURL)

    #expect(throws: ReconciliationStatusError.self) {
      _ = try store.persist(
        manifest: manifest,
        results: [
          AdapterResult(
            adapterID: "oversized",
            requirement: .required,
            status: .failed,
            message: String(repeating: "x", count: BoundedRegularFile.maximumSize)
          )
        ]
      )
    }
    #expect(throws: ReconciliationStatusError.duplicateAdapterID) {
      _ = try store.persist(
        manifest: manifest,
        results: [
          AdapterResult(adapterID: "kitty", requirement: .required, status: .applied),
          AdapterResult(adapterID: "kitty", requirement: .required, status: .drifted),
        ]
      )
    }

    _ = try store.persist(
      manifest: manifest,
      results: [
        AdapterResult(adapterID: "a", requirement: .required, status: .applied),
        AdapterResult(adapterID: "b", requirement: .required, status: .applied),
      ]
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any]
    )
    object["results"] = Array(try #require(object["results"] as? [[String: Any]]).reversed())
    try JSONSerialization.data(withJSONObject: object).write(to: statusURL)
    #expect(throws: ReconciliationStatusError.nondeterministicResultOrder) {
      _ = try store.read()
    }
  }

  @Test
  func activeManifestRejectsBrokenPointerAndManifestIdentity() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let store = ReconciliationStatusStore(root: root)
    let missingGenerationID = "g-00000000-0000-0000-0000-000000000000"
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "current").path,
      withDestinationPath: "generations/\(missingGenerationID)"
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let manifestURL = root.appending(path: "generations/\(manifest.generationID)/manifest.json")
    let original = try Data(contentsOf: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    var object = try #require(
      JSONSerialization.jsonObject(with: original) as? [String: Any]
    )
    object["manifest_schema_version"] = GenerationManifest.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }

    object["manifest_schema_version"] = GenerationManifest.currentSchemaVersion
    object["generation_id"] = missingGenerationID
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    try expectInvalidActiveGeneration { try store.activeManifest() }
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func catppuccinPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
  }

  private func tokyoNightPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/tokyo-night",
        directoryHint: .isDirectory
      )
    )
  }

  private func package(
    _ base: ThemePackage,
    appearance: ThemeAppearance
  ) -> ThemePackage {
    ThemePackage(
      packageURL: base.packageURL,
      schemaVersion: base.schemaVersion,
      id: base.id,
      displayName: base.displayName,
      appearance: appearance,
      semantic: base.semantic,
      terminal: base.terminal,
      wallpaper: base.wallpaper,
      wallpaperData: base.wallpaperData,
      mappings: base.mappings
    )
  }

  private func testActivator(root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-adapter-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeWritableForRemoval(_ root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  private static func waitForBothAdapters(_ entered: borrowing Mutex<Set<String>>) async throws {
    for _ in 0..<100 {
      if entered.withLock({ $0.count }) == 2 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReconciliationTestError.timedOut
  }

  private static func appearanceScript(dark: Bool) -> String {
    "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
  }

  private static func appearanceRequest(dark: Bool) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/osascript"),
      arguments: ["-e", appearanceScript(dark: dark)],
      timeout: 2
    )
  }

  private static func wallpaperControl(
    initialURL: URL = URL(filePath: "/tmp/existing-wallpaper.png")
  ) -> WallpaperControl {
    let displays = Mutex([
      WallpaperDisplay(id: 1, name: "Test Display", wallpaperURL: initialURL)
    ])
    return WallpaperControl(
      inspect: { displays.withLock { $0 } },
      set: { wallpaperURL, displayID in
        try displays.withLock { displays in
          guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            throw WallpaperAdapterError.unavailableDisplay(displayID)
          }
          displays[index] = WallpaperDisplay(
            id: displays[index].id,
            name: displays[index].name,
            wallpaperURL: wallpaperURL
          )
        }
      }
    )
  }

  private static func wallpaperSignal(root: URL) throws -> YabaiWallpaperSignal {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "test-yabai")
    try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let signal = YabaiWallpaperSignal(
      configurationURL: root.appending(path: "test-yabairc"),
      macarchyExecutableURL: executable,
      yabaiExecutableURL: executable
    )
    try "\(signal.directive)\n".write(
      to: signal.configurationURL,
      atomically: true,
      encoding: .utf8
    )
    return signal
  }

  private static func sketchyBarConfiguration(root: URL) throws -> URL {
    let configurationRoot = root.appending(path: "sketchybar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: configurationRoot,
      withIntermediateDirectories: true
    )
    let configuration = configurationRoot.appending(path: "sketchybarrc")
    try "\(SketchyBarAdapter.initImport)\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    try "\(SketchyBarAdapter.readyMarkerDeclaration)\n".write(
      to: configurationRoot.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    let colors = configurationRoot.appending(path: "colors.lua")
    try "\(SketchyBarAdapter.paletteImport(root: root))\nreturn colors\n".write(
      to: colors,
      atomically: true,
      encoding: .utf8
    )
    return configuration
  }

  private static func consumerPaths(
    root: URL,
    kittyConfigurationURL: URL,
    sketchyBarConfigurationURL: URL
  ) throws -> ThemeConsumerPaths {
    let ezaDirectory = root.appending(path: "eza", directoryHint: .isDirectory)
    let batDirectory = root.appending(path: "bat", directoryHint: .isDirectory)
    let btopDirectory = root.appending(path: "btop", directoryHint: .isDirectory)
    let yaziDirectory = root.appending(path: "yazi", directoryHint: .isDirectory)
    let atuinDirectory = root.appending(path: "atuin", directoryHint: .isDirectory)
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let neovimPlugins = neovimDirectory.appending(
      path: "lua/plugins", directoryHint: .isDirectory)
    let neovimMacarchy = neovimDirectory.appending(
      path: "lua/macarchy", directoryHint: .isDirectory)
    let starshipDirectory = root.appending(path: "starship", directoryHint: .isDirectory)
    let batThemes = batDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let btopThemes = btopDirectory.appending(path: "themes", directoryHint: .isDirectory)
    let yaziFlavor = yaziDirectory.appending(
      path: "flavors/\(YaziAdapter.flavorName).yazi", directoryHint: .isDirectory)
    let atuinThemes = atuinDirectory.appending(path: "themes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ezaDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: batThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: btopThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: yaziFlavor, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: atuinThemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimPlugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: neovimMacarchy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: starshipDirectory, withIntermediateDirectories: true)

    let ezaTheme = ezaDirectory.appending(path: "theme.yml")
    try FileManager.default.createSymbolicLink(
      at: ezaTheme,
      withDestinationURL: root.appending(path: "current/\(EzaAdapter.outputPath)")
    )
    let batTheme = batThemes.appending(path: "\(BatAdapter.themeName).tmTheme")
    try FileManager.default.createSymbolicLink(
      at: batTheme,
      withDestinationURL: root.appending(path: "current/\(BatAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: btopThemes.appending(path: "\(BtopAdapter.themeName).theme"),
      withDestinationURL: root.appending(path: "current/\(BtopAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "flavor.toml"),
      withDestinationURL: root.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavor.appending(path: "tmtheme.xml"),
      withDestinationURL: root.appending(path: "current/\(YaziAdapter.syntaxOutputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: atuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
      withDestinationURL: root.appending(path: "current/\(AtuinAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: neovimMacarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "current/\(NeovimAdapter.outputPath)")
    )
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "starship.toml"),
      withDestinationURL: root.appending(path: StarshipAdapter.bridgePath)
    )

    let shellConfiguration = root.appending(path: ".zshrc")
    try "export EZA_CONFIG_DIR=\"\(ezaDirectory.path)\"\n".write(
      to: shellConfiguration,
      atomically: true,
      encoding: .utf8
    )
    try "--theme=\"\(BatAdapter.themeName)\"\n".write(
      to: batDirectory.appending(path: "config"),
      atomically: true,
      encoding: .utf8
    )
    try "color_theme = \"\(BtopAdapter.themeName)\"\n".write(
      to: btopDirectory.appending(path: "btop.conf"), atomically: true, encoding: .utf8)
    try "[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n".write(
      to: yaziDirectory.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    try "[theme]\nname = \"\(AtuinAdapter.themeName)\"\n".write(
      to: atuinDirectory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try "\(NeovimAdapter.integrationDirective)\n".write(
      to: neovimPlugins.appending(path: "colorscheme.lua"), atomically: true, encoding: .utf8)
    try "format = \"$character\"\n".write(
      to: starshipDirectory.appending(path: "behavior.toml"),
      atomically: true,
      encoding: .utf8
    )

    return ThemeConsumerPaths(
      kittyConfigurationURL: kittyConfigurationURL,
      sketchyBarConfigurationURL: sketchyBarConfigurationURL,
      shellConfigurationURL: shellConfiguration,
      ezaConfigurationDirectoryURL: ezaDirectory,
      batConfigurationDirectoryURL: batDirectory,
      batCacheDirectoryURL: root.appending(path: "bat-cache", directoryHint: .isDirectory),
      btopConfigurationDirectoryURL: btopDirectory,
      yaziConfigurationDirectoryURL: yaziDirectory,
      atuinConfigurationDirectoryURL: atuinDirectory,
      neovimConfigurationDirectoryURL: neovimDirectory,
      starshipConfigurationURL: root.appending(path: "starship.toml"),
      starshipBehaviorURL: starshipDirectory.appending(path: "behavior.toml")
    )
  }

  private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReconciliationTestError.timedOut
  }

  private func expectInvalidActiveGeneration(
    _ operation: () throws -> GenerationManifest
  ) throws {
    do {
      _ = try operation()
      Issue.record("Expected invalid active generation")
    } catch ReconciliationStatusError.invalidActiveGeneration {
      return
    }
  }
}

private enum ReconciliationTestError: Error {
  case expectedCommittedError
  case expectedCurrentStatus
  case expectedFailure
  case expectedInterruption
  case timedOut
}
