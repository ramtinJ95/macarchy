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

public struct ThemeBackground: Sendable {
  public let id: String
  public let path: String
  public let source: String
  public let author: String
  public let license: String
  public let format: ThemeBackgroundFormat
}

public enum ThemeBackgroundFormat: String, Codable, Sendable {
  case jpeg
  case png

  init?(pathExtension: String) {
    switch pathExtension.lowercased() {
    case "jpeg", "jpg": self = .jpeg
    case "png": self = .png
    default: return nil
    }
  }

  var mediaType: String {
    switch self {
    case .jpeg: "public.jpeg"
    case .png: "public.png"
    }
  }
}

public struct ThemePackage: Sendable {
  public let packageURL: URL
  public let schemaVersion: Int
  public let id: String
  public let displayName: String
  public let appearance: ThemeAppearance
  public let semantic: SemanticColors
  public let terminal: TerminalColors
  public let backgrounds: [ThemeBackground]
  let backgroundData: [String: Data]
  public let mappings: [String: String]

  package func background(id: String) -> ThemeBackground? {
    backgrounds.first { $0.id == id }
  }

  package func data(for background: ThemeBackground) -> Data {
    guard let data = backgroundData[background.id] else {
      preconditionFailure("Theme package is missing data for background '\(background.id)'")
    }
    return data
  }

  var firstBackgroundData: Data? {
    backgrounds.first.map(data(for:))
  }

  var defaultBackgroundData: Data {
    guard let data = firstBackgroundData else {
      preconditionFailure("Theme package has no default background")
    }
    return data
  }

  init(
    packageURL: URL,
    schemaVersion: Int,
    id: String,
    displayName: String,
    appearance: ThemeAppearance,
    semantic: SemanticColors,
    terminal: TerminalColors,
    backgrounds: [ThemeBackground],
    backgroundData: [String: Data],
    mappings: [String: String]
  ) {
    precondition(
      Set(backgrounds.map(\.id)).count == backgrounds.count,
      "Theme package background identifiers must be unique"
    )
    precondition(
      Set(backgroundData.keys) == Set(backgrounds.map(\.id)),
      "Theme package background data must exactly cover its inventory"
    )
    self.packageURL = packageURL
    self.schemaVersion = schemaVersion
    self.id = id
    self.displayName = displayName
    self.appearance = appearance
    self.semantic = semantic
    self.terminal = terminal
    self.backgrounds = backgrounds
    self.backgroundData = backgroundData
    self.mappings = mappings
  }
}

public struct GenerationBackground: Codable, Equatable, Sendable {
  public let id: String
  public let format: ThemeBackgroundFormat

  public init(id: String, format: ThemeBackgroundFormat) {
    self.id = id
    self.format = format
  }
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
