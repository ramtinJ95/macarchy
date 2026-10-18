import AppKit
import Foundation
import UniformTypeIdentifiers

/// The image formats Macarchy reads from the clipboard.
enum ClipboardImageFormat: String, CaseIterable {
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
}

/// The image on the general pasteboard, as the app that copied it provided it.
struct ClipboardImageData: Equatable {
  let data: Data
  let format: ClipboardImageFormat

  /// Reads image types only, never text or files. Original encodings come before TIFF, which
  /// apps often synthesize.
  static func readGeneralPasteboard() -> Self? {
    let order: [ClipboardImageFormat] = [.png, .jpeg, .heic, .tiff]
    let types = order.map { NSPasteboard.PasteboardType($0.type.identifier) }
    let board = NSPasteboard.general
    guard let type = board.availableType(from: types), let index = types.firstIndex(of: type),
      let data = board.data(forType: type)
    else { return nil }
    return Self(data: data, format: order[index])
  }
}
