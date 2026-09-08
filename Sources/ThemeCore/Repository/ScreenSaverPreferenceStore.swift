import Darwin
import Foundation

package struct ScreenSaverPreference: Codable, Equatable, Sendable {
  package let backgroundID: String
  let imageDigest: String
  let format: ThemeBackgroundFormat

  private enum CodingKeys: String, CodingKey {
    case backgroundID = "background_id"
    case imageDigest = "image_digest"
    case format
  }

  var imageName: String { String(imageDigest.dropFirst("sha256:".count)) + "." + format.rawValue }
}

enum ScreenSaverPreferenceError: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self {
    case .invalid(let reason): "Invalid screensaver selection: \(reason)"
    }
  }
}

/// Per-theme visual intent. Images are retained independently of package/version
/// paths; the public Photos folder remains a repairable projection, not authority.
package struct ScreenSaverPreferenceStore: Sendable {
  private struct Document: Codable {
    var schemaVersion = 1
    var selections: [String: ScreenSaverPreference]

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case selections
    }
  }

  private let root: URL
  private static let preferencesName = "screensaver-preferences.json"
  private var stateURL: URL { root.appending(path: "state") }
  private var imagesURL: URL { stateURL.appending(path: "screensaver-images") }

  package init(root: URL) { self.root = root.standardizedFileURL }

  package func load() throws -> [String: ScreenSaverPreference] {
    let url = stateURL.appending(path: Self.preferencesName)
    let data: Data
    do {
      let state = try openState(create: false)
      defer { Darwin.close(state) }
      data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: state, name: Self.preferencesName, url: url
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return [:]
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let object, Set(object.keys) == ["schema_version", "selections"],
      let entries = object["selections"] as? [String: [String: Any]],
      entries.values.allSatisfy({ Set($0.keys) == ["background_id", "image_digest", "format"] })
    else { throw ScreenSaverPreferenceError.invalid("unknown or missing fields") }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.schemaVersion == 1 else {
      throw ScreenSaverPreferenceError.invalid("unsupported preference schema")
    }
    for (themeID, selection) in document.selections {
      guard ThemeSchema.isThemeID(themeID), ThemeSchema.isThemeID(selection.backgroundID),
        isSHA256Digest(selection.imageDigest)
      else { throw ScreenSaverPreferenceError.invalid("invalid selection identity or digest") }
    }
    return document.selections
  }

  /// Caller holds ThemePackageLock while resolving the package and saving intent.
  /// Bounded image work stays outside ActivationLock; only the small preference
  /// document commits under that lock, after its immutable image is available.
  package func select(package: ThemePackage, backgroundID: String) throws {
    _ = try load()
    guard let background = package.background(id: backgroundID) else {
      throw BackgroundSelectionError.unknownBackground(
        themeID: package.id, backgroundID: backgroundID)
    }
    let data = package.data(for: background)
    try ThemeImageAsset.validate(data: data, format: background.format)
    let preference = ScreenSaverPreference(
      backgroundID: background.id, imageDigest: sha256Digest(data), format: background.format)
    let state = try openState(create: true)
    defer { Darwin.close(state) }
    let images = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: state, name: "screensaver-images", url: imagesURL, mode: 0o700)
    defer { Darwin.close(images) }
    let url = imagesURL.appending(path: preference.imageName)
    do {
      let existing = try PinnedFilesystem.readRegularFile(
        parentDescriptor: images, name: preference.imageName, url: url,
        maximumSize: ThemeImageAsset.maximumSize
      ).data
      guard existing == data else {
        throw ScreenSaverPreferenceError.invalid(
          "saved image digest mismatch; nothing was overwritten")
      }
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      let temporaryName = ".image-\(UUID().uuidString.lowercased())"
      defer { temporaryName.withCString { _ = Darwin.unlinkat(images, $0, 0) } }
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: images, name: temporaryName,
        url: imagesURL.appending(path: temporaryName),
        data: data, mode: 0o400)
      let result = temporaryName.withCString { source in
        preference.imageName.withCString { destination in
          Darwin.renameatx_np(images, source, images, destination, UInt32(RENAME_EXCL))
        }
      }
      guard result == 0 else {
        throw PinnedFilesystemError(
          operation: "publish screensaver selection image", url: url, code: errno)
      }
    }
    try update(themeID: package.id, selection: preference)
  }

  package func followWallpaper(themeID: String) throws {
    guard ThemeSchema.isThemeID(themeID) else {
      throw ScreenSaverPreferenceError.invalid("invalid theme identifier")
    }
    try update(themeID: themeID, selection: nil)
  }

  func image(for selection: ScreenSaverPreference) throws -> Data {
    let images = try PinnedFilesystem.openDirectory(at: imagesURL)
    defer { Darwin.close(images) }
    let data = try PinnedFilesystem.readRegularFile(
      parentDescriptor: images, name: selection.imageName,
      url: imagesURL.appending(path: selection.imageName), maximumSize: ThemeImageAsset.maximumSize
    ).data
    guard sha256Digest(data) == selection.imageDigest else {
      throw ScreenSaverPreferenceError.invalid(
        "saved image is damaged; choose another image or follow wallpaper")
    }
    return data
  }

  private func update(themeID: String, selection: ScreenSaverPreference?) throws {
    try ActivationLock(root: root).withLock {
      var selections = try load()
      if selections[themeID] == selection { return }
      selections[themeID] = selection
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(Document(selections: selections))
      guard data.count <= BoundedRegularFile.maximumSize else {
        throw ScreenSaverPreferenceError.invalid("preferences exceed the 1 MiB limit")
      }
      let state = try openState(create: true)
      defer { Darwin.close(state) }
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: state, name: Self.preferencesName,
        url: stateURL.appending(path: Self.preferencesName), data: data, mode: 0o600)
    }
  }

  private func openState(create: Bool) throws -> Int32 {
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    return try create
      ? PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: parent, name: "state", url: stateURL, mode: 0o700)
      : PinnedFilesystem.openDirectory(parentDescriptor: parent, name: "state", url: stateURL)
  }
}
