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
  /// The `--seconds` contract shared by the JankyBorders preview and the lean helper it launches.
  package static let previewSeconds: ClosedRange<Double> = 1...300
  package static let defaultPreviewSeconds: Double = 30
  package static let previewSecondsRangeMessage = "--seconds must be between 1 and 300."

  package static let appearanceArguments = [
    "inactive_color=0x00000000", "background_color=0x00000000", "width=\(width)",
    "style=round", "hidpi=on", "ax_focus=off",
  ]

  package var arguments: [String] {
    ["active_color=0xff\(accent.dropFirst())"] + Self.appearanceArguments
  }

  package static func read(root: URL) throws -> Self {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    let theme = try manifest.normalizedTheme(root: root)
    return Self(
      generationID: manifest.generationID, themeID: manifest.themeID,
      accent: theme.semantic.accent.rawValue
    )
  }
}
