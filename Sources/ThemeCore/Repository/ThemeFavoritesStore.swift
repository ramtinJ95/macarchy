import Darwin
import Foundation

package enum ThemeFavoritesStoreError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL)
  case cannotReplace(Int32)
  case invalid(String)

  package var description: String {
    switch self {
    case .cannotRead(let url):
      "Cannot read theme favorites at \(url.path)"
    case .cannotReplace(let code):
      "Cannot atomically replace theme favorites (errno \(code)): "
        + String(cString: strerror(code))
    case .invalid(let reason):
      "Invalid theme favorites: \(reason)"
    }
  }
}

private struct ThemeFavoritesDocument: Codable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let themeIDs: [String]

  init(themeIDs: [String]) {
    schemaVersion = Self.schemaVersion
    self.themeIDs = themeIDs
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case themeIDs = "theme_ids"
  }
}

/// `state/theme-favorites.json`: favorite theme IDs, oldest first. A preference record, never
/// canonical state; callers write it under ThemePackageLock.
package struct ThemeFavoritesStore: Sendable {
  package static let maximumFavorites = 500

  private let url: URL

  package init(root: URL) {
    url = root.standardizedFileURL.appending(path: "state/theme-favorites.json")
  }

  package func load() throws -> [String] {
    let file: BoundedRegularFile?
    do {
      file = try BoundedRegularFile.readIfPresent(at: url)
    } catch {
      throw ThemeFavoritesStoreError.cannotRead(url)
    }
    guard let data = file?.data else { return [] }

    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys) == Set(ThemeFavoritesDocument.CodingKeys.allCases.map(\.stringValue))
      else {
        throw ThemeFavoritesStoreError.invalid("contains unknown or missing fields")
      }
      let document = try JSONDecoder().decode(ThemeFavoritesDocument.self, from: data)
      guard document.schemaVersion == ThemeFavoritesDocument.schemaVersion else {
        throw ThemeFavoritesStoreError.invalid(
          "unsupported schema version \(document.schemaVersion)")
      }
      try validate(document.themeIDs)
      return document.themeIDs
    } catch let error as ThemeFavoritesStoreError {
      throw error
    } catch {
      throw ThemeFavoritesStoreError.invalid(String(describing: error))
    }
  }

  package func persist(_ themeIDs: [String]) throws {
    try validate(themeIDs)
    try StateFile.replaceByRename(
      at: url,
      temporaryName: ".theme-favorites-\(UUID().uuidString.lowercased()).json",
      temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(ThemeFavoritesDocument(themeIDs: themeIDs)) },
      tooLargeError: ThemeFavoritesStoreError.invalid("exceeds the 1 MiB file limit"),
      renameError: ThemeFavoritesStoreError.cannotReplace
    )
  }

  private func validate(_ themeIDs: [String]) throws {
    guard themeIDs.count <= Self.maximumFavorites else {
      throw ThemeFavoritesStoreError.invalid("holds more than \(Self.maximumFavorites) themes")
    }
    guard Set(themeIDs).count == themeIDs.count else {
      throw ThemeFavoritesStoreError.invalid("lists a theme more than once")
    }
    guard themeIDs.allSatisfy(ThemeSchema.isThemeID) else {
      throw ThemeFavoritesStoreError.invalid("every entry must be a valid theme identifier")
    }
  }
}
