import Foundation

public enum ThemeAppearance: String, Codable, Sendable {
  case dark
  case light
}

public struct SRGBColor: RawRepresentable, Codable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue.count == 7, rawValue.first == "#" else { return nil }
    let digits = rawValue.dropFirst()
    guard digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
    self.rawValue = rawValue.lowercased()
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let color = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an sRGB color in #RRGGBB form"
      )
    }
    self = color
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct SemanticColors: Codable, Sendable {
  public let background: SRGBColor
  public let surface: SRGBColor
  public let overlay: SRGBColor
  public let border: SRGBColor
  public let text: SRGBColor
  public let mutedText: SRGBColor
  public let accent: SRGBColor
  public let selection: SRGBColor
  public let info: SRGBColor
  public let success: SRGBColor
  public let warning: SRGBColor
  public let error: SRGBColor

  enum CodingKeys: String, CodingKey {
    case background, surface, overlay, border, text, accent, selection
    case mutedText = "muted_text"
    case info, success, warning, error
  }
}

public struct TerminalColors: Codable, Sendable {
  public let foreground: SRGBColor
  public let background: SRGBColor
  public let cursor: SRGBColor
  public let selectionForeground: SRGBColor
  public let selectionBackground: SRGBColor
  public let ansi: [SRGBColor]

  enum CodingKeys: String, CodingKey {
    case foreground, background, cursor, ansi
    case selectionForeground = "selection_foreground"
    case selectionBackground = "selection_background"
  }
}

public struct ThemeWallpaper: Codable, Sendable {
  public let path: String
  public let source: String
  public let author: String
  public let license: String
}

public struct ThemePackage: Sendable {
  public let packageURL: URL
  public let schemaVersion: Int
  public let id: String
  public let displayName: String
  public let appearance: ThemeAppearance
  public let semantic: SemanticColors
  public let terminal: TerminalColors
  public let wallpaper: ThemeWallpaper
  public let mappings: [String: String]

}

public struct NormalizedTheme: Codable, Sendable {
  public let schemaVersion: Int
  public let generationID: String
  public let themeID: String
  public let appearance: ThemeAppearance
  public let semantic: SemanticColors
  public let terminal: TerminalColors

  public init(package: ThemePackage, generationID: String) {
    schemaVersion = package.schemaVersion
    self.generationID = generationID
    themeID = package.id
    appearance = package.appearance
    semantic = package.semantic
    terminal = package.terminal
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case themeID = "theme_id"
    case appearance, semantic, terminal
  }
}
