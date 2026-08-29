import Foundation

struct ThemeDocument: Decodable {
  let schemaVersion: Int
  let id: String
  let displayName: String
  let appearance: String
  let semantic: RawSemanticColors
  let terminal: RawTerminalColors
  let backgrounds: [RawThemeBackground]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case displayName = "display_name"
    case appearance, semantic, terminal, backgrounds
  }
}

struct RawThemeBackground: Decodable {
  let id: String
  let path: String
  let source: String
  let author: String
  let license: String
}

struct RawSemanticColors: Decodable {
  let background: String
  let surface: String
  let overlay: String
  let border: String
  let text: String
  let mutedText: String
  let accent: String
  let selection: String
  let info: String
  let success: String
  let warning: String
  let error: String

  enum CodingKeys: String, CodingKey {
    case background, surface, overlay, border, text, accent, selection
    case mutedText = "muted_text"
    case info, success, warning, error
  }
}

struct RawTerminalColors: Decodable {
  let foreground: String
  let background: String
  let cursor: String
  let selectionForeground: String
  let selectionBackground: String
  let ansi: [String]

  enum CodingKeys: String, CodingKey {
    case foreground, background, cursor, ansi
    case selectionForeground = "selection_foreground"
    case selectionBackground = "selection_background"
  }
}

struct MappingsDocument: Decodable {
  let schemaVersion: Int
  let mappings: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case mappings
  }
}
