import Foundation

/// Validated declarations for browsing, not an activation-ready package. Image
/// bytes are deliberately absent; ThemePackage retains its complete-data invariant.
package struct ThemePackageMetadata: Sendable {
  package let packageURL: URL
  package let schemaVersion: Int
  package let id: String
  package let displayName: String
  package let appearance: ThemeAppearance
  package let semantic: SemanticColors
  package let terminal: TerminalColors
  package let backgrounds: [ThemeBackground]
  package let mappings: [String: String]

  package func background(id: String) -> ThemeBackground? {
    backgrounds.first { $0.id == id }
  }

  package func addingPersonalBackgrounds(_ additions: [ThemeBackground]) throws -> Self {
    let collisions = Set(backgrounds.map(\.id)).intersection(additions.map(\.id))
    guard collisions.isEmpty else {
      throw MacarchyConfigurationError.invalid(
        "personal background identifiers collide with package backgrounds: "
          + collisions.sorted().joined(separator: ", "))
    }
    return Self(
      packageURL: packageURL, schemaVersion: schemaVersion, id: id,
      displayName: displayName, appearance: appearance, semantic: semantic,
      terminal: terminal, backgrounds: backgrounds + additions, mappings: mappings)
  }

  package func backgroundData(id: String) throws -> Data {
    guard let background = background(id: id) else {
      throw ThemeDiagnostic(
        location: .init(file: packageURL), field: "backgrounds.id",
        message: "Unknown background '\(id)' for theme '\(self.id)'")
    }
    if background.origin == .personal {
      return try ThemeImageAsset.load(
        at: URL(filePath: background.path).resolvingSymlinksInPath().standardizedFileURL,
        format: background.format)
    }
    return try ThemePackageLoader().loadBackground(background, packageURL: packageURL)
  }
}

extension ThemePackage {
  package var metadata: ThemePackageMetadata {
    ThemePackageMetadata(
      packageURL: packageURL, schemaVersion: schemaVersion, id: id,
      displayName: displayName, appearance: appearance, semantic: semantic,
      terminal: terminal, backgrounds: backgrounds, mappings: mappings)
  }
}
