import Darwin
import Foundation

package enum BackgroundSelectionError: Error, CustomStringConvertible, Equatable, Sendable {
  case noBackgrounds(themeID: String)
  case unknownBackground(themeID: String, backgroundID: String)

  package var description: String {
    switch self {
    case .noBackgrounds(let themeID):
      "Theme '\(themeID)' has no backgrounds to select"
    case .unknownBackground(let themeID, let backgroundID):
      "Theme '\(themeID)' has no background named '\(backgroundID)'"
    }
  }
}

enum BackgroundPreferenceStoreError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL)
  case cannotReplace(Int32)
  case invalid(String)

  var description: String {
    switch self {
    case .cannotRead(let url):
      "Cannot read background preferences at \(url.path)"
    case .cannotReplace(let code):
      "Cannot atomically replace background preferences (errno \(code)): "
        + String(cString: strerror(code))
    case .invalid(let reason):
      "Invalid background preferences: \(reason)"
    }
  }
}

private struct BackgroundPreferenceDocument: Codable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let selections: [String: String]

  init(selections: [String: String]) {
    schemaVersion = Self.schemaVersion
    self.selections = selections
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case selections
  }
}

struct BackgroundPreferenceStore: Sendable {
  private let root: URL
  private let preferencesURL: URL

  init(root: URL) {
    self.root = root.standardizedFileURL
    preferencesURL = self.root.appending(path: "state/background-preferences.json")
  }

  func load() throws -> [String: String] {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: preferencesURL).data
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return [:]
    } catch {
      throw BackgroundPreferenceStoreError.cannotRead(preferencesURL)
    }

    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys) == Set(BackgroundPreferenceDocument.CodingKeys.allCases.map(\.stringValue))
      else {
        throw BackgroundPreferenceStoreError.invalid("contains unknown or missing fields")
      }
      let document = try JSONDecoder().decode(BackgroundPreferenceDocument.self, from: data)
      guard document.schemaVersion == BackgroundPreferenceDocument.schemaVersion else {
        throw BackgroundPreferenceStoreError.invalid(
          "unsupported schema version \(document.schemaVersion)"
        )
      }
      try validate(document.selections)
      return document.selections
    } catch let error as BackgroundPreferenceStoreError {
      throw error
    } catch {
      throw BackgroundPreferenceStoreError.invalid(String(describing: error))
    }
  }

  func persist(_ selections: [String: String]) throws {
    try validate(selections)
    let stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true
    )
    let temporaryURL = stateDirectory.appending(
      path: ".background-preferences-\(UUID().uuidString.lowercased()).json"
    )
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(BackgroundPreferenceDocument(selections: selections))
    data.append(0x0a)
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw BackgroundPreferenceStoreError.invalid("exceeds the 1 MiB file limit")
    }
    try data.write(to: temporaryURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporaryURL.path
    )

    let result = temporaryURL.path.withCString { source in
      preferencesURL.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw BackgroundPreferenceStoreError.cannotReplace(errno)
    }
  }

  private func validate(_ selections: [String: String]) throws {
    for (themeID, backgroundID) in selections {
      guard ThemeSchema.isThemeID(themeID), ThemeSchema.isThemeID(backgroundID) else {
        throw BackgroundPreferenceStoreError.invalid(
          "selection identifiers must match the theme identifier grammar"
        )
      }
    }
  }
}

package struct PreparedThemeBackground: Sendable {
  package let selection: GenerationBackground?
  package let data: Data?
  package let notice: String?

  package init(
    selection: GenerationBackground?,
    data: Data?,
    notice: String? = nil
  ) {
    self.selection = selection
    self.data = data
    self.notice = notice
  }
}

struct BackgroundSelectionResolver {
  static func resolve(
    package: ThemePackage,
    requestedBackgroundID: String?,
    preferences: [String: String],
    overrideData: Data?
  ) throws -> PreparedThemeBackground {
    guard let first = package.backgrounds.first else {
      if requestedBackgroundID != nil {
        throw BackgroundSelectionError.noBackgrounds(themeID: package.id)
      }
      return PreparedThemeBackground(selection: nil, data: nil)
    }

    let selected: ThemeBackground
    var notice: String?
    if let requestedBackgroundID {
      guard let requested = package.background(id: requestedBackgroundID) else {
        throw BackgroundSelectionError.unknownBackground(
          themeID: package.id,
          backgroundID: requestedBackgroundID
        )
      }
      selected = requested
    } else if let rememberedID = preferences[package.id] {
      if let remembered = package.background(id: rememberedID) {
        selected = remembered
      } else {
        selected = first
        notice =
          "Remembered background '\(rememberedID)' is no longer available; selected the first background."
      }
    } else {
      selected = first
    }

    return PreparedThemeBackground(
      selection: GenerationBackground(
        id: selected.id,
        format: overrideData == nil ? selected.format : .png
      ),
      data: overrideData ?? package.data(for: selected),
      notice: notice
    )
  }
}
