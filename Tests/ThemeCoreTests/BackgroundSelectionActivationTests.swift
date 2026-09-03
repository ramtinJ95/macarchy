import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func backgroundOnlyActivationCarriesEvidenceAndRestoresRememberedSelection() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let package = try packageWithSecondBackground(root: root)
    let requests = BackgroundRequestLog()
    let wallpaperState = BackgroundWallpaperState(
      (url: URL(filePath: "/tmp/existing-wallpaper.png"), setCount: 0)
    )
    let consumerPaths = try backgroundConsumerPaths(root: root)
    let coordinator = try backgroundCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      requests: requests,
      wallpaperControl: trackedWallpaperControl(state: wallpaperState)
    )

    let first = try await coordinator.activate(package: package)
    #expect(first.manifest.background == GenerationBackground(id: "default", format: .webp))
    let baseline = try ReconciliationStatusStore(root: root).persist(
      manifest: first.manifest,
      results: first.reconciliation.results.map { result in
        guard result.adapterID == SpicetifyAdapter.id else { return result }
        return AdapterResult(
          adapterID: result.adapterID,
          requirement: result.requirement,
          status: .failed,
          message: "Fixture failure remains actionable"
        )
      }
    )
    requests.values.withLock { $0.removeAll() }

    let withoutTuicr = try backgroundCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      requests: requests,
      wallpaperControl: trackedWallpaperControl(state: wallpaperState),
      enabledAdapterIDs: Set(ThemeActivationCoordinator.adapterRequirements.keys)
        .subtracting([PiAdapter.id, TuicrAdapter.id])
    )
    let second = try await withoutTuicr.activate(
      package: package,
      expectedActiveGenerationID: first.manifest.generationID,
      requestedBackgroundID: "second"
    )

    #expect(second.manifest.background == GenerationBackground(id: "second", format: .webp))
    #expect(requests.values.withLock { $0 }.isEmpty)
    #expect(wallpaperState.value.withLock { $0.setCount } == 2)
    let priorResults = Dictionary(
      uniqueKeysWithValues: baseline.results.map { ($0.adapterID, $0) }
    )
    for result in second.reconciliation.results where result.adapterID != WallpaperAdapter.id {
      let prior = try #require(priorResults[result.adapterID])
      #expect(result.requirement == prior.requirement)
      #expect(result.status == prior.status)
      #expect(result.message == prior.message)
      #expect(result.carriedForwardFromGenerationID == first.manifest.generationID)
    }
    #expect(!second.reconciliation.results.contains { $0.adapterID == TuicrAdapter.id })
    #expect(
      try BackgroundPreferenceStore(root: root).load()[package.id] == "second"
    )

    var stalePreferences = try BackgroundPreferenceStore(root: root).load()
    stalePreferences[package.id] = "default"
    try BackgroundPreferenceStore(root: root).persist(stalePreferences)
    _ = try await coordinator.activate(package: tokyoNightPackage())
    let restarted = try backgroundCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      requests: requests,
      wallpaperControl: trackedWallpaperControl(state: wallpaperState)
    )
    let restored = try await restarted.activate(package: package)
    #expect(restored.manifest.background == GenerationBackground(id: "second", format: .webp))

    let removed = try removingSecondBackground(from: package)
    let fallback = try await restarted.activate(package: removed)
    #expect(fallback.manifest.background == GenerationBackground(id: "default", format: .webp))
    #expect(
      fallback.notice
        == "Remembered background 'second' is no longer available; selected the first background."
    )

    try Data("not-json\n".utf8).write(
      to: root.appending(path: "state/reconciliation.json"),
      options: .atomic
    )
    requests.values.withLock { $0.removeAll() }
    let healed = try await restarted.activate(
      package: removed,
      expectedActiveGenerationID: fallback.manifest.generationID,
      requestedBackgroundID: "default"
    )
    #expect(!requests.values.withLock { $0 }.isEmpty)
    #expect(try ReconciliationStatusStore(root: root).read() == .current(healed.reconciliation))

    requests.values.withLock { $0.removeAll() }
    let repeated = try await restarted.activate(
      package: removed,
      expectedActiveGenerationID: healed.manifest.generationID,
      requestedBackgroundID: "default"
    )
    #expect(repeated.manifest.generationID == healed.manifest.generationID)
    #expect(requests.values.withLock { $0 }.isEmpty)
    #expect(
      repeated.reconciliation.results.filter { $0.adapterID != WallpaperAdapter.id }
        == healed.reconciliation.results.filter { $0.adapterID != WallpaperAdapter.id }
    )
  }

  @Test
  func zeroBackgroundActivationLeavesWallpaperUntouchedAndReportsItDisabled() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
      let package = try packageWithoutBackgrounds(root: root)
      let requests = BackgroundRequestLog()
      let wallpaperInspections = Mutex(0)
      let consumerPaths = try backgroundConsumerPaths(root: root)
      let coordinator = try backgroundCoordinator(
        root: root,
        consumerPaths: consumerPaths,
        requests: requests,
        wallpaperControl: WallpaperControl(
          inspect: {
            wallpaperInspections.withLock { $0 += 1 }
            throw WallpaperAdapterError.noDisplays
          },
          set: { _, _ in Issue.record("Zero-background activation tried to set wallpaper") }
        )
      )

      let result = try await coordinator.activate(package: package)

      #expect(result.manifest.background == nil)
      #expect(result.manifest.artifacts[WallpaperAdapter.outputPath] == nil)
      #expect(wallpaperInspections.withLock { $0 } == 0)
      #expect(
        result.reconciliation.results.first { $0.adapterID == WallpaperAdapter.id }
          == AdapterResult(
            adapterID: WallpaperAdapter.id,
            requirement: .required,
            status: .disabled,
            message: "This theme has no backgrounds; macOS wallpaper is intentionally unmanaged"
          )
      )
    }
  }

  private func packageWithSecondBackground(root: URL) throws -> ThemePackage {
    let packageURL = root.appending(path: "multi-background", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"),
      to: packageURL
    )
    let source = packageURL.appending(path: "wallpapers/1-totoro.webp")
    let second = packageURL.appending(path: "wallpapers/second.webp")
    try FileManager.default.copyItem(at: source, to: second)
    let manifestURL = packageURL.appending(path: "theme.toml")
    var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    manifest = try #require(
      manifest.components(separatedBy: "\n\n[[backgrounds]]\nid = \"waves\"").first
    )
    manifest += """

      [[backgrounds]]
      id = "second"
      path = "wallpapers/second.webp"
      source = "Selection fixture"
      author = "Fixture author"
      license = "MIT"
      """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    return try ThemePackageLoader().load(packageURL: packageURL)
  }

  private func packageWithoutBackgrounds(root: URL) throws -> ThemePackage {
    let packageURL = root.appending(path: "zero-background", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: repositoryRoot.appending(path: "Themes/catppuccin-mocha"),
      to: packageURL
    )
    let manifestURL = packageURL.appending(path: "theme.toml")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    let updated =
      try #require(manifest.components(separatedBy: "\n[[backgrounds]]").first)
      + "\n"
    try #require(updated != manifest)
    try updated.write(to: manifestURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: packageURL.appending(path: "LICENSES/wallpaper.md"))
    return try ThemePackageLoader().load(packageURL: packageURL)
  }

  private func removingSecondBackground(from package: ThemePackage) throws -> ThemePackage {
    let manifestURL = package.packageURL.appending(path: "theme.toml")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    let second = """

      [[backgrounds]]
      id = "second"
      path = "wallpapers/second.webp"
      source = "Selection fixture"
      author = "Fixture author"
      license = "MIT"
      """
    let updated = manifest.replacingOccurrences(of: second, with: "")
    try #require(updated != manifest)
    try updated.write(to: manifestURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(
      at: package.packageURL.appending(path: "wallpapers/second.webp")
    )
    return try ThemePackageLoader().load(packageURL: package.packageURL)
  }

  private func backgroundCoordinator(
    root: URL,
    consumerPaths: ThemeConsumerPaths,
    requests: BackgroundRequestLog,
    wallpaperControl: WallpaperControl,
    enabledAdapterIDs: Set<String>? = nil
  ) throws -> ThemeActivationCoordinator {
    let runner = ProcessRunner { request in
      requests.values.withLock { $0.append(request) }
      if request.executableURL == URL(filePath: "/usr/bin/osascript")
        || request.executableURL == BatAdapter.liveExecutableURL
        || request.executableURL == EzaAdapter.liveExecutableURL
        || request.executableURL == HerdrAdapter.liveExecutableURL
        || request.executableURL == SpicetifyAdapter.liveExecutableURL
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
      if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
        return ProcessResult(terminationStatus: 1, output: "")
      }
      if request.arguments == ["-USR1", "kitty"] || request.arguments == ["-0", "kitty"] {
        return ProcessResult(terminationStatus: 0, output: "")
      }
      if request.executableURL == SketchyBarAdapter.liveExecutableURL {
        let output =
          request.arguments == ["--query", "bar"]
          ? #"{"drawing":"on","color":"0xf01e1e2e","items":["macarchy.theme.ready"]}"#
          : ""
        return ProcessResult(terminationStatus: 0, output: output)
      }
      return ProcessResult(terminationStatus: 1, output: "fixture denied")
    }
    return ThemeActivationCoordinator(
      root: root,
      consumerPaths: consumerPaths,
      processRunner: runner,
      wallpaperControl: wallpaperControl,
      wallpaperSignal: try Self.wallpaperSignal(root: root),
      currentAppearance: { .dark },
      enabledAdapterIDs: enabledAdapterIDs
        ?? Set(ThemeActivationCoordinator.adapterRequirements.keys).subtracting([PiAdapter.id])
    )
  }

  private func backgroundConsumerPaths(root: URL) throws -> ThemeConsumerPaths {
    let kittyConfiguration = root.appending(path: "kitty.conf")
    try "\(ThemeActivationCoordinator.kittyIncludeDirective(root: root))\n".write(
      to: kittyConfiguration,
      atomically: true,
      encoding: .utf8
    )
    return try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: kittyConfiguration,
      sketchyBarConfigurationURL: try Self.sketchyBarConfiguration(root: root)
    )
  }

  private func trackedWallpaperControl(
    state: BackgroundWallpaperState
  ) -> WallpaperControl {
    WallpaperControl(
      inspect: {
        state.value.withLock { state in
          [WallpaperDisplay(id: 1, name: "Test", wallpaperURL: state.url)]
        }
      },
      set: { url, _ in
        state.value.withLock { state in
          state.url = url
          state.setCount += 1
        }
      }
    )
  }
}

private final class BackgroundRequestLog: Sendable {
  let values = Mutex([ProcessRequest]())
}

private final class BackgroundWallpaperState: Sendable {
  let value: Mutex<(url: URL, setCount: Int)>

  init(_ initial: (url: URL, setCount: Int)) {
    value = Mutex(initial)
  }
}
