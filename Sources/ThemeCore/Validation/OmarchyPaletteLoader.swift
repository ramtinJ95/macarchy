import Darwin
import Foundation
import TOMLDecoder

public struct OmarchyPaletteCompatibility: Codable, Sendable {
  public let usedLegacyANSI: Bool
  public let usedLegacyAliases: Bool
  public let derivedFields: [String]
  public let ignoredFields: [String]
  public let overriddenFields: [String]

  enum CodingKeys: String, CodingKey {
    case usedLegacyANSI = "used_legacy_ansi"
    case usedLegacyAliases = "used_legacy_aliases"
    case derivedFields = "derived_fields"
    case ignoredFields = "ignored_fields"
    case overriddenFields = "overridden_fields"
  }
}

public struct OmarchyPaletteConversion: Codable, Sendable {
  public let appearance: ThemeAppearance
  public let semantic: SemanticColors
  public let terminal: TerminalColors
  public let compatibility: OmarchyPaletteCompatibility
}

public struct OmarchyPaletteLoader: Sendable {
  private static let legacyPaletteAliases = [
    "background": "bg",
    "lighter_background": "lighter_bg",
    "foreground": "fg",
    "dark_foreground": "dark_fg",
    "bright_foreground": "bright_fg",
  ]

  private static let legacyNamedAliases = [
    "magenta": "purple",
    "bright_magenta": "bright_purple",
  ]

  private static let legacyANSIAliases = [
    "red": "color1",
    "green": "color2",
    "yellow": "color3",
    "blue": "color4",
    "magenta": "color5",
    "cyan": "color6",
    "bright_red": "color9",
    "bright_green": "color10",
    "bright_yellow": "color11",
    "bright_blue": "color12",
    "bright_magenta": "color13",
    "bright_cyan": "color14",
  ]

  private static let ansiFields = (0...15).map { "color\($0)" }

  private static let ansiSourceFields = [
    "background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
    "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue",
    "bright_magenta", "bright_cyan", "bright_foreground",
  ]

  private static let resolvedFields: Set<String> = {
    var fields: Set<String> = [
      "mode", "theme_type", "accent", "selection", "muted",
      "background", "lighter_background", "foreground", "dark_foreground",
      "bright_foreground", "red", "green", "yellow", "blue", "magenta", "cyan",
      "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta",
      "bright_cyan", "cursor", "selection_foreground", "selection_background",
    ]
    fields.formUnion(legacyPaletteAliases.values)
    fields.formUnion(legacyNamedAliases.values)
    fields.formUnion(ansiFields)
    return fields
  }()

  private static let outputFields: Set<String> = {
    var fields: Set<String> = [
      "background", "lighter_background", "selection", "muted", "dark_foreground",
      "foreground", "accent", "cyan", "green", "yellow", "red", "cursor",
      "selection_foreground", "selection_background",
    ]
    fields.formUnion(ansiFields)
    return fields
  }()

  private struct Document: Decodable {
    let values: [String: String]

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: FieldKey.self)
      var values: [String: String] = [:]
      for key in container.allKeys {
        guard OmarchyPaletteLoader.resolvedFields.contains(key.stringValue) else { continue }
        values[key.stringValue] = try container.decode(String.self, forKey: key)
      }
      self.values = values
    }
  }

  private struct FieldKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      return nil
    }
  }

  public init() {}

  public func load(colorsFile: URL) throws -> OmarchyPaletteConversion {
    let text = try read(colorsFile)
    let index = try TOMLSourceIndex(
      text: text, file: colorsFile, syntaxRole: "Omarchy colors")
    try validateShape(index: index, file: colorsFile)
    let source = try decode(text, file: colorsFile)

    var colors = source
    var origins = Dictionary(uniqueKeysWithValues: source.keys.map { ($0, $0) })
    var derivedFields: Set<String> = []

    for (canonical, legacy) in Self.legacyPaletteAliases {
      Self.derive(
        &colors, origins: &origins, canonical, from: [legacy], tracking: &derivedFields)
    }

    Self.derive(
      &colors, origins: &origins, "background", from: ["color0"], tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "foreground", from: ["color7"], tracking: &derivedFields)

    var overriddenFields: Set<String> = []
    for (canonical, legacy) in Self.legacyPaletteAliases {
      if !Self.isMissing(source[canonical]), !Self.isMissing(source[legacy]) {
        overriddenFields.insert(legacy)
      }
    }
    for (canonical, legacy) in Self.legacyNamedAliases {
      if !Self.isMissing(source[canonical]), !Self.isMissing(source[legacy]) {
        overriddenFields.insert(legacy)
      }
    }
    if !Self.isMissing(source["background"]), !Self.isMissing(source["color0"]) {
      overriddenFields.insert("color0")
    }
    if !Self.isMissing(source["foreground"]), !Self.isMissing(source["color7"]) {
      overriddenFields.insert("color7")
    }
    if let background = Self.value(colors, "background") {
      if Self.isMissing(source["color0"]) { derivedFields.insert("color0") }
      colors["color0"] = background
      origins["color0"] = origins["background"]
    }
    if let foreground = Self.value(colors, "foreground") {
      if Self.isMissing(source["color7"]) { derivedFields.insert("color7") }
      colors["color7"] = foreground
      origins["color7"] = origins["foreground"]
    }

    for (canonical, legacy) in Self.legacyANSIAliases {
      Self.derive(
        &colors, origins: &origins, canonical, from: [legacy], tracking: &derivedFields)
    }
    for (canonical, legacy) in Self.legacyNamedAliases {
      Self.derive(
        &colors, origins: &origins, canonical, from: [legacy], tracking: &derivedFields)
    }

    Self.derive(
      &colors, origins: &origins, "bright_foreground", from: ["color15", "foreground"],
      tracking: &derivedFields)
    if !Self.isMissing(source["cursor"]) { overriddenFields.insert("cursor") }
    colors["cursor"] = Self.value(colors, "bright_foreground")
    origins["cursor"] = origins["bright_foreground"]
    derivedFields.insert("cursor")

    Self.derive(
      &colors, origins: &origins, "lighter_background", from: ["color0", "background"],
      tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "dark_foreground", from: ["color8", "foreground"],
      tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "muted", from: ["color8", "dark_foreground"],
      tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "selection",
      from: ["selection_background", "color8", "color0", "background"],
      tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "selection_background", from: ["selection"],
      tracking: &derivedFields)
    Self.derive(
      &colors, origins: &origins, "selection_foreground", from: ["bright_foreground"],
      tracking: &derivedFields)

    for field in ["red", "green", "yellow", "cyan", "blue", "magenta"] {
      let bright = "bright_\(field)"
      if Self.isMissing(colors[bright]) {
        let base = try color(
          field, colors: colors, origins: origins, index: index, file: colorsFile)
        colors[bright] = Self.mix(base, with: SRGBColor(rawValue: "#ffffff")!, amount: 0.2)
        origins[bright] = origins[field]
        derivedFields.insert(bright)
      }
    }

    for (offset, field) in Self.ansiSourceFields.enumerated() {
      Self.derive(
        &colors, origins: &origins, "color\(offset)", from: [field], tracking: &derivedFields)
    }

    let outputOrigins = Self.outputFields.compactMap { origins[$0] }
    var legacyAliasFields = Set(Self.legacyPaletteAliases.values)
    legacyAliasFields.formUnion(Self.legacyNamedAliases.values)
    let usedLegacyANSI = outputOrigins.contains { Self.ansiFields.contains($0) }
    let usedLegacyAliases =
      outputOrigins.contains { legacyAliasFields.contains($0) }
      || (Self.isMissing(source["mode"]) && !Self.isMissing(source["theme_type"]))

    let appearance = try resolveAppearance(
      colors: colors, origins: origins, derivedFields: &derivedFields, index: index,
      colorsFile: colorsFile)
    let semantic = try SemanticColors(
      background: color(
        "background", colors: colors, origins: origins, index: index, file: colorsFile),
      surface: color(
        "lighter_background", colors: colors, origins: origins, index: index,
        file: colorsFile),
      overlay: color(
        "selection", colors: colors, origins: origins, index: index, file: colorsFile),
      border: color("muted", colors: colors, origins: origins, index: index, file: colorsFile),
      text: color(
        "foreground", colors: colors, origins: origins, index: index, file: colorsFile),
      mutedText: color(
        "dark_foreground", colors: colors, origins: origins, index: index, file: colorsFile),
      accent: color(
        "accent", colors: colors, origins: origins, index: index, file: colorsFile),
      selection: color(
        "selection", colors: colors, origins: origins, index: index, file: colorsFile),
      info: color("cyan", colors: colors, origins: origins, index: index, file: colorsFile),
      success: color(
        "green", colors: colors, origins: origins, index: index, file: colorsFile),
      warning: color(
        "yellow", colors: colors, origins: origins, index: index, file: colorsFile),
      error: color("red", colors: colors, origins: origins, index: index, file: colorsFile)
    )
    let terminal = try TerminalColors(
      foreground: color(
        "foreground", colors: colors, origins: origins, index: index, file: colorsFile),
      background: color(
        "background", colors: colors, origins: origins, index: index, file: colorsFile),
      cursor: color(
        "cursor", colors: colors, origins: origins, index: index, file: colorsFile),
      selectionForeground: color(
        "selection_foreground", colors: colors, origins: origins, index: index,
        file: colorsFile),
      selectionBackground: color(
        "selection_background", colors: colors, origins: origins, index: index,
        file: colorsFile),
      ansi: try Self.ansiFields.map {
        try color($0, colors: colors, origins: origins, index: index, file: colorsFile)
      }
    )

    return OmarchyPaletteConversion(
      appearance: appearance,
      semantic: semantic,
      terminal: terminal,
      compatibility: OmarchyPaletteCompatibility(
        usedLegacyANSI: usedLegacyANSI,
        usedLegacyAliases: usedLegacyAliases,
        derivedFields: derivedFields.sorted(),
        ignoredFields: index.fields.map(\.path).filter { !Self.resolvedFields.contains($0) }
          .sorted(),
        overriddenFields: overriddenFields.sorted()
      )
    )
  }

  private func read(_ file: URL) throws -> String {
    do {
      let data = try BoundedRegularFile.read(at: file).data
      guard let text = String(data: data, encoding: .utf8) else {
        throw ThemeDiagnostic(
          location: .init(file: file), message: "Omarchy colors must be valid UTF-8")
      }
      return text
    } catch let diagnostic as ThemeDiagnostic {
      throw diagnostic
    } catch {
      throw ThemeDiagnostic(
        location: .init(file: file), message: "Cannot read Omarchy colors: \(error)")
    }
  }

  private func validateShape(index: TOMLSourceIndex, file: URL) throws {
    if let table = index.tables.first {
      throw ThemeDiagnostic(
        location: .init(file: file, line: table.line, column: table.column),
        field: table.path,
        message: "Omarchy colors must contain only top-level fields"
      )
    }

    var seen: Set<String> = []
    if let duplicate = index.fields.first(where: { !seen.insert($0.path).inserted }) {
      throw ThemeDiagnostic(
        location: .init(file: file, line: duplicate.line, column: duplicate.column),
        field: duplicate.path,
        message: "Duplicate Omarchy color field"
      )
    }
  }

  private func decode(_ text: String, file: URL) throws -> [String: String] {
    do {
      return try TOMLDecoder().decode(Document.self, from: text).values
    } catch {
      let description = String(describing: error)
      throw ThemeDiagnostic(
        location: .init(file: file, line: parseLine(from: description)),
        message: "Invalid Omarchy colors TOML: \(description)"
      )
    }
  }

  private func parseLine(from description: String) -> Int? {
    guard let marker = description.range(of: "(Line ") else { return nil }
    let suffix = description[marker.upperBound...]
    guard let closing = suffix.firstIndex(of: ")") else { return nil }
    return Int(suffix[..<closing])
  }

  private func resolveAppearance(
    colors: [String: String],
    origins: [String: String],
    derivedFields: inout Set<String>,
    index: TOMLSourceIndex,
    colorsFile: URL
  ) throws -> ThemeAppearance {
    if let mode = Self.value(colors, "mode") ?? Self.value(colors, "theme_type") {
      guard let appearance = ThemeAppearance(rawValue: mode) else {
        let field = Self.value(colors, "mode") == nil ? "theme_type" : "mode"
        throw ThemeDiagnostic(
          location: index.location(for: field, file: colorsFile), field: field,
          message: "Omarchy mode must be 'dark' or 'light'; found '\(mode)'"
        )
      }
      if Self.value(colors, "mode") == nil { derivedFields.insert("mode") }
      return appearance
    }

    derivedFields.insert("mode")
    if try hasLightModeMarker(beside: colorsFile) { return .light }

    let background = try color(
      "background", colors: colors, origins: origins, index: index, file: colorsFile)
    let bytes = Self.components(background)
    return bytes.reduce(0, +) > 382 ? .light : .dark
  }

  private func hasLightModeMarker(beside colorsFile: URL) throws -> Bool {
    let marker = colorsFile.deletingLastPathComponent().appending(path: "light.mode")
    do {
      _ = try BoundedRegularFile.read(at: marker)
      return true
    } catch BoundedRegularFileError.system(_, let code) where code == ENOENT {
      return false
    } catch {
      throw ThemeDiagnostic(
        location: .init(file: marker), message: "Cannot read Omarchy light-mode marker: \(error)")
    }
  }

  private func color(
    _ field: String,
    colors: [String: String],
    origins: [String: String],
    index: TOMLSourceIndex,
    file: URL
  ) throws -> SRGBColor {
    guard let value = Self.value(colors, field) else {
      throw ThemeDiagnostic(
        location: .init(file: file), field: field,
        message: "Omarchy palette cannot resolve required color"
      )
    }
    let sourceField = origins[field] ?? field
    guard let color = SRGBColor(rawValue: value) else {
      throw ThemeDiagnostic(
        location: index.location(for: sourceField, file: file), field: sourceField,
        message: "Color must use sRGB #RRGGBB form; found '\(value)'"
      )
    }
    return color
  }

  private static func mix(_ start: SRGBColor, with end: SRGBColor, amount: Double) -> String {
    let startBytes = components(start)
    let endBytes = components(end)
    let mixed = zip(startBytes, endBytes).map { start, end in
      Int((Double(start) * (1 - amount) + Double(end) * amount).rounded())
    }
    return String(format: "#%02x%02x%02x", mixed[0], mixed[1], mixed[2])
  }

  private static func components(_ color: SRGBColor) -> [Int] {
    let rgb = Int(color.rawValue.dropFirst(), radix: 16)!
    return [(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff]
  }

  private static func derive(
    _ colors: inout [String: String],
    origins: inout [String: String],
    _ target: String,
    from fallbacks: [String],
    tracking derivedFields: inout Set<String>
  ) {
    guard isMissing(colors[target]) else { return }
    for fallback in fallbacks {
      if let resolved = value(colors, fallback) {
        colors[target] = resolved
        origins[target] = origins[fallback] ?? fallback
        derivedFields.insert(target)
        return
      }
    }
  }

  private static func value(_ colors: [String: String], _ field: String) -> String? {
    guard let value = colors[field], !value.isEmpty else { return nil }
    return value
  }

  private static func isMissing(_ value: String?) -> Bool {
    value?.isEmpty != false
  }
}
