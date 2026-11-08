import AppKit
import Foundation
import ThemeCore

/// The active theme, or the bundled catppuccin-mocha before any theme is active.
func loadPopupTheme(
  stateRoot: URL,
  bundledThemesRoot: URL
) throws -> NormalizedTheme {
  do {
    return try ThemeGenerationReader(root: stateRoot).activeManifest()
      .normalizedTheme(root: stateRoot)
  } catch ReconciliationStatusError.noActiveGeneration {
    let package = try ThemePackageLoader().load(
      packageURL: bundledThemesRoot.appending(
        path: "catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    return NormalizedTheme(package: package, generationID: "popup-default")
  }
}

extension SRGBColor {
  @MainActor
  var nsColor: NSColor {
    let (red, green, blue) = components
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}
