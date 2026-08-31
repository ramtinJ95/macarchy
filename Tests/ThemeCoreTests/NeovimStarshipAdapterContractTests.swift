import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
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
    try writeBackgroundAwareWatcher(at: neovimDirectory)
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
    #expect(neovim.inspection(includeRuntimeChecks: true).status == .ready)
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
  func neovimRuntimeInspectionExposesRejectedActivePalette() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let plugins = neovimDirectory.appending(path: "lua/plugins", directoryHint: .isDirectory)
    let macarchy = neovimDirectory.appending(path: "lua/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: macarchy, withIntermediateDirectories: true)
    try writeBackgroundAwareWatcher(at: neovimDirectory)
    try "\(NeovimAdapter.integrationDirective)\n".write(
      to: plugins.appending(path: "colorscheme.lua"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: macarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "current/\(NeovimAdapter.outputPath)")
    )
    let adapter = NeovimAdapter(
      root: root,
      configurationDirectoryURL: neovimDirectory,
      executableURL: NeovimAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "Aether palette mismatch")
      }
    )

    #expect(adapter.inspection().status == .ready)
    let runtime = adapter.inspection(includeRuntimeChecks: true)
    #expect(runtime.status == .failed)
    #expect(runtime.message == "Aether palette mismatch")

    try "return {}\n".write(
      to: neovimDirectory.appending(path: "lua/config/macarchy-theme.lua"),
      atomically: true,
      encoding: .utf8
    )
    let watcherDrift = adapter.inspection()
    #expect(watcherDrift.status == .drifted)
    #expect(watcherDrift.message?.contains(NeovimAdapter.backgroundAwareWatcherDirective) == true)
  }

  @Test
  func importedNeovimPreflightRequiresPinnedSourceControlledRenderer() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let neovimDirectory = root.appending(path: "nvim", directoryHint: .isDirectory)
    let plugins = neovimDirectory.appending(path: "lua/plugins", directoryHint: .isDirectory)
    let macarchy = neovimDirectory.appending(path: "lua/macarchy", directoryHint: .isDirectory)
    let colors = neovimDirectory.appending(path: "colors", directoryHint: .isDirectory)
    for directory in [plugins, macarchy, colors] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try writeBackgroundAwareWatcher(at: neovimDirectory)
    let configuration = plugins.appending(path: "colorscheme.lua")
    try "\(NeovimAdapter.integrationDirective)\n".write(
      to: configuration, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: macarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "current/\(NeovimAdapter.outputPath)")
    )
    let adapter = NeovimAdapter(
      root: root,
      configurationDirectoryURL: neovimDirectory,
      executableURL: NeovimAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    )
    let imported = packageWithoutNamedThemeMappings(try catppuccinPackage())

    #expect(throws: NeovimAdapterError.self) {
      try adapter.preflight(package: imported)
    }
    try """
    \(NeovimAdapter.integrationDirective)
    \(NeovimAdapter.aetherRepositoryDirective)
    \(NeovimAdapter.aetherBranchDirective)
    \(NeovimAdapter.aetherCommitDirective)

    """.write(to: configuration, atomically: true, encoding: .utf8)
    try "\(NeovimAdapter.importedColorschemeDirective)\n".write(
      to: colors.appending(path: "\(NeovimAdapter.importedColorscheme).lua"),
      atomically: true,
      encoding: .utf8
    )

    try adapter.preflight(package: imported)
    _ = try testActivator(root: root).activate(package: imported)
    try """
    \(NeovimAdapter.integrationDirective)
    \(NeovimAdapter.aetherRepositoryDirective)
    \(NeovimAdapter.aetherBranchDirective)

    """.write(to: configuration, atomically: true, encoding: .utf8)
    #expect(adapter.inspection(includeRuntimeChecks: true).status == .drifted)
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
      backgrounds: base.backgrounds,
      backgroundData: base.backgroundData,
      mappings: ["neovim": "theme\"; os.execute('unsafe')"]
    )
    #expect(throws: NeovimAdapterError.self) {
      _ = try NeovimAdapter.render(package: unsafe, generationID: "g-test")
    }
  }

  @Test
  func neovimImportedPaletteIsCompleteDataOnly() throws {
    let package = packageWithoutNamedThemeMappings(try catppuccinPackage())
    let rendered = try NeovimAdapter.render(package: package, generationID: "g-imported")
    let paletteKeys = [
      "accent", "cursor", "foreground", "background", "selection_foreground",
      "selection_background", "bg", "lighter_bg", "selection", "muted", "dark_fg", "fg",
      "light_fg", "bright_fg", "red", "yellow", "orange", "green", "cyan", "blue",
      "purple", "brown", "dark_bg", "darker_bg", "bright_red", "bright_yellow",
      "bright_green", "bright_cyan", "bright_blue", "bright_purple",
    ]

    #expect(rendered.contains("generation_id = \"g-imported\""))
    #expect(rendered.contains("colorscheme = \"\(NeovimAdapter.importedColorscheme)\""))
    for key in paletteKeys {
      #expect(rendered.contains("\(key) = \"#"))
    }
    #expect(rendered.components(separatedBy: " = \"#").count - 1 == paletteKeys.count)
    #expect(!rendered.contains("function"))
    #expect(!rendered.contains("require"))
  }

  private func writeBackgroundAwareWatcher(at neovimDirectory: URL) throws {
    let watcher = neovimDirectory.appending(path: "lua/config/macarchy-theme.lua")
    try FileManager.default.createDirectory(
      at: watcher.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "\(NeovimAdapter.backgroundAwareWatcherDirective)\n".write(
      to: watcher,
      atomically: true,
      encoding: .utf8
    )
  }

}
