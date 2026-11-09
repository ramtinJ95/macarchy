import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct ZedAdapterTests {
  @Test(arguments: ["catppuccin-mocha", "tokyo-night", "kanagawa-wave"])
  func rendererUsesSemanticAndTerminalPalettes(theme: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(theme)"))
    let data = Data(try ZedAdapter.render(package: package).utf8)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["$schema"] as? String == "https://zed.dev/schema/themes/v0.2.0.json")
    #expect(object["name"] as? String == "Macarchy")
    #expect(object["author"] as? String == "Macarchy")
    let themes = try #require(object["themes"] as? [[String: Any]])
    #expect(themes.count == 1)
    #expect(themes[0]["name"] as? String == "Macarchy")
    #expect(themes[0]["appearance"] as? String == package.appearance.rawValue)
    let style = try #require(themes[0]["style"] as? [String: Any])
    #expect(style["editor.background"] as? String == package.semantic.background.rawValue)
    #expect(style["terminal.background"] as? String == package.terminal.background.rawValue)
    #expect(style.keys.filter { $0.hasPrefix("terminal.ansi.") }.count == 16)
    #expect(style["terminal.ansi.bright_blue"] as? String == package.terminal.ansi[12].rawValue)
    #expect(!ConsumerCatalog.shared.defaultEnabledAdapterIDs.contains("zed"))
    #expect(RuntimeAdapterKind.zed.repaint == .live)
  }

  @Test(arguments: ["0.122.1", "0.122.2", "1.27.0", "unknown", "1.27", "1.27.0-dev"])
  func versionComesFromTheInstalledBundlesPlist(version: String) throws {
    try withTemporaryRoot(named: "zed-version") { root in
      let app = root.appending(path: "Zed.app")
      let info = app.appending(path: "Contents/Info.plist")
      try FileManager.default.createDirectory(
        at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
      try data.write(to: info)
      if ["0.122.2", "1.27.0"].contains(version) {
        #expect(
          try ZedAdapter.installedVersion(applicationURL: app)
            == version.split(separator: ".").compactMap { Int($0) })
      } else {
        #expect(throws: ZedAdapter.Failure.self) {
          try ZedAdapter.installedVersion(applicationURL: app)
        }
      }
    }
  }

  @Test func missingAppUnsupportedVersionAndDriftAreExplicit() async throws {
    try await withTemporaryRoot(named: "zed-status") { root in
      let app = root.appending(path: "absent.app")
      let absent = ZedAdapter(
        root: root, configurationDirectory: root,
        version: { try ZedAdapter.installedVersion(applicationURL: app) },
        validateOwnership: { _ in })
      #expect(absent.inspection().status == .failed)
      let absentResult = try await absent.reconciliation().run()
      #expect(absentResult.status == .failed)
      let old = ZedAdapter(
        root: root, configurationDirectory: root, version: { [0, 122, 1] },
        validateOwnership: { _ in })
      #expect(old.inspection().status == .unsupported)
      #expect(old.inspection().message?.contains("0.122.2") == true)
      let oldResult = try await old.reconciliation().run()
      #expect(oldResult.status == .unsupported)
      let drift = ZedAdapter(
        root: root, configurationDirectory: root, version: { [1, 27, 0] },
        validateOwnership: { _ in throw ZedAdapter.Failure.drift })
      #expect(drift.inspection().status == .drifted)
      let driftResult = try await drift.reconciliation().run()
      #expect(driftResult.status == .drifted)
    }
  }

  @Test func macOSPathsUseTheSelectedHomeNotXDG() {
    #expect(
      ThemeConsumerPaths.zedConfigurationDirectory(home: URL(filePath: "/selected/home"))
        == URL(filePath: "/selected/home/.config/zed"))
  }
}
