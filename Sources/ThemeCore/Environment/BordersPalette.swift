import Foundation

/// One appearance contract for the bounded preview, native startup and live adapter.
package struct BordersPalette: Equatable, Sendable {
  package let generationID: String
  package let themeID: String
  package let accent: String

  package init(generationID: String, themeID: String, accent: String) {
    self.generationID = generationID
    self.themeID = themeID
    self.accent = accent
  }

  package static let width = 6.0
  /// Shared by the JankyBorders preview and the lean helper it launches.
  package static let previewSeconds: ClosedRange<Double> = 1...300

  package static let appearanceArguments = [
    "inactive_color=0x00000000", "background_color=0x00000000", "width=\(width)",
    "style=round", "hidpi=on", "ax_focus=off",
  ]

  package var arguments: [String] {
    ["active_color=0xff\(accent.dropFirst())"] + Self.appearanceArguments
  }

  package static func read(root: URL) throws -> Self {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let theme = try manifest.normalizedTheme(root: root)
    return Self(
      generationID: manifest.generationID, themeID: manifest.themeID,
      accent: theme.semantic.accent.rawValue
    )
  }
}
