import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct AdapterContractTests {}

extension AdapterContractTests {
  func catppuccinPackage() throws -> ThemePackage {
    try BuiltInThemePackages.catppuccinMocha.get()
  }

  func tokyoNightPackage() throws -> ThemePackage {
    try BuiltInThemePackages.tokyoNight.get()
  }

  func packageWithoutNamedThemeMappings(_ base: ThemePackage) -> ThemePackage {
    ThemePackage(
      packageURL: base.packageURL,
      schemaVersion: base.schemaVersion,
      id: base.id,
      displayName: base.displayName,
      appearance: base.appearance,
      semantic: base.semantic,
      terminal: base.terminal,
      backgrounds: base.backgrounds,
      backgroundData: base.backgroundData,
      mappings: [:]
    )
  }

  func testActivator(root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  func temporaryDirectory() throws -> URL {
    try makeTemporaryDirectory(named: "macarchy-adapter-tests")
  }

  static func appearanceScript(dark: Bool) -> String {
    "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
  }

  static func appearanceRequest(dark: Bool) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/osascript"),
      arguments: ["-e", appearanceScript(dark: dark)],
      timeout: 2
    )
  }

  static func wallpaperControl(
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

  static func wallpaperSignal(root: URL) throws -> YabaiWallpaperSignal {
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

  static func sketchyBarConfiguration(root: URL) throws -> URL {
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

  /// Writes `root/kitty.conf` including the managed Kitty bridge and returns its URL.
  @discardableResult
  static func kittyConfiguration(root: URL) throws -> URL {
    let configuration = root.appending(path: "kitty.conf")
    try "include \(root.path)/state/adapters/kitty.conf\n".write(
      to: configuration, atomically: true, encoding: .utf8)
    return configuration
  }

  static func consumerPaths(
    root: URL,
    kittyConfigurationURL: URL? = nil,
    sketchyBarConfigurationURL: URL? = nil,
    adapterIDs: Set<String> = ConsumerCatalog.shared.defaultEnabledAdapterIDs
  ) throws -> ThemeConsumerPaths {
    for adapterID in adapterIDs.sorted() {
      switch adapterID {
      case "kitty":
        if kittyConfigurationURL == nil {
          try kittyConfiguration(root: root)
        }
      case "sketchybar":
        if sketchyBarConfigurationURL == nil {
          _ = try sketchyBarConfiguration(root: root)
        }
      case "macos-appearance", "wallpaper":
        // Appearance and wallpaper have no consumer configuration here.
        break
      default:
        guard
          try ConsumerConfigurationFixture.write(
            adapterID, root: root, stateRoot: root, neovim: .aether)
        else {
          throw AdapterSelectionError.unknown(adapterID)
        }
      }
    }

    // Even unconfigured consumers stay inside this test root, never the real home.
    return ConsumerConfigurationFixture.paths(
      root: root,
      kittyConfigurationURL: kittyConfigurationURL ?? root.appending(path: "kitty.conf"),
      sketchyBarConfigurationURL: sketchyBarConfigurationURL
        ?? root.appending(path: "sketchybar/sketchybarrc")
    )
  }

  func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReconciliationTestError.timedOut
  }

}

enum ReconciliationTestError: Error {
  case expectedCommittedError
  case expectedCurrentStatus
  case expectedFailure
  case expectedInterruption
  case timedOut
}
