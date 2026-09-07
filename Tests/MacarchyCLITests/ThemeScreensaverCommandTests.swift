import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeScreensaverCommandTests {
  @Test
  func preparesOnlyTheRequestedStateRootsImageWithoutActivatingATheme() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-saver-command-\(UUID().uuidString)")
    defer {
      if let files = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
      {
        for case let file as URL in files
        where (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
      }
      try? FileManager.default.removeItem(at: root)
    }
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/kanagawa-wave"))
    let manifest = try ThemeActivator(root: root, faultInjector: { _ in }).activate(
      package: package)
    var command = try Theme.parseAsRoot(["screensaver", "--state-root", root.path])
    try command.run()
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
}
