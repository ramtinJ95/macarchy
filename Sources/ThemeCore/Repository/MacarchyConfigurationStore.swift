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
  let wallpaperAdditions: [PersonalWallpaperDocument]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case wallpaperOverrides = "wallpaper_overrides"
    case wallpaperAdditions = "wallpaper_additions"
  }
}

private struct PersonalWallpaperDocument: Decodable {
  let themeID: String
  let id: String
  let path: String

  enum CodingKeys: String, CodingKey {
    case themeID = "theme_id"
    case id, path
  }
}

private struct PersonalWallpaper: Sendable {
  let id: String
  let path: String
}

struct ThemeBackgroundAddition: Sendable {
  let background: ThemeBackground
  let data: Data
}

struct MacarchyConfiguration: Sendable {
  private let wallpaperAdditions: [String: [PersonalWallpaper]]

  fileprivate init(wallpaperAdditions: [String: [PersonalWallpaper]]) {
    self.wallpaperAdditions = wallpaperAdditions
  }

  func personalBackgrounds(themeID: String) throws -> [ThemeBackgroundAddition] {
    try (wallpaperAdditions[themeID] ?? []).map { addition in
      let id = addition.id
      let path = addition.path
      let wallpaperURL = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
      guard let format = ThemeBackgroundFormat(pathExtension: wallpaperURL.pathExtension) else {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: themeID,
          reason: "personal background '\(id)' has unsupported image extension"
        )
      }
      do {
        return ThemeBackgroundAddition(
          background: ThemeBackground(
            id: id,
            path: path,
            source: "Personal wallpaper configured by the user",
            author: "Personal; not verified",
            license: "Personal use only; not bundled",
            format: format,
            origin: .personal
          ),
          data: try ThemeImageAsset.load(at: wallpaperURL, format: format)
        )
      } catch {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: themeID,
          reason: "personal background '\(id)' is invalid: \(error)"
        )
      }
    }
  }
}

package struct MacarchyConfigurationStore: Sendable {
  private let configurationURL: URL

  package init(root: URL) {
    configurationURL = root.appending(path: "config.toml")
  }

  package func addingPersonalBackgrounds(to package: ThemePackage) throws -> ThemePackage {
    let configuration = try load()
    return try package.addingPersonalBackgrounds(
      configuration.personalBackgrounds(themeID: package.id)
    )
  }

  func load() throws -> MacarchyConfiguration {
    var metadata = stat()
    guard lstat(configurationURL.path, &metadata) == 0 else {
      if errno == ENOENT { return MacarchyConfiguration(wallpaperAdditions: [:]) }
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
    guard
      index.tables.allSatisfy({ table in
        table.path == "wallpaper_overrides" || table.path == "wallpaper_additions"
      })
    else {
      throw MacarchyConfigurationError.invalid("contains an unknown table")
    }
    guard
      index.fields.allSatisfy({ field in
        field.path == "schema_version"
          || field.path.hasPrefix("wallpaper_overrides.")
          || field.path.hasPrefix("wallpaper_additions.")
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
    guard [1, 2].contains(document.schemaVersion) else {
      throw MacarchyConfigurationError.invalid(
        "unsupported schema version \(document.schemaVersion); expected 1 or 2"
      )
    }

    if document.schemaVersion == 1, document.wallpaperAdditions != nil {
      throw MacarchyConfigurationError.invalid(
        "wallpaper_additions requires schema_version = 2"
      )
    }
    if document.schemaVersion == 2, document.wallpaperOverrides != nil {
      throw MacarchyConfigurationError.invalid(
        "wallpaper_overrides was replaced by wallpaper_additions in schema version 2"
      )
    }

    var additions: [String: [PersonalWallpaper]] = [:]
    if document.schemaVersion == 1 {
      for (themeID, path) in document.wallpaperOverrides ?? [:] {
        additions[themeID] = [PersonalWallpaper(id: "personal", path: path)]
      }
    } else {
      for addition in document.wallpaperAdditions ?? [] {
        additions[addition.themeID, default: []].append(
          PersonalWallpaper(id: addition.id, path: addition.path)
        )
      }
    }
    for (themeID, backgrounds) in additions {
      guard ThemeSchema.isThemeID(themeID) else {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: themeID,
          reason: "theme identifier is invalid"
        )
      }
      guard !backgrounds.isEmpty else {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: themeID,
          reason: "personal background collection is empty"
        )
      }
      guard Set(backgrounds.map(\.id)).count == backgrounds.count else {
        throw MacarchyConfigurationError.invalidWallpaperOverride(
          themeID: themeID,
          reason: "personal background identifiers must be unique"
        )
      }
      for background in backgrounds {
        let backgroundID = background.id
        let path = background.path
        guard ThemeSchema.isThemeID(backgroundID) else {
          throw MacarchyConfigurationError.invalidWallpaperOverride(
            themeID: themeID,
            reason: "personal background identifier '\(backgroundID)' is invalid"
          )
        }
        try Self.requireAbsolute(
          path,
          field: "wallpaper_additions.\(themeID).\(backgroundID)"
        )
      }
    }

    return MacarchyConfiguration(wallpaperAdditions: additions)
  }

  private static func requireAbsolute(_ path: String, field: String) throws {
    guard NSString(string: path).isAbsolutePath else {
      throw MacarchyConfigurationError.invalid("\(field) must be an absolute path")
    }
  }
}
