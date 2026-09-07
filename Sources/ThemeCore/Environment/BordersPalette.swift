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

  package static let appearanceArguments = [
    "inactive_color=0x00000000", "background_color=0x00000000", "width=6.0",
    "style=round", "hidpi=on", "ax_focus=off",
  ]

  package var arguments: [String] {
    ["active_color=0xff\(accent.dropFirst())"] + Self.appearanceArguments
  }

  package static func read(root: URL) throws -> Self {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let theme = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: BoundedRegularFile.read(
        at: root.appending(path: "generations/\(manifest.generationID)/theme.json")
      ).data
    )
    guard theme.generationID == manifest.generationID,
      theme.themeID == manifest.themeID,
      theme.schemaVersion == manifest.themeSchemaVersion
    else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "theme.json does not match the active manifest"
      )
    }
    return Self(
      generationID: manifest.generationID, themeID: manifest.themeID,
      accent: theme.semantic.accent.rawValue
    )
  }
}
