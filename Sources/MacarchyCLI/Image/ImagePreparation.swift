import AppKit
import ArgumentParser
import Foundation
import ImageIO
import ThemeCore
import UniformTypeIdentifiers

enum ImagePreset: String, CaseIterable, ExpressibleByArgument {
  case share
  case small
  case png

  struct Parameters: Equatable {
    let format: UTType
    let fileExtension: String
    let quality: Double?
    let maxEdge: Int?
    let title: String
  }

  var parameters: Parameters {
    switch self {
    case .share:
      Parameters(
        format: .jpeg, fileExtension: "jpg", quality: 0.8, maxEdge: 2048,
        title: "Share — JPEG, up to 2048 px")
    case .small:
      Parameters(
        format: .jpeg, fileExtension: "jpg", quality: 0.7, maxEdge: 1280,
        title: "Small — JPEG, up to 1280 px")
    case .png:
      Parameters(
        format: .png, fileExtension: "png", quality: nil, maxEdge: nil,
        title: "PNG — lossless, original size")
    }
  }
}

enum ImageSource: Equatable {
  case file(URL)
  case clipboard

  var subject: String {
    switch self {
    case .file(let url): url.path
    case .clipboard: "the clipboard image"
    }
  }
}

/// The two ways the menu dialog can pick the image to prepare.
enum ImageSourceChoice: CaseIterable, Equatable {
  case clipboard
  case file

  var title: String {
    switch self {
    case .clipboard: "Use clipboard image"
    case .file: "Choose file…"
    }
  }
}

struct PreparedImage: Equatable {
  let output: URL
  let pixelWidth: Int
  let pixelHeight: Int
  let bytes: Int
  /// The source had several frames, such as an animated GIF, and only its primary one was used.
  let primaryFrameOnly: Bool
}

struct EncodedImage {
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int
  let primaryFrameOnly: Bool
}

enum ImagePreparationError: Error, Equatable, CustomStringConvertible {
  case missing(String)
  case unreadable(String, String)
  case empty(String)
  case notAnImage(String)
  case noClipboardImage
  case encodingFailed
  case outputExists(String)
  case outputParent(String)
  case outputExtension(String, ImagePreset)
  case namesExhausted(String)
  case clipboardWrite
  case savedButNotCopied(String, String)

  var description: String {
    switch self {
    case .missing(let path): "Cannot use \(path): it does not exist."
    case .unreadable(let path, let reason): "Cannot use \(path): \(reason)."
    case .empty(let subject): "Cannot use \(subject): it is empty."
    case .notAnImage(let subject): "Cannot use \(subject): it is not a readable image."
    case .noClipboardImage: "The clipboard has no image."
    case .encodingFailed: "Could not encode the prepared image. Nothing was saved."
    case .outputExists(let path):
      "\(path) already exists. Macarchy never overwrites a file; choose a new output path."
    case .outputParent(let path): "The output folder \(path) does not exist."
    case .outputExtension(let path, let preset):
      "\(path) must end in .\(preset.parameters.fileExtension) for the \(preset.rawValue) preset."
    case .namesExhausted(let path):
      "\(path) and its -2 to -\(ImagePreparation.maximumNameAttempts) variants already exist. "
        + "Nothing was saved."
    case .clipboardWrite: "The clipboard did not accept the image."
    case .savedButNotCopied(let path, let detail):
      "Saved \(path), but copying it to the clipboard failed: \(detail)"
    }
  }
}

/// Encodes a separate, metadata-free sRGB copy of an image and saves it without ever replacing a
/// file. The source is only read. Clipboard input reads image types only.
@MainActor
struct ImagePreparation {
  nonisolated static let maximumSourceSize = 256 * 1_048_576
  nonisolated static let maximumNameAttempts = 99

  let clipboardImage: () -> Data?
  let copyToClipboard: (_ file: URL, _ data: Data, _ format: UTType) throws -> Void
  let showInFinder: (URL) -> Void
  let now: () -> Date
  let downloads: URL

  /// Without `output`, the result goes beside the source file, or to Downloads for clipboard input.
  func prepare(
    _ source: ImageSource, preset: ImagePreset, output: URL? = nil, copy: Bool, reveal: Bool
  ) throws -> PreparedImage {
    if let output { try Self.validate(output: output, preset: preset) }
    let encoded = try Self.encode(try load(source), preset: preset, subject: source.subject)
    let saved = try save(encoded.data, to: output, for: source, preset: preset)
    var copyFailure: (any Error)?
    if copy {
      do {
        try copyToClipboard(saved, encoded.data, preset.parameters.format)
      } catch {
        copyFailure = error
      }
    }
    if reveal { showInFinder(saved) }
    if let copyFailure {
      throw ImagePreparationError.savedButNotCopied(saved.path, String(describing: copyFailure))
    }
    return PreparedImage(
      output: saved, pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight,
      bytes: encoded.data.count, primaryFrameOnly: encoded.primaryFrameOnly)
  }

  /// The menu flow: `pick` returns the preset and where the image comes from, and `chooseFile`
  /// the chosen file. Either returning nil cancels with nothing written. The result is copied
  /// and revealed.
  func choose(
    pick: () -> (preset: ImagePreset, source: ImageSourceChoice)?, chooseFile: () -> URL?
  ) throws -> PreparedImage? {
    guard let picked = pick() else { return nil }
    let source: ImageSource
    switch picked.source {
    case .clipboard:
      source = .clipboard
    case .file:
      guard let url = chooseFile() else { return nil }
      source = .file(url)
    }
    return try prepare(source, preset: picked.preset, copy: true, reveal: true)
  }

  /// Decodes the primary frame with its orientation applied, never larger than the source, draws
  /// it into an 8-bit sRGB bitmap, and encodes only those pixels. No source property is copied.
  static func encode(_ data: Data, preset: ImagePreset, subject: String) throws -> EncodedImage {
    guard !data.isEmpty else { throw ImagePreparationError.empty(subject) }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) != nil,
      CGImageSourceGetStatus(source) == .statusComplete
    else { throw ImagePreparationError.notAnImage(subject) }
    let frames = CGImageSourceGetCount(source)
    guard frames > 0 else { throw ImagePreparationError.notAnImage(subject) }
    let index = CGImageSourceGetPrimaryImageIndex(source)
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0
    else { throw ImagePreparationError.notAnImage(subject) }
    let parameters = preset.parameters
    let longestEdge = max(width, height)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(parameters.maxEdge ?? longestEdge, longestEdge),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    else { throw ImagePreparationError.notAnImage(subject) }
    guard let image = render(decoded, opaque: parameters.format != .png) else {
      throw ImagePreparationError.encodingFailed
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, parameters.format.identifier as CFString, 1, nil)
    else { throw ImagePreparationError.encodingFailed }
    var encoding: [CFString: Any] = [:]
    if let quality = parameters.quality {
      encoding[kCGImageDestinationLossyCompressionQuality] = quality
    }
    CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ImagePreparationError.encodingFailed
    }
    return EncodedImage(
      data: output as Data, pixelWidth: image.width, pixelHeight: image.height,
      primaryFrameOnly: frames > 1)
  }

  /// JPEG has no alpha channel, so an opaque render flattens transparency onto white.
  private static func render(_ image: CGImage, opaque: Bool) -> CGImage? {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue))
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    if opaque {
      context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
      context.fill(bounds)
    }
    context.draw(image, in: bounds)
    return context.makeImage()
  }

  private static func validate(output: URL, preset: ImagePreset) throws {
    guard UTType(filenameExtension: output.pathExtension.lowercased()) == preset.parameters.format
    else { throw ImagePreparationError.outputExtension(output.path, preset) }
    try checkNewFile(output)
  }

  /// A path the user chose must name nothing yet, not even a dangling link, inside an existing
  /// folder. `writeNewFile` rechecks existence.
  static func checkNewFile(_ url: URL) throws {
    if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
      throw ImagePreparationError.outputExists(url.path)
    }
    let parent = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ImagePreparationError.outputParent(parent.path) }
  }

  /// Writes exclusively, so a file that appeared after `checkNewFile` is never replaced.
  static func writeNewFile(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: .withoutOverwriting)
    } catch let error where alreadyExists(error) {
      throw ImagePreparationError.outputExists(url.path)
    }
  }

  private func load(_ source: ImageSource) throws -> Data {
    switch source {
    case .clipboard:
      guard let data = clipboardImage() else { throw ImagePreparationError.noClipboardImage }
      return data
    case .file(let url):
      do {
        return try BoundedRegularFile.read(
          at: url.resolvingSymlinksInPath(), maximumSize: Self.maximumSourceSize
        ).data
      } catch let error as BoundedRegularFileError {
        if case .system(_, let code) = error, code == ENOENT {
          throw ImagePreparationError.missing(url.path)
        }
        throw ImagePreparationError.unreadable(url.path, error.description)
      }
    }
  }

  /// Every write is exclusive, so a file that appears meanwhile is never replaced: an explicit
  /// output then fails, and a generated name steps to the next suffix.
  private func save(_ data: Data, to output: URL?, for source: ImageSource, preset: ImagePreset)
    throws -> URL
  {
    if let output {
      try Self.writeNewFile(data, to: output)
      return output
    }
    let folder: URL
    let stem: String
    switch source {
    case .file(let url):
      folder = url.deletingLastPathComponent()
      stem = url.deletingPathExtension().lastPathComponent
    case .clipboard:
      folder = downloads
      stem = "clipboard-\(Self.timestamp(now()))"
    }
    let parameters = preset.parameters
    func candidate(_ attempt: Int) -> URL {
      let suffix = attempt == 1 ? "" : "-\(attempt)"
      return folder.appending(
        path: "\(stem)-\(preset.rawValue)\(suffix).\(parameters.fileExtension)",
        directoryHint: .notDirectory)
    }
    for attempt in 1...Self.maximumNameAttempts {
      do {
        try data.write(to: candidate(attempt), options: .withoutOverwriting)
        return candidate(attempt)
      } catch let error where Self.alreadyExists(error) {
        continue
      }
    }
    throw ImagePreparationError.namesExhausted(candidate(1).path)
  }

  /// Foundation reports EEXIST as a Cocoa error, possibly wrapping the POSIX one.
  private static func alreadyExists(_ error: any Error) -> Bool {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain,
      failure.code == CocoaError.fileWriteFileExists.rawValue
    {
      return true
    }
    let errors: [NSError?] = [failure, failure.userInfo[NSUnderlyingErrorKey] as? NSError]
    return errors.contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EEXIST) }
  }

  /// Local wall-clock time, `yyyyMMdd-HHmmss`.
  static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}

extension ImagePreparation {
  static var live: Self {
    Self(
      clipboardImage: { ClipboardImageData.readGeneralPasteboard()?.data },
      copyToClipboard: { file, data, format in
        let item = NSPasteboardItem()
        guard item.setString(file.absoluteString, forType: .fileURL),
          item.setData(data, forType: NSPasteboard.PasteboardType(format.identifier))
        else { throw ImagePreparationError.clipboardWrite }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([item]) else { throw ImagePreparationError.clipboardWrite }
      },
      showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      now: { Date() },
      downloads: URL.downloadsDirectory)
  }
}

extension PreparedImage {
  /// `Prepared photo-share.jpg (2048×1365, 412 KB) in ~/Pictures, copied to the clipboard.`
  func message(copied: Bool) -> String {
    let frame = primaryFrameOnly ? ", primary frame only" : ""
    let folder = (output.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    return
      "Prepared \(output.lastPathComponent) (\(pixelWidth)×\(pixelHeight), "
      + "\(Self.size(bytes))\(frame)) in \(folder)"
      + (copied ? ", copied to the clipboard." : ".")
  }

  func renderJSON() throws -> String {
    let document: [String: Any] = [
      "status": "prepared", "output": output.path, "width": pixelWidth, "height": pixelHeight,
      "bytes": bytes, "primaryFrameOnly": primaryFrameOnly,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// Decimal units, as Finder shows file sizes.
  static func size(_ bytes: Int) -> String {
    if bytes < 1_000 { return "\(bytes) bytes" }
    if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1_000).rounded())) KB" }
    return String(format: "%.1f MB", Double(bytes) / 1_000_000)
  }
}
