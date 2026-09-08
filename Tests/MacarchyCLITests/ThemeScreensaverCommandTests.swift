import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeScreensaverCommandTests {
  @Test
  func preparesOnlyTheRequestedStateRootsImageWithoutActivatingATheme() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-saver-command-\(UUID().uuidString)")
    defer { removeRoot(root) }
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/kanagawa-wave"))
    let manifest = try ThemeActivator(root: root, faultInjector: { _ in }).activate(
      package: package)
    var command = try #require(
      Theme.parseAsRoot(["screensaver", "--state-root", root.path]) as? Theme.Screensaver)
    try await command.run()
    #expect(
      FileManager.default.fileExists(atPath: root.appending(path: "screensaver/wallpaper.png").path)
    )
    #expect(
      try ReconciliationStatusStore(root: root).activeManifest().generationID
        == manifest.generationID)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: "state/reconciliation.json").path))
  }

  @Test
  func savesActiveAndInactiveThemeChoicesWithoutActivatingWallpaperOrOtherAdapters() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-saver-\(UUID())")
    defer { removeRoot(root) }
    let repository = ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
    let active = try repository.package(id: "kanagawa-wave")
    let other = try repository.package(id: "catppuccin-mocha")
    let manifest = try ThemeActivator(root: root, faultInjector: { _ in }).activate(package: active)
    let runner = ThemeScreenSaverCommandRunner()
    let output = try await runner.execute(
      repository: repository, stateRoot: root, themeID: other.id,
      backgroundID: try #require(other.backgrounds.first?.id), followWallpaper: false)
    #expect(output.contains("when this theme is active"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "screensaver").path))
    let activeOutput = try await runner.execute(
      repository: repository, stateRoot: root, themeID: nil,
      backgroundID: try #require(active.backgrounds.last?.id), followWallpaper: false)
    #expect(activeOutput.contains("Theme and wallpaper unchanged"))
    let preferences = ScreenSaverPreferenceStore(root: root)
    #expect(try preferences.load().count == 2)
    let picker = try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: root)
    #expect(picker.item(id: active.id)?.screenSaverBackgroundID == active.backgrounds.last?.id)
    #expect(picker.item(id: other.id)?.screenSaverBackgroundID == other.backgrounds.first?.id)
    _ = try await runner.execute(
      repository: repository, stateRoot: root, themeID: active.id,
      backgroundID: nil, followWallpaper: true)
    #expect(try preferences.load().keys.sorted() == [other.id])
    #expect(
      try ReconciliationStatusStore(root: root).activeManifest().generationID
        == manifest.generationID)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: "state/reconciliation.json").path))
  }

  @Test
  func exportFailureRetainsExplicitSavedIntentForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-saver-\(UUID())")
    defer { removeRoot(root) }
    let repository = ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
    let package = try repository.package(id: "kanagawa-wave")
    _ = try ThemeActivator(root: root, faultInjector: { _ in }).activate(package: package)
    let folder = root.appending(path: "screensaver")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let foreign = folder.appending(path: "personal.png")
    try Data("personal".utf8).write(to: foreign)
    do {
      _ = try await ThemeScreenSaverCommandRunner().execute(
        repository: repository, stateRoot: root, themeID: nil,
        backgroundID: try #require(package.backgrounds.first?.id), followWallpaper: false)
      Issue.record("Foreign Photos contents must block publication")
    } catch {
      #expect(String(describing: error).contains("The selection was retained"))
    }
    #expect(try ScreenSaverPreferenceStore(root: root).load()[package.id] != nil)
    #expect(try Data(contentsOf: foreign) == Data("personal".utf8))
  }

  @Test
  func selectionFlagsRejectAmbiguousRequests() {
    #expect(throws: (any Error).self) {
      try Theme.Screensaver.parse(["--background", "default", "--follow-wallpaper"])
    }
    #expect(throws: (any Error).self) {
      try Theme.Screensaver.parse(["--theme", "kanagawa-wave"])
    }
  }

  private func removeRoot(_ root: URL) {
    if let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey])
    {
      for case let file as URL in files
      where (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      }
    }
    try? FileManager.default.removeItem(at: root)
  }
}
