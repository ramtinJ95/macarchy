import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeGetCommandTests {
  @Test
  func getReturnsTheActiveSlackImportPayloadExactly() throws {
    let stateRoot = temporaryStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let package = try ThemePackageLoader().load(packageURL: catppuccinPackageURL())
    _ = try ThemeActivator(root: stateRoot).activate(package: package)

    let payload = try ManualThemePayloadStore(root: stateRoot).payload(targetID: "slack")

    #expect(
      payload
        == "#1e1e2e,#cba6f7,#a6e3a1,#f38ba8\n"
    )
  }

  @Test
  func getRejectsUnknownTargetsBeforeReadingCanonicalState() {
    let store = ManualThemePayloadStore(root: URL(filePath: "/missing-state"))

    #expect(
      throws: ManualThemePayloadError.unsupportedTarget("spotify", available: ["slack"])
    ) {
      _ = try store.payload(targetID: "spotify")
    }
  }

  @Test
  func getRequiresAnActiveTheme() {
    let stateRoot = temporaryStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    #expect(throws: ManualThemePayloadError.noActiveTheme) {
      _ = try ManualThemePayloadStore(root: stateRoot).payload(targetID: "slack")
    }
  }
}

private func temporaryStateRoot() -> URL {
  FileManager.default.temporaryDirectory.appending(
    path: "macarchy-theme-get-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
}

private func catppuccinPackageURL() -> URL {
  repositoryRoot
    .appending(path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
}
