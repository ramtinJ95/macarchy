import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct HerdrAppAdapterTests {
  @Test(arguments: ["catppuccin-mocha", "tokyo-night", "kanagawa-wave"])
  func rendererUsesTerminalAndPanelColors(theme: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(theme)"))
    let data = Data(try HerdrAppAdapter.render(package: package).utf8)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["background"] as? String == package.terminal.background.rawValue)
    #expect(object["foreground"] as? String == package.terminal.foreground.rawValue)
    #expect(object["selection"] as? String == package.terminal.selectionBackground.rawValue)
    #expect(object["cursor"] as? String == package.terminal.cursor.rawValue)
    #expect(object["ansi"] as? [String] == package.terminal.ansi.map(\.rawValue))
    let colors = try #require(object["colors"] as? [String: String])
    #expect(colors["chrome"] == package.semantic.surface.rawValue)
    #expect(colors["canvas"] == package.semantic.background.rawValue)
    #expect(colors["accent"] == package.semantic.accent.rawValue)
    #expect(colors["foreground"] == package.semantic.text.rawValue)
    #expect(colors["working"] == package.semantic.warning.rawValue)
    #expect(colors["blocked"] == package.semantic.error.rawValue)
    #expect(colors["done"] == package.semantic.success.rawValue)
    #expect(!ConsumerCatalog.shared.defaultEnabledAdapterIDs.contains("herdr-app"))
    #expect(RuntimeAdapterKind.herdrApp.repaint == .live)
  }

  @Test(arguments: ["0.1.13", "0.1.14", "0.2.0", "unknown", "0.1", "0.1.14-dev"])
  func versionComesFromTheInstalledBundle(version: String) throws {
    try withTemporaryRoot(named: "herdr-app-version") { root in
      let app = root.appending(path: "Herdr.app")
      let info = app.appending(path: "Contents/Info.plist")
      try FileManager.default.createDirectory(
        at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0
      ).write(to: info)
      if ["0.1.14", "0.2.0"].contains(version) {
        #expect(
          try HerdrAppAdapter.installedVersion(applicationURL: app)
            == version.split(separator: ".").compactMap { Int($0) })
      } else {
        #expect(throws: HerdrAppAdapter.Failure.self) {
          try HerdrAppAdapter.installedVersion(applicationURL: app)
        }
      }
    }
  }

  @Test func missingUnsupportedAndDriftAreExplicit() async throws {
    try await withTemporaryRoot(named: "herdr-app-status") { root in
      let missing = HerdrAppAdapter(
        root: root, configurationDirectory: root,
        version: {
          try HerdrAppAdapter.installedVersion(applicationURL: root.appending(path: "absent"))
        },
        validateOwnership: { _ in })
      #expect(missing.inspection().status == .failed)
      let missingResult = try await missing.reconciliation().run()
      #expect(missingResult.status == .failed)
      let old = HerdrAppAdapter(
        root: root, configurationDirectory: root, version: { [0, 1, 13] },
        validateOwnership: { _ in })
      #expect(old.inspection().status == .unsupported)
      let oldResult = try await old.reconciliation().run()
      #expect(oldResult.status == .unsupported)
      let drift = HerdrAppAdapter(
        root: root, configurationDirectory: root, version: { [0, 1, 14] },
        validateOwnership: { _ in throw HerdrAppAdapter.Failure.drift })
      #expect(drift.inspection().status == .drifted)
      let driftResult = try await drift.reconciliation().run()
      #expect(driftResult.status == .drifted)
    }
  }

  @Test func aDifferentAppHomeIsRefusedInsteadOfWritingTheWrongDirectory() throws {
    let directory = URL(filePath: "/home/test/.config/herdr-app")
    try HerdrAppAdapter.requireConfigurationHome(directory, environment: [:])
    try HerdrAppAdapter.requireConfigurationHome(
      directory, environment: ["HERDR_APP_HOME": directory.path])
    #expect(throws: HerdrAppAdapter.Failure.self) {
      try HerdrAppAdapter.requireConfigurationHome(
        directory, environment: ["HERDR_APP_HOME": "/other"])
    }
  }

  @Test func appAndTerminalHerdrHaveSeparateIdentitiesAndHomes() {
    #expect(HerdrAppAdapter.id != HerdrAdapter.id)
    #expect(
      ThemeConsumerPaths.herdrAppConfigurationDirectory(home: URL(filePath: "/selected/home"))
        == URL(filePath: "/selected/home/.config/herdr-app"))
  }
}
