import Darwin
import Foundation
import TOMLDecoder

enum MacarchyConfigurationError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL)
  case invalid(String)
  case invalidWallpaperOverride(themeID: String, reason: String)

  var description: String {
    switch self {
    case .cannotRead(let url):
      "Cannot read Macarchy configuration at \(url.path)"
    case .invalid(let reason):
      "Invalid Macarchy configuration: \(reason)"
    case .invalidWallpaperOverride(let themeID, let reason):
      "Invalid wallpaper override for '\(themeID)': \(reason)"
    }
  }
}

private struct MacarchyConfigurationDocument: Decodable {
  let schemaVersion: Int
  let wallpaperOverrides: [String: String]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case wallpaperOverrides = "wallpaper_overrides"
  }
}

struct MacarchyConfiguration: Sendable {
  let wallpaperOverrides: [String: String]

  func wallpaperData(themeID: String) throws -> Data? {
    guard let path = wallpaperOverrides[themeID] else { return nil }
    let wallpaperURL = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
    do {
      return try WallpaperAsset.load(at: wallpaperURL)
    } catch {
      throw MacarchyConfigurationError.invalidWallpaperOverride(
        themeID: themeID,
        reason: String(describing: error)
      )
    }
  }
}

package struct MacarchyConfigurationStore: Sendable {
  private let configurationURL: URL

  package init(root: URL) {
    configurationURL = root.appending(path: "config.toml")
  }

  package func wallpaperData(themeIDs: [String]) throws -> [String: Data] {
    let configuration = try load()
    return try Dictionary(
      uniqueKeysWithValues: themeIDs.compactMap { themeID in
        try configuration.wallpaperData(themeID: themeID).map { (themeID, $0) }
      }
    )
  }

  func load() throws -> MacarchyConfiguration {
    var metadata = stat()
    guard lstat(configurationURL.path, &metadata) == 0 else {
      if errno == ENOENT { return MacarchyConfiguration(wallpaperOverrides: [:]) }
      throw MacarchyConfigurationError.cannotRead(configurationURL)
    }

    let resolved = configurationURL.resolvingSymlinksInPath().standardizedFileURL
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: resolved).data
    } catch {
      throw MacarchyConfigurationError.cannotRead(configurationURL)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw MacarchyConfigurationError.cannotRead(configurationURL)
    }

    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(text: text, file: configurationURL)
    } catch {
      throw MacarchyConfigurationError.invalid(String(describing: error))
    }
    let allowedTables = Set(["wallpaper_overrides"])
    guard Set(index.tables.map(\.path)).isSubset(of: allowedTables) else {
      throw MacarchyConfigurationError.invalid("contains an unknown table")
    }
    guard
      index.fields.allSatisfy({ field in
        field.path == "schema_version"
          || field.path.hasPrefix("wallpaper_overrides.")
      })
    else {
      throw MacarchyConfigurationError.invalid("contains an unknown key")
    }

    let document: MacarchyConfigurationDocument
    do {
      document = try TOMLDecoder().decode(MacarchyConfigurationDocument.self, from: text)
    } catch {
      throw MacarchyConfigurationError.invalid(String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw MacarchyConfigurationError.invalid(
        "unsupported schema version \(document.schemaVersion); expected 1"
      )
    }

    let overrides = document.wallpaperOverrides ?? [:]
    for (id, path) in overrides {
      guard ThemeSchema.isThemeID(id) else {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: id,
          reason: "theme identifier is invalid"
        )
      }
      try Self.requireAbsolute(path, field: "wallpaper_overrides.\(id)")
    }

    return MacarchyConfiguration(wallpaperOverrides: overrides)
  }

  private static func requireAbsolute(_ path: String, field: String) throws {
    guard NSString(string: path).isAbsolutePath else {
      throw MacarchyConfigurationError.invalid("\(field) must be an absolute path")
    }
  }
}
