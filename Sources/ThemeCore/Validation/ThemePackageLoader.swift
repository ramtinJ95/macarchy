import Foundation
import ImageIO
import TOMLDecoder

enum WallpaperAssetError: Error, CustomStringConvertible, Sendable {
  case invalidPNG

  var description: String { "file cannot be decoded as PNG" }
}

struct WallpaperAsset {
  static let maximumSize = 32 * 1_048_576

  static func load(at url: URL) throws -> Data {
    let data = try BoundedRegularFile.read(at: url, maximumSize: maximumSize).data
    let source = CGImageSourceCreateWithData(data as CFData, nil)
    let imageType = source.flatMap(CGImageSourceGetType) as String?
    guard source.map(CGImageSourceGetCount) ?? 0 > 0, imageType == "public.png" else {
      throw WallpaperAssetError.invalidPNG
    }
    return data
  }
}

public struct ThemePackageLoader: Sendable {
  public init() {}

  public func load(packageURL: URL) throws -> ThemePackage {
    let themeFile = packageURL.appending(path: "theme.toml")
    let mappingsFile = packageURL.appending(path: "mappings.toml")
    let themeText = try readText(themeFile, role: "theme manifest")
    let mappingsText = try readText(mappingsFile, role: "mappings manifest")

    let themeIndex = try TOMLSourceIndex(text: themeText, file: themeFile)
    let mappingsIndex = try TOMLSourceIndex(text: mappingsText, file: mappingsFile)
    try ThemeSchema.validateThemeShape(index: themeIndex, file: themeFile)
    try ThemeSchema.validateMappingsShape(index: mappingsIndex, file: mappingsFile)

    let theme: ThemeDocument = try decode(ThemeDocument.self, text: themeText, file: themeFile)
    let mappings: MappingsDocument = try decode(
      MappingsDocument.self, text: mappingsText, file: mappingsFile)

    let validated = try validate(theme: theme, themeIndex: themeIndex, themeFile: themeFile)
    try validate(mappings: mappings, index: mappingsIndex, file: mappingsFile)
    let wallpaperData = try validateAssets(
      theme: theme, packageURL: packageURL, index: themeIndex, file: themeFile)

    return ThemePackage(
      packageURL: packageURL,
      schemaVersion: theme.schemaVersion,
      id: theme.id,
      displayName: theme.displayName,
      appearance: validated.appearance,
      semantic: validated.semantic,
      terminal: validated.terminal,
      wallpaper: theme.wallpaper,
      wallpaperData: wallpaperData,
      mappings: mappings.mappings
    )
  }

  private func readText(_ file: URL, role: String) throws -> String {
    do {
      return try String(contentsOf: file, encoding: .utf8)
    } catch {
      throw ThemeDiagnostic(
        location: .init(file: file),
        message: "Cannot read required \(role): \(error.localizedDescription)")
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, text: String, file: URL) throws -> Value
  {
    do {
      return try TOMLDecoder().decode(type, from: text)
    } catch {
      let description = String(describing: error)
      throw ThemeDiagnostic(
        location: .init(file: file, line: parseLine(from: description)),
        message: "Invalid TOML: \(description)"
      )
    }
  }

  private func parseLine(from description: String) -> Int? {
    guard let marker = description.range(of: "(Line ") else { return nil }
    let suffix = description[marker.upperBound...]
    guard let closing = suffix.firstIndex(of: ")") else { return nil }
    return Int(suffix[..<closing])
  }

  private func validate(
    theme: ThemeDocument,
    themeIndex: TOMLSourceIndex,
    themeFile: URL
  ) throws -> (
    appearance: ThemeAppearance,
    semantic: SemanticColors,
    terminal: TerminalColors
  ) {
    try require(
      theme.schemaVersion == ThemeSchema.version, path: "schema_version",
      message: "Unsupported schema version \(theme.schemaVersion); expected \(ThemeSchema.version)",
      index: themeIndex, file: themeFile)
    try require(
      ThemeSchema.isThemeID(theme.id), path: "id",
      message: "Theme ID must match [a-z][a-z0-9]*(?:-[a-z0-9]+)*",
      index: themeIndex, file: themeFile)
    try require(
      !theme.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      path: "display_name", message: "Display name must not be empty", index: themeIndex,
      file: themeFile)
    guard let appearance = ThemeAppearance(rawValue: theme.appearance) else {
      throw ThemeDiagnostic(
        location: themeIndex.location(for: "appearance", file: themeFile),
        field: "appearance",
        message: "Appearance must be 'dark' or 'light'; found '\(theme.appearance)'"
      )
    }
    try require(
      theme.terminal.ansi.count == 16, path: "terminal.ansi",
      message: "Terminal palette must contain exactly 16 ANSI colors", index: themeIndex,
      file: themeFile)

    let semantic = try SemanticColors(
      background: color(
        theme.semantic.background, path: "semantic.background", index: themeIndex, file: themeFile),
      surface: color(
        theme.semantic.surface, path: "semantic.surface", index: themeIndex, file: themeFile),
      overlay: color(
        theme.semantic.overlay, path: "semantic.overlay", index: themeIndex, file: themeFile),
      border: color(
        theme.semantic.border, path: "semantic.border", index: themeIndex, file: themeFile),
      text: color(theme.semantic.text, path: "semantic.text", index: themeIndex, file: themeFile),
      mutedText: color(
        theme.semantic.mutedText, path: "semantic.muted_text", index: themeIndex, file: themeFile),
      accent: color(
        theme.semantic.accent, path: "semantic.accent", index: themeIndex, file: themeFile),
      selection: color(
        theme.semantic.selection, path: "semantic.selection", index: themeIndex, file: themeFile),
      info: color(theme.semantic.info, path: "semantic.info", index: themeIndex, file: themeFile),
      success: color(
        theme.semantic.success, path: "semantic.success", index: themeIndex, file: themeFile),
      warning: color(
        theme.semantic.warning, path: "semantic.warning", index: themeIndex, file: themeFile),
      error: color(theme.semantic.error, path: "semantic.error", index: themeIndex, file: themeFile)
    )
    let terminal = try TerminalColors(
      foreground: color(
        theme.terminal.foreground, path: "terminal.foreground", index: themeIndex, file: themeFile),
      background: color(
        theme.terminal.background, path: "terminal.background", index: themeIndex, file: themeFile),
      cursor: color(
        theme.terminal.cursor, path: "terminal.cursor", index: themeIndex, file: themeFile),
      selectionForeground: color(
        theme.terminal.selectionForeground, path: "terminal.selection_foreground",
        index: themeIndex, file: themeFile),
      selectionBackground: color(
        theme.terminal.selectionBackground, path: "terminal.selection_background",
        index: themeIndex, file: themeFile),
      ansi: try theme.terminal.ansi.enumerated().map {
        try color(
          $0.element, path: "terminal.ansi", index: themeIndex, file: themeFile,
          suffix: "[\($0.offset)]")
      }
    )
    return (appearance, semantic, terminal)
  }

  private func color(
    _ value: String,
    path: String,
    index: TOMLSourceIndex,
    file: URL,
    suffix: String = ""
  ) throws -> SRGBColor {
    guard let color = SRGBColor(rawValue: value) else {
      throw ThemeDiagnostic(
        location: index.location(for: path, file: file),
        field: path + suffix,
        message: "Color must use sRGB #RRGGBB form; found '\(value)'"
      )
    }
    return color
  }

  private func validate(mappings: MappingsDocument, index: TOMLSourceIndex, file: URL) throws {
    try require(
      mappings.schemaVersion == ThemeSchema.version, path: "schema_version",
      message:
        "Unsupported mappings schema version \(mappings.schemaVersion); expected \(ThemeSchema.version)",
      index: index, file: file)
    for (consumer, value) in mappings.mappings.sorted(by: { $0.key < $1.key }) {
      try require(
        ThemeSchema.isThemeID(consumer), path: "mappings.\(consumer)",
        message: "Mapping key must match [a-z][a-z0-9]*(?:-[a-z0-9]+)*", index: index,
        file: file)
      try require(
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        path: "mappings.\(consumer)", message: "Mapping value must not be empty", index: index,
        file: file)
    }
  }

  private func validateAssets(
    theme: ThemeDocument,
    packageURL: URL,
    index: TOMLSourceIndex,
    file: URL
  ) throws -> Data {
    let path = theme.wallpaper.path
    try require(
      path == "wallpapers/default.png", path: "wallpaper.path",
      message: "Schema v1 requires wallpapers/default.png", index: index, file: file)

    let wallpaperURL = packageURL.appending(path: path)
    let resolvedPackage = packageURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedWallpaper = wallpaperURL.resolvingSymlinksInPath().standardizedFileURL
    try require(
      resolvedWallpaper.path.hasPrefix(resolvedPackage.path + "/"),
      path: "wallpaper.path",
      message: "Wallpaper symlink must resolve inside the theme package",
      index: index,
      file: file
    )

    let wallpaperData: Data
    do {
      wallpaperData = try WallpaperAsset.load(at: resolvedWallpaper)
    } catch WallpaperAssetError.invalidPNG {
      throw ThemeDiagnostic(
        location: index.location(for: "wallpaper.path", file: file),
        field: "wallpaper.path",
        message: "Wallpaper asset cannot be decoded as PNG"
      )
    } catch {
      throw ThemeDiagnostic(
        location: index.location(for: "wallpaper.path", file: file),
        field: "wallpaper.path",
        message: "Cannot read wallpaper asset at \(path): \(error)"
      )
    }

    let provenance = packageURL.appending(path: "LICENSES/wallpaper.md")
    try require(
      FileManager.default.fileExists(atPath: provenance.path), path: "wallpaper.license",
      message: "Missing LICENSES/wallpaper.md provenance record", index: index, file: file)
    for (path, value) in [
      ("wallpaper.source", theme.wallpaper.source),
      ("wallpaper.author", theme.wallpaper.author),
      ("wallpaper.license", theme.wallpaper.license),
    ] {
      try require(
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, path: path,
        message: "Wallpaper provenance value must not be empty", index: index, file: file)
    }
    return wallpaperData
  }

  private func require(
    _ condition: @autoclosure () -> Bool,
    path: String,
    message: String,
    index: TOMLSourceIndex,
    file: URL
  ) throws {
    guard condition() else {
      throw ThemeDiagnostic(
        location: index.location(for: path, file: file), field: path, message: message)
    }
  }

}
