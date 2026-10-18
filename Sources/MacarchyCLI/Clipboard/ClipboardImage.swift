import AppKit
import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image formats Macarchy reads from the clipboard and saves.
enum ClipboardImageFormat: String, CaseIterable, ExpressibleByArgument {
  case png
  case jpeg
  case tiff
  case heic

  var type: UTType {
    switch self {
    case .png: .png
    case .jpeg: .jpeg
    case .tiff: .tiff
    case .heic: .heic
    }
  }

  var name: String { rawValue.uppercased() }

  /// Matched by UTType, so `.jpg` and `.jpeg`, or `.tif` and `.tiff`, pick the same format.
  init?(fileExtension: String) {
    let type = UTType(filenameExtension: fileExtension.lowercased())
    guard let format = Self.allCases.first(where: { $0.type == type }) else { return nil }
    self = format
  }
}

/// The image on the general pasteboard, as the app that copied it provided it.
struct ClipboardImageData: Equatable {
  let data: Data
  let format: ClipboardImageFormat

  /// The formats to look for, `preferred` first. Original encodings come before TIFF, which
  /// apps often synthesize.
  static func readingOrder(preferring preferred: ClipboardImageFormat? = nil)
    -> [ClipboardImageFormat]
  {
    let order: [ClipboardImageFormat] = [.png, .jpeg, .heic, .tiff]
    guard let preferred else { return order }
    return [preferred] + order.filter { $0 != preferred }
  }

  /// Reads image types only, never text or files: the first in `readingOrder` the general
  /// pasteboard holds.
  static func readGeneralPasteboard(preferring preferred: ClipboardImageFormat? = nil) -> Self? {
    let order = readingOrder(preferring: preferred)
    let types = order.map { NSPasteboard.PasteboardType($0.type.identifier) }
    let board = NSPasteboard.general
    guard let type = board.availableType(from: types), let index = types.firstIndex(of: type),
      let data = board.data(forType: type)
    else { return nil }
    return Self(data: data, format: order[index])
  }
}

enum ClipboardSaveDestination: Equatable {
  /// A new file whose extension picks the format.
  case file(URL)
  case standardOutput(ClipboardImageFormat)
}

struct SavedClipboardImage: Equatable {
  let format: ClipboardImageFormat
  let bytes: Int
  /// False when the clipboard already held the format and its bytes were written unchanged.
  let converted: Bool
}

enum ClipboardSaveError: Error, Equatable, CustomStringConvertible {
  case noImage
  case unsupportedExtension(String)
  case terminal
  case conversionFailed(ClipboardImageFormat)

  var description: String {
    switch self {
    case .noImage: "The clipboard has no image. For text, use pbpaste."
    case .unsupportedExtension(let path):
      "\(path) must end in .png, .jpg, .jpeg, .tiff, .tif or .heic."
    case .terminal:
      "Refusing to write image data to a terminal. Redirect it, for example: "
        + "macarchy clipboard save - > image.png"
    case .conversionFailed(let format):
      "Could not convert the clipboard image to \(format.name). Nothing was written."
    }
  }
}

/// Saves whatever image the system clipboard holds now, so it works with or without Maccy.
@MainActor
struct ClipboardImageSaver {
  /// Reads the clipboard image, preferring the given format when the clipboard holds several.
  let clipboardImage: (ClipboardImageFormat) -> ClipboardImageData?
  let writeStandardOutput: (Data) throws -> Void
  let standardOutputIsTerminal: () -> Bool

  /// The destination is checked before the clipboard is read, and every failure writes nothing.
  /// A file is written exclusively, never replacing one, like `image prepare --output`.
  func save(to destination: ClipboardSaveDestination) throws -> SavedClipboardImage {
    let format: ClipboardImageFormat
    switch destination {
    case .file(let url):
      guard let matched = ClipboardImageFormat(fileExtension: url.pathExtension) else {
        throw ClipboardSaveError.unsupportedExtension(url.path)
      }
      try ImagePreparation.checkNewFile(url)
      format = matched
    case .standardOutput(let chosen):
      guard !standardOutputIsTerminal() else { throw ClipboardSaveError.terminal }
      format = chosen
    }
    guard let image = clipboardImage(format) else { throw ClipboardSaveError.noImage }
    let (data, converted) = try Self.convert(image, to: format)
    switch destination {
    case .file(let url): try ImagePreparation.writeNewFile(data, to: url)
    case .standardOutput: try writeStandardOutput(data)
    }
    return SavedClipboardImage(format: format, bytes: data.count, converted: converted)
  }

  /// Returns the clipboard bytes unchanged when they already have `format`. Otherwise ImageIO
  /// re-encodes the primary image at its own size and carries over its color profile and
  /// properties. JPEG has no alpha, so ImageIO composites transparency onto white.
  static func convert(_ image: ClipboardImageData, to format: ClipboardImageFormat) throws
    -> (data: Data, converted: Bool)
  {
    if image.format == format { return (image.data, false) }
    let output = NSMutableData()
    guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) > 0,
      let destination = CGImageDestinationCreateWithData(
        output, format.type.identifier as CFString, 1, nil)
    else { throw ClipboardSaveError.conversionFailed(format) }
    CGImageDestinationAddImageFromSource(
      destination, source, CGImageSourceGetPrimaryImageIndex(source), nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ClipboardSaveError.conversionFailed(format)
    }
    return (output as Data, true)
  }
}

extension ClipboardImageSaver {
  static var live: Self {
    Self(
      clipboardImage: { ClipboardImageData.readGeneralPasteboard(preferring: $0) },
      writeStandardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
      standardOutputIsTerminal: { isatty(STDOUT_FILENO) == 1 })
  }
}

extension SavedClipboardImage {
  /// `Saved the clipboard image to ~/Desktop/shot.png (PNG, 412 KB).`
  func message(savedTo output: URL) -> String {
    let path = (output.path as NSString).abbreviatingWithTildeInPath
    return "Saved the clipboard image to \(path) (\(format.name), \(PreparedImage.size(bytes)))."
  }

  func renderJSON(savedTo output: URL) throws -> String {
    let document: [String: Any] = [
      "status": "saved", "output": output.path, "format": format.type.identifier,
      "bytes": bytes, "converted": converted,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }
}
