import Foundation
import Synchronization
import TOMLDecoder
import TestSupport
import Testing

@testable import ThemeCore

struct AlacrittyAdapterTests {
  @Test(arguments: ["catppuccin-mocha", "tokyo-night", "kanagawa-wave"])
  func rendererUsesPackageTerminalColors(theme: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(theme)"))
    let output = try TOMLDecoder().decode(
      [String: [String: [String: String]]].self,
      from: AlacrittyAdapter.render(package: package))
    let colors = try #require(output["colors"])
    #expect(
      colors["primary"] == [
        "background": package.terminal.background.rawValue,
        "foreground": package.terminal.foreground.rawValue,
      ])
    #expect(
      colors["cursor"] == [
        "text": package.terminal.background.rawValue,
        "cursor": package.terminal.cursor.rawValue,
      ])
    #expect(
      colors["selection"] == [
        "text": package.terminal.selectionForeground.rawValue,
        "background": package.terminal.selectionBackground.rawValue,
      ])
    let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    for (table, offset) in [("normal", 0), ("bright", 8)] {
      #expect(
        colors[table]
          == Dictionary(
            uniqueKeysWithValues:
              names.enumerated().map {
                ($0.element, package.terminal.ansi[offset + $0.offset].rawValue)
              }))
    }
  }
  @Test func fileSearchIncludesXDGSystemDirectoriesBeforeHomeFallbacks() throws {
    let home = URL(filePath: "/home/test")
    let files = AlacrittyConfiguration.files(
      home: home,
      environment: [
        "XDG_CONFIG_HOME": "/home/test/custom", "XDG_CONFIG_DIRS": "/one:/two:relative",
      ])
    #expect(
      files.map(\.path) == [
        "/home/test/custom/alacritty/alacritty.toml", "/one/alacritty/alacritty.toml",
        "/two/alacritty/alacritty.toml", "/home/test/custom/alacritty.toml",
        "/one/alacritty.toml", "/two/alacritty.toml", "/home/test/.config/alacritty/alacritty.toml",
        "/home/test/.alacritty.toml", "/etc/alacritty/alacritty.toml",
      ])
  }

  @Test(arguments: ["alacritty 0.14.0", "alacritty 0.17.0 (aabbcc)", "alacritty 1.0.0"])
  func releasedVersions(output: String) throws {
    try AlacrittyAdapter.requireSupported(#require(AlacrittyAdapter.parseVersion(output)))
  }
  @Test func oldAndUnknownVersionsAreExplicit() {
    #expect(throws: (any Error).self) { try AlacrittyAdapter.requireSupported([0, 13, 2]) }
    for text in ["unknown", "alacritty 0.17", "alacritty 0.17.0-dev", "kitty 0.17.0"] {
      #expect(AlacrittyAdapter.parseVersion(text) == nil)
    }
  }
  @Test func reloadFlagsIncludeLegacyPrecedence() throws {
    #expect(try AlacrittyImportEdit.liveReload("[general]\nimport = []\n"))
    #expect(try !AlacrittyImportEdit.liveReload("[general]\nlive_config_reload = false\n"))
    #expect(
      try !AlacrittyImportEdit.liveReload(
        "live_config_reload = false\n[general]\nlive_config_reload = true\n"))
  }
  @Test func reloadFlagIsResolvedThroughImports() throws {
    try withTemporaryRoot(named: "alacritty-reload") { home in
      let source = home.appending(path: "alacritty.toml")
      let included = home.appending(path: "base.toml")
      try Data("[general]\nlive_config_reload = false\n".utf8).write(to: included)
      let text = "[general]\nimport = ['base.toml']\n"
      #expect(
        try !AlacrittyConfiguration.reloadState(configuration: text, source: source, home: home)
          .enabled)
      #expect(
        try AlacrittyConfiguration.reloadState(
          configuration: text + "live_config_reload = true\n", source: source, home: home
        ).enabled)
      try Data("live_config_reload = false\n".utf8).write(to: included)
      #expect(
        try !AlacrittyConfiguration.reloadState(
          configuration: text + "live_config_reload = true\n", source: source, home: home
        ).enabled)
    }
  }
  @Test func mainAndLaterImportOverridesAreNamed() throws {
    try withTemporaryRoot(named: "alacritty-overrides") { home in
      let source = home.appending(path: "alacritty.toml")
      let later = home.appending(path: "later.toml")
      try Data("[colors.cursor]\ncursor = '#123456'\n".utf8).write(to: later)
      let theme = home.appending(path: AlacrittyAdapter.bridgePath).path
      let text =
        "[general]\nimport = [\"\(theme)\", 'later.toml']\n[colors.primary]\nbackground = '#654321'\n"
      let message = try #require(
        AlacrittyConfiguration.overrideMessage(
          configuration: text, source: source, root: home, home: home))
      #expect(message.contains(later.path))
      #expect(message.contains(source.path))
      #expect(message.contains("colors.cursor.cursor"))
      #expect(message.contains("colors.primary.background"))
    }
  }

  @Test func legacyYAMLIsNotShadowed() throws {
    try withTemporaryRoot(named: "alacritty-yaml") { home in
      let files = ThemeConsumerPaths.alacrittyConfigurationFiles(home: home, environment: [:])
      let yaml = home.appending(path: ".alacritty.yml")
      try Data("font:\n  size: 12\n".utf8).write(to: yaml)
      do {
        _ = try AlacrittyConfiguration.selectedFile(in: files)
        Issue.record("YAML should require explicit native migration")
      } catch {
        #expect(String(describing: error).contains(yaml.path))
        #expect(String(describing: error).contains("alacritty migrate"))
      }
      #expect(!FileManager.default.fileExists(atPath: files[0].path))
    }
  }

  @Test(arguments: [true, false])
  func bridgeIsAnOrdinaryFileAndReloadBoundaryIsExplicit(reload: Bool) async throws {
    try await withTemporaryRoot(named: "alacritty-bridge") { home in
      let adapter = try fixture(home: home, reload: reload)
      #expect(adapter.inspection().status == .drifted)
      let first = try await adapter.reconciliation().run()
      #expect(first.status == (reload ? .applied : .restartRequired))
      let bridge = home.appending(path: AlacrittyAdapter.bridgePath)
      #expect(
        try Data(contentsOf: bridge)
          == Data(
            AlacrittyAdapter.render(package: BuiltInThemePackages.catppuccinMocha.get()).utf8))
      #expect(adapter.inspection().status == .ready)
      _ = try ThemeActivator(root: home, faultInjector: { _ in }).activate(
        package: BuiltInThemePackages.tokyoNight.get())
      #expect(adapter.inspection().status == .drifted)
      let second = try await adapter.reconciliation().run()
      #expect(second.status == (reload ? .applied : .restartRequired))
      #expect(
        try Data(contentsOf: bridge)
          == Data(
            AlacrittyAdapter.render(package: BuiltInThemePackages.tokyoNight.get()).utf8))
      #expect(
        (try FileManager.default.attributesOfItem(atPath: bridge.path)[.type]) as? FileAttributeType
          == .typeRegular)
      if !reload { #expect(second.message?.contains("next_invocation") == true) }
    }
  }

  @Test func missingAppAndVersionGate() throws {
    try withTemporaryRoot(named: "alacritty-version") { home in
      let missing = try fixture(home: home, available: false)
      let old = try fixture(home: home, version: "alacritty 0.13.2")
      let unknown = try fixture(home: home, version: "unknown")
      #expect(missing.inspection().status == .failed)
      #expect(old.inspection().status == .unsupported)
      #expect(unknown.inspection().status == .failed)
    }
  }

  @Test func reopenBoundaryPersistsUntilEveryOldProcessExits() async throws {
    try await withTemporaryRoot(named: "alacritty-watcher") { home in
      let starts = Mutex<[UInt64]>([50])
      let clock = Mutex<UInt64>(100)
      let adapter = try fixture(
        home: home, runningProcessStarts: { starts.withLock { $0 } }, now: { clock.withLock { $0 } }
      )
      #expect(adapter.repaintBoundary() == .nextLaunch)
      for _ in 0..<2 {
        let result = try await adapter.reconciliation().run()
        #expect(result.status == .restartRequired)
        #expect(result.message?.contains("Reopen Alacritty once") == true)
        #expect(adapter.repaintBoundary() == .nextLaunch)
        clock.withLock { $0 = 200 }
      }
      #expect(try AlacrittyConnection.read(root: home)?.adoptedAt == 100)
      starts.withLock { $0 = [101] }
      #expect(adapter.repaintBoundary() == .live)
      #expect(try await adapter.reconciliation().run().status == .applied)
      // One newer window does not clear the requirement for another old process.
      starts.withLock { $0 = [50, 101] }
      #expect(try await adapter.reconciliation().run().status == .restartRequired)
      starts.withLock { $0 = [] }
      #expect(adapter.repaintBoundary() == .live)
      #expect(try await adapter.reconciliation().run().status == .applied)
    }
  }

  @Test func missingConnectionWithAnExistingBridgeDoesNotProveWatcherReadiness() async throws {
    try await withTemporaryRoot(named: "alacritty-missing-connection") { home in
      let adapter = try fixture(home: home, runningProcessStarts: { [50] })
      try StableAdapterBridge.restore(
        at: home.appending(path: AlacrittyAdapter.bridgePath), data: Data("# old bridge\n".utf8),
        mode: 0o644)
      #expect(adapter.repaintBoundary() == .nextLaunch)
      #expect(try await adapter.reconciliation().run().status == .restartRequired)
      #expect(adapter.repaintBoundary() == .nextLaunch)
    }
  }

  @Test func unreadableProcessObservationIsExplicit() throws {
    try withTemporaryRoot(named: "alacritty-process-error") { home in
      let adapter = try fixture(
        home: home,
        runningProcessStarts: {
          throw AlacrittyConnection.Failure.observation("unreadable live PID")
        })
      #expect(throws: AlacrittyConnection.Failure.self) { try adapter.preflight() }
      #expect(adapter.repaintBoundary() == .nextLaunch)
      #expect(adapter.inspection().status == .failed)
    }
  }

  @Test func redirectedBridgeParentIsRefused() async throws {
    try await withTemporaryRoot(named: "alacritty-redirect") { home in
      let adapter = try fixture(home: home)
      let target = home.appending(path: "elsewhere")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: "state"), withDestinationURL: target)
      await #expect(throws: (any Error).self) { try await adapter.reconciliation().run() }
      #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
  }

  private func fixture(
    home: URL, reload: Bool = true, available: Bool = true,
    version: String = "alacritty 0.17.0 (aabbcc)",
    runningProcessStarts: @escaping @Sendable () throws -> [UInt64] = { [] },
    now: @escaping @Sendable () -> UInt64 = { 100 }
  ) throws -> AlacrittyAdapter {
    let files = ThemeConsumerPaths.alacrittyConfigurationFiles(home: home, environment: [:])
    let source = Data("[general]\nlive_config_reload = \(reload)\n".utf8)
    let edit = try AlacrittyImportEdit.adopting(
      source, themePath: home.appending(path: AlacrittyAdapter.bridgePath).path)
    try FileManager.default.createDirectory(
      at: files[0].deletingLastPathComponent(), withIntermediateDirectories: true)
    try edit.apply(to: source).write(to: files[0])
    _ = try ThemeActivator(root: home, faultInjector: { _ in }).activate(
      package: BuiltInThemePackages.catppuccinMocha.get())
    return AlacrittyAdapter(
      root: home, home: home, configurationFiles: files,
      ownedConfigurationURL: files[0], ownedImportEdit: edit,
      executableURL: AlacrittyAdapter.liveExecutableURL, controlIsAvailable: { available },
      processRunner: ProcessRunner { request in
        #expect(request.arguments == ["--version"])
        return ProcessResult(terminationStatus: 0, output: version)
      }, runningProcessStarts: runningProcessStarts, now: now)
  }
}
