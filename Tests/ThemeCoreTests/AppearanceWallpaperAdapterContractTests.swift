import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
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
  func wallpaperLeavesUnmanagedThemesUntouched() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inspections = Mutex(0)
    let writes = Mutex(0)
    let adapter = WallpaperAdapter(
      root: root,
      control: WallpaperControl(
        inspect: {
          inspections.withLock { $0 += 1 }
          return []
        },
        set: { _, _ in writes.withLock { $0 += 1 } }
      )
    )
    let reconciliation = adapter.reconciliation { nil }

    let result = try await reconciliation.run()

    #expect(result.status == .disabled)
    #expect(result.message?.contains("intentionally unmanaged") == true)
    #expect(inspections.withLock { $0 } == 0)
    #expect(writes.withLock { $0 } == 0)
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
  func macOSAppearancePreflightFailurePreservesThePreviousGeneration() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
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
  }

  @Test
  func wallpaperPreflightFailurePreservesThePreviousGeneration() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
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
        wallpaperSignal: try Self.wallpaperSignal(root: root),
        enabledAdapterIDs: [WallpaperAdapter.id]
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
  }

  @Test
  func selectedPersonalWallpaperBytesFlowThroughActivationIntoTheGeneration() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = try catppuccinPackage()
    var override = try Data(
      contentsOf: repositoryRoot.appending(path: "Tests/Fixtures/Images/test-wallpaper.png")
    )
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
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      enabledAdapterIDs: [WallpaperAdapter.id]
    )

    let result = try await coordinator.activate(
      package: package,
      requestedBackgroundID: "personal"
    )
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
        darkActivationStarted: false,
        darkPreflightEntered: false,
        appearanceRequests: [ProcessRequest]()
      )
    )
    let releaseLightCommand = DispatchSemaphore(value: 0)
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
        releaseLightCommand.wait()
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
      currentAppearance: { state.withLock { $0.appearance } },
      enabledAdapterIDs: [MacOSAppearanceAdapter.id]
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
      },
      enabledAdapterIDs: [MacOSAppearanceAdapter.id]
    )
    let basePackage = try catppuccinPackage()
    let lightPackage = package(basePackage, appearance: .light)

    let lightActivation = Task.detached {
      try await lightCoordinator.activate(package: lightPackage)
    }
    try await waitUntil { state.withLock { $0.lightCommandEntered } }

    let darkActivation = Task.detached {
      state.withLock { $0.darkActivationStarted = true }
      return try await darkCoordinator.activate(package: basePackage)
    }
    try await waitUntil { state.withLock { $0.darkActivationStarted } }
    let committedBeforeRelease = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: Data(contentsOf: root.appending(path: "current/theme.json"))
    )
    #expect(committedBeforeRelease.appearance == .light)
    #expect(!state.withLock { $0.darkPreflightEntered })
    releaseLightCommand.signal()
    try await waitUntil { state.withLock { $0.darkPreflightEntered } }

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
      backgrounds: base.backgrounds,
      backgroundData: base.backgroundData,
      mappings: base.mappings
    )
  }

}
