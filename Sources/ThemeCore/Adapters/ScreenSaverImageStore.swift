import Darwin
import Foundation
import ImageIO

enum ScreenSaverImageError: Error, CustomStringConvertible, Equatable {
  case unsafeFolder(String)
  case cannotEncode
  case activeThemeChanged

  var description: String {
    switch self {
    case .unsafeFolder(let detail):
      "Cannot publish the Photos screensaver source: \(detail)"
    case .cannotEncode:
      "Cannot encode the chosen wallpaper as a bounded PNG for Photos"
    case .activeThemeChanged:
      "Active theme or screensaver selection changed while preparing the Photos source; prepare it again"
    }
  }
}

/// A derived image export, not a native screensaver settings owner.
package struct ScreenSaverImageStore: Sendable {
  private struct Source {
    let generationID: String
    let themeID: String
    let preference: ScreenSaverPreference?
    let data: Data
    let format: ThemeBackgroundFormat
  }

  private struct Receipt: Codable {
    var owner = "macarchy.screensaver.v1"
    var sourceDigest: String?
    var imageDigest: String?
  }

  private static let imageName = "wallpaper.png"
  private static let receiptName = ".macarchy.json"
  // JPEG/WebP input may expand when losslessly encoded; original PNG stays bounded
  // by the ordinary wallpaper limit. Decoded inputs already have a 64 MP ceiling.
  private static let maximumPNGSize = ThemeImageAsset.maximumPixels * 4 + 1_048_576
  let root: URL
  var beforeCompletion: @Sendable () throws -> Void = {}

  package init(root: URL, beforeCompletion: @escaping @Sendable () throws -> Void = {}) {
    self.root = root.standardizedFileURL
    self.beforeCompletion = beforeCompletion
  }

  var folderURL: URL { root.appending(path: "screensaver", directoryHint: .isDirectory) }

  private var instructions: String {
    "Photos image source ready at \(folderURL.path). Select this folder once in System Settings "
      + "→ Wallpaper → Screen Saver → Custom → Photos → Options; later previews/invocations "
      + "read updates. Native selection and live repaint are not verified or changed."
  }

  func inspection() -> AdapterInspection {
    do {
      guard let source = try activeSource() else {
        return result(.ready, "No chosen wallpaper; the previous Photos source is retained.")
      }
      let lock = ActivationLock(root: root)
      let snapshot = try lock.withLock { try openFolder(create: false) }
      defer { Darwin.close(snapshot.directory) }
      guard
        try matches(
          sourceDigest: sha256Digest(source.data), receipt: snapshot.receipt,
          directory: snapshot.directory)
      else {
        return result(
          .drifted, "Photos source differs from the selected screensaver image; prepare it again.")
      }
      try lock.withLock {
        try validateSource(source, directory: snapshot.directory)
      }
      return result(.ready, instructions)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return result(.drifted, "Photos source is not prepared; run macarchy reconcile wallpaper.")
    } catch ReconciliationStatusError.noActiveGeneration {
      return result(.drifted, "Activate a theme with a wallpaper to prepare the Photos source.")
    } catch ScreenSaverImageError.activeThemeChanged {
      return result(.drifted, ScreenSaverImageError.activeThemeChanged.description)
    } catch {
      return result(.failed, String(describing: error))
    }
  }

  package func reconcile() throws -> String {
    guard let source = try activeSource() else {
      return "No chosen wallpaper; the previous Photos source is retained."
    }
    let lock = ActivationLock(root: root)
    let snapshot = try lock.withLock { try openFolder(create: true) }
    let directory = snapshot.directory
    defer { Darwin.close(directory) }
    let sourceDigest = sha256Digest(source.data)
    if try matches(
      sourceDigest: sourceDigest, receipt: snapshot.receipt, directory: directory)
    {
      try beforeCompletion()
      try lock.withLock {
        try validateSource(source, directory: directory)
      }
      return instructions
    }

    // Decode and write the potentially large image outside the activation lock.
    // Only the final pointer check and renames share the canonical commit boundary.
    let png = try Self.png(data: source.data, format: source.format)
    let temporaryName = ".wallpaper.png-\(UUID().uuidString.lowercased())"
    let temporaryURL = folderURL.appending(path: temporaryName)
    defer { temporaryName.withCString { _ = Darwin.unlinkat(directory, $0, 0) } }
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: directory, name: temporaryName, url: temporaryURL, data: png, mode: 0o600
    )
    let receipt = Receipt(sourceDigest: sourceDigest, imageDigest: sha256Digest(png))
    try beforeCompletion()
    try lock.withLock {
      try validateSource(source, directory: directory)
      do {
        let existing = try PinnedFilesystem.metadata(
          parentDescriptor: directory, name: Self.imageName,
          url: folderURL.appending(path: Self.imageName)
        )
        guard existing.st_mode & S_IFMT == S_IFREG else {
          throw ScreenSaverImageError.unsafeFolder("wallpaper.png is not a regular file")
        }
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        // First publication has no destination yet.
      }
      let renamed = temporaryName.withCString { source in
        Self.imageName.withCString { destination in
          Darwin.renameat(directory, source, directory, destination)
        }
      }
      guard renamed == 0 else {
        throw PinnedFilesystemError(operation: "publish Photos image", url: folderURL, code: errno)
      }
      try writeReceipt(receipt, directory: directory)
    }
    return instructions
  }

  private func activeSource() throws -> Source? {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let preferences = ScreenSaverPreferenceStore(root: root)
    if let preference = try preferences.load()[manifest.themeID] {
      return Source(
        generationID: manifest.generationID, themeID: manifest.themeID, preference: preference,
        data: try preferences.image(for: preference), format: preference.format)
    }
    guard let background = manifest.background else { return nil }
    let data = try BoundedRegularFile.read(
      at: root.appending(
        path: "generations/\(manifest.generationID)/\(WallpaperAdapter.outputPath)"),
      maximumSize: ThemeImageAsset.maximumSize
    ).data
    return Source(
      generationID: manifest.generationID, themeID: manifest.themeID, preference: nil,
      data: data, format: background.format)
  }

  // Caller holds ActivationLock; receipt staging must not look like foreign content.
  private func openFolder(create: Bool) throws -> (directory: Int32, receipt: Receipt) {
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let directory =
      try create
      ? PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: parent, name: "screensaver", url: folderURL, mode: 0o700)
      : PinnedFilesystem.openDirectory(
        parentDescriptor: parent, name: "screensaver", url: folderURL)
    do {
      let listing = try PinnedFilesystem.directoryEntries(
        descriptor: directory, url: folderURL, limit: 64)
      guard !listing.truncated else {
        throw ScreenSaverImageError.unsafeFolder("too many entries at \(folderURL.path)")
      }
      let entries = Set(listing.entries).subtracting([".DS_Store"])
      let receipt: Receipt
      if create, entries.isEmpty {
        receipt = Receipt()
        try writeReceipt(receipt, directory: directory)
      } else {
        receipt = try readReceipt(directory: directory)
        guard
          entries.allSatisfy({
            $0 == Self.receiptName || $0 == Self.imageName || $0.hasPrefix(".wallpaper.png-")
          })
        else {
          throw ScreenSaverImageError.unsafeFolder(
            "unrelated files at \(folderURL.path); nothing was removed")
        }
      }
      return (directory, receipt)
    } catch {
      Darwin.close(directory)
      throw error
    }
  }

  // Also used for no-op success: hashing a matching image is not sufficient if
  // the canonical source or the stable folder was replaced during that read.
  private func validateSource(_ source: Source, directory: Int32) throws {
    let current = try FileManager.default.destinationOfSymbolicLink(
      atPath: root.appending(path: "current").path)
    guard current == "generations/\(source.generationID)",
      try ScreenSaverPreferenceStore(root: root).load()[source.themeID] == source.preference
    else {
      throw ScreenSaverImageError.activeThemeChanged
    }
    let snapshot = try openFolder(create: false)
    defer { Darwin.close(snapshot.directory) }
    var pinned = stat()
    var actual = stat()
    guard fstat(directory, &pinned) == 0, fstat(snapshot.directory, &actual) == 0,
      pinned.st_dev == actual.st_dev, pinned.st_ino == actual.st_ino
    else {
      throw ScreenSaverImageError.unsafeFolder("the source folder changed during publication")
    }
  }

  private func readReceipt(directory: Int32) throws -> Receipt {
    let file = try PinnedFilesystem.readRegularFile(
      parentDescriptor: directory, name: Self.receiptName,
      url: folderURL.appending(path: Self.receiptName)
    )
    let receipt = try JSONDecoder().decode(Receipt.self, from: file.data)
    guard receipt.owner == Receipt().owner else {
      throw ScreenSaverImageError.unsafeFolder("unrecognized ownership at \(folderURL.path)")
    }
    return receipt
  }

  private func writeReceipt(_ receipt: Receipt, directory: Int32) throws {
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: directory, name: Self.receiptName,
      url: folderURL.appending(path: Self.receiptName),
      data: JSONEncoder().encode(receipt), mode: 0o600
    )
  }

  private func imageData(directory: Int32) throws -> Data? {
    do {
      return try PinnedFilesystem.readRegularFile(
        parentDescriptor: directory, name: Self.imageName,
        url: folderURL.appending(path: Self.imageName),
        maximumSize: Self.maximumPNGSize
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
  }

  private func matches(sourceDigest: String, receipt: Receipt, directory: Int32) throws -> Bool {
    guard receipt.sourceDigest == sourceDigest, let data = try imageData(directory: directory)
    else { return false }
    return sha256Digest(data) == receipt.imageDigest
  }

  private static func png(data: Data, format: ThemeBackgroundFormat) throws -> Data {
    try ThemeImageAsset.validate(data: data, format: format)
    if format == .png { return data }
    let output = NSMutableData()
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: ThemeImageAsset.maximumDimension,
      ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
      let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
    else { throw ScreenSaverImageError.cannotEncode }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), output.length <= maximumPNGSize else {
      throw ScreenSaverImageError.cannotEncode
    }
    return output as Data
  }

  private func result(_ status: AdapterInspectionStatus, _ message: String) -> AdapterInspection {
    AdapterInspection(
      adapterID: WallpaperAdapter.id, requirement: .required, status: status, message: message)
  }
}
