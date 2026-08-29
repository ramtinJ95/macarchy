import Foundation

enum ThemeSchema {
  static let version = 1

  static let themeKeys: [String: Set<String>] = [
    "": ["schema_version", "id", "display_name", "appearance"],
    "semantic": [
      "background", "surface", "overlay", "border", "text", "muted_text",
      "accent", "selection", "info", "success", "warning", "error",
    ],
    "terminal": [
      "foreground", "background", "cursor", "selection_foreground",
      "selection_background", "ansi",
    ],
    "backgrounds": ["id", "path", "source", "author", "license"],
  ]

  static let requiredThemePaths: Set<String> = Set(
    themeKeys.filter { $0.key != "backgrounds" }.flatMap { table, keys in
      keys.map { table.isEmpty ? $0 : "\(table).\($0)" }
    }
  )

  static func validateThemeShape(index: TOMLSourceIndex, file: URL) throws {
    if let table = index.tables.first(where: { $0.path == "wallpaper" }) {
      throw ThemeDiagnostic(
        location: .init(file: file, line: table.line, column: table.column),
        field: table.path,
        message:
          "Theme packages using [wallpaper] must be reinstalled to use [[backgrounds]]"
      )
    }
    try validateKnownTables(
      index: index, allowed: Set(themeKeys.keys).subtracting([""]), file: file)

    if let table = index.tables.first(where: { $0.path == "backgrounds" && !$0.isArray }) {
      throw ThemeDiagnostic(
        location: .init(file: file, line: table.line, column: table.column),
        field: table.path,
        message: "Background inventory entries must use [[backgrounds]] array tables"
      )
    }

    let backgroundCount = index.tables.count { $0.path == "backgrounds" }

    for field in index.fields {
      let parts = field.path.split(separator: ".", maxSplits: 1).map(String.init)
      let table = parts.count == 1 ? "" : parts[0]
      let key = parts.count == 1 ? parts[0] : parts[1]
      guard themeKeys[table]?.contains(key) == true else {
        throw ThemeDiagnostic(
          location: .init(file: file, line: field.line, column: field.column),
          field: field.path,
          message: "Unknown schema key"
        )
      }
    }

    let present = Set(index.fields.map(\.path))
    if let missing = requiredThemePaths.subtracting(present).sorted().first {
      throw ThemeDiagnostic(
        location: .init(file: file),
        field: missing,
        message: "Missing required schema key"
      )
    }

    for key in themeKeys["backgrounds", default: []].sorted() {
      let path = "backgrounds.\(key)"
      guard index.fields.count(where: { $0.path == path }) == backgroundCount else {
        throw ThemeDiagnostic(
          location: .init(file: file), field: path, message: "Missing required schema key")
      }
    }
  }

  static func validateMappingsShape(index: TOMLSourceIndex, file: URL) throws {
    try validateKnownTables(index: index, allowed: ["mappings"], file: file)
    for field in index.fields {
      if field.path == "schema_version" || field.path.hasPrefix("mappings.") {
        continue
      }
      throw ThemeDiagnostic(
        location: .init(file: file, line: field.line, column: field.column),
        field: field.path,
        message: "Unknown mappings key"
      )
    }
    guard index.fields.contains(where: { $0.path == "schema_version" }) else {
      throw ThemeDiagnostic(
        location: .init(file: file), field: "schema_version", message: "Missing required schema key"
      )
    }
  }

  static func isThemeID(_ value: String) -> Bool {
    guard !value.isEmpty, value.first?.isLetter == true, value == value.lowercased() else {
      return false
    }
    return value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
      && !value.hasSuffix("-")
      && !value.contains("--")
  }

  private static func validateKnownTables(
    index: TOMLSourceIndex,
    allowed: Set<String>,
    file: URL
  ) throws {
    if let table = index.tables.first(where: { !allowed.contains($0.path) }) {
      throw ThemeDiagnostic(
        location: .init(file: file, line: table.line, column: table.column),
        field: table.path,
        message: "Unknown schema table"
      )
    }
  }
}
