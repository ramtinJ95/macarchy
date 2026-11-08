import Foundation

package struct GeneratedHerdrTheme: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2

  package let schemaVersion: Int
  package let name: String
  package let custom: [String: String]

  init(name: String, custom: [String: String] = [:]) {
    schemaVersion = Self.currentSchemaVersion
    self.name = name
    self.custom = custom
  }

  package func validated() throws -> Self {
    guard [1, Self.currentSchemaVersion].contains(schemaVersion),
      HerdrAdapter.supportedThemes.contains(name),
      custom.isEmpty
        || Set(custom.keys)
          == (schemaVersion == 1 ? HerdrAdapter.legacyCustomKeySet : HerdrAdapter.customKeySet),
      custom.values.allSatisfy({ SRGBColor(rawValue: $0) != nil })
    else {
      throw HerdrAdapterError.invalidGeneratedTheme
    }
    return self
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case name, custom
  }
}

extension HerdrAdapter {
  static let supportedThemes = Set([
    "catppuccin", "tokyo-night", "kanagawa",
  ])
  static let legacyCustomKeys = [
    "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1",
    "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach",
  ]
  static let legacyCustomKeySet = Set(legacyCustomKeys)
  package static let customKeys =
    legacyCustomKeys + ["sidebar_bg", "active_row_bg", "selection_bg"]
  static let customKeySet = Set(customKeys)
  static let importedBaseTheme = "catppuccin"

  static func render(package: ThemePackage) throws -> String {
    let desired = try desiredTheme(for: package)
    let data = try prettyJSONDocument(desired)
    return String(decoding: data, as: UTF8.self)
  }

  package static func desiredTheme(root: URL) throws -> GeneratedHerdrTheme {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    let url = StateLayout(root: root).currentThemeArtifact(outputPath).resolvingSymlinksInPath()
    let data = try BoundedRegularFile.read(at: url).data
    return try decodeGeneratedTheme(
      data,
      rendererVersion: manifest.rendererVersions[id, default: 0]
    )
  }

  package static func desiredTheme(for package: ThemePackage) throws -> GeneratedHerdrTheme {
    if let mapping = package.mappings[id] {
      guard supportedThemes.contains(mapping) else {
        throw HerdrAdapterError.unsupportedTheme(mapping)
      }
      return GeneratedHerdrTheme(name: mapping)
    }

    let semantic = package.semantic
    let terminal = package.terminal
    return GeneratedHerdrTheme(
      name: importedBaseTheme,
      custom: [
        "accent": semantic.accent.rawValue,
        "panel_bg": semantic.background.rawValue,
        "sidebar_bg": semantic.background.rawValue,
        "active_row_bg": semantic.surface.rawValue,
        "selection_bg": semantic.selection.rawValue,
        "surface0": semantic.surface.rawValue,
        "surface1": semantic.overlay.rawValue,
        "surface_dim": semantic.background.rawValue,
        "overlay0": semantic.border.rawValue,
        "overlay1": semantic.mutedText.rawValue,
        "text": semantic.text.rawValue,
        "subtext0": semantic.mutedText.rawValue,
        "mauve": terminal.ansi[5].rawValue,
        "green": terminal.ansi[2].rawValue,
        "yellow": terminal.ansi[3].rawValue,
        "red": terminal.ansi[1].rawValue,
        "blue": terminal.ansi[4].rawValue,
        "teal": terminal.ansi[6].rawValue,
        "peach": semantic.warning.rawValue,
      ]
    )
  }

  package static func decodeGeneratedTheme(
    _ data: Data,
    rendererVersion: Int
  ) throws -> GeneratedHerdrTheme {
    if rendererVersion == 2 {
      guard
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        Self.supportedThemes.contains(value)
      else {
        throw HerdrAdapterError.invalidGeneratedTheme
      }
      return GeneratedHerdrTheme(name: value)
    }

    guard [3, Self.rendererVersion].contains(rendererVersion),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schema_version", "name", "custom"])
    else {
      throw HerdrAdapterError.invalidGeneratedTheme
    }
    let theme = try JSONDecoder().decode(GeneratedHerdrTheme.self, from: data).validated()
    guard
      theme.schemaVersion == (rendererVersion == 3 ? 1 : GeneratedHerdrTheme.currentSchemaVersion)
    else {
      throw HerdrAdapterError.invalidGeneratedTheme
    }
    return theme
  }
}
