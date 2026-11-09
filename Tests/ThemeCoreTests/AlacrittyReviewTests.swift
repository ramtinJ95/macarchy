import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct AlacrittyReviewTests {
  @Test(arguments: ["direct", "imported", "legacy", "imported-legacy"])
  func reviewUsesEffectiveReloadFlagWithoutWriting(kind: String) throws {
    try withTemporaryRoot(named: "alacritty-review") { home in
      let source = home.appending(path: ".config/alacritty/alacritty.toml")
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      let original: String
      switch kind {
      case "direct": original = "[general]\nlive_config_reload = false\n"
      case "legacy": original = "live_config_reload = false\n[general]\nlive_config_reload = true\n"
      default:
        original =
          "[general]\nimport = ['base.toml']\n"
          + (kind == "imported-legacy" ? "live_config_reload = true\n" : "")
        let included =
          kind == "imported-legacy"
          ? "live_config_reload = false\n" : "[general]\nlive_config_reload = false\n"
        try Data(included.utf8).write(
          to: source.deletingLastPathComponent().appending(path: "base.toml"))
      }
      let edit = try AlacrittyImportEdit.adopting(
        Data(original.utf8), themePath: home.appending(path: AlacrittyAdapter.bridgePath).path)
      let managed = try edit.apply(to: Data(original.utf8))
      try managed.write(to: source)
      var paths = try AdapterContractTests.consumerPaths(root: home, adapterIDs: [])
      paths.piConfigurationDirectoryURL = home.appending(path: ".pi/agent")
      paths.alacrittyOwnedConfigurationURL = source
      paths.alacrittyOwnedImportEdit = edit
      let coordinator = ThemeActivationCoordinator(
        root: home, consumerPaths: paths,
        processRunner: ProcessRunner { request in
          #expect(request.arguments == ["--version"])
          return ProcessResult(terminationStatus: 0, output: "alacritty 0.17.0")
        },
        wallpaperControl: AdapterContractTests.wallpaperControl(),
        wallpaperSignal: try AdapterContractTests.wallpaperSignal(root: home),
        enabledAdapterIDs: [AlacrittyAdapter.id])
      let package = try BuiltInThemePackages.catppuccinMocha.get()
      let review = try coordinator.review(package: package)
      #expect(review.canApply)
      #expect(review.consumers.count == 1)
      #expect(review.consumers.first?.repaint == .nextInvocation)
      #expect(review.consumers.first?.preflight == .ready)
      #expect(try Data(contentsOf: source) == managed)
      for path in AlacrittyAdapter.statePaths {
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: path).path))
      }
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: "generations").path))
    }
  }
}
