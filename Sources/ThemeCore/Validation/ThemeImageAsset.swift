import Foundation
import ImageIO

enum ThemeImageAssetError: Error, CustomStringConvertible, Sendable {
  case mediaTypeMismatch
  case invalidDimensions
  case incompleteDecode

  var description: String {
    switch self {
    case .mediaTypeMismatch:
      "the bytes do not decode as the filename's PNG or JPEG type"
    case .invalidDimensions:
      "image dimensions must be positive, at most 16384 per side, and at most 64 megapixels"
    case .incompleteDecode:
      "ImageIO cannot fully decode the image"
    }
  }
}

enum ThemeImageAsset {
  static let maximumSize = 32 * 1_048_576
  static let maximumDimension = 16_384
  static let maximumPixels = 64_000_000

  static func load(at url: URL, format: ThemeBackgroundFormat) throws -> Data {
    let data = try BoundedRegularFile.read(at: url, maximumSize: maximumSize).data
    try validate(data: data, format: format)
    return data
  }

  private static func validate(data: Data, format: ThemeBackgroundFormat) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      (CGImageSourceGetType(source) as String?) == format.mediaType
    else {
      throw ThemeImageAssetError.mediaTypeMismatch
    }

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0,
      width <= maximumDimension, height <= maximumDimension,
      width.multipliedReportingOverflow(by: height).overflow == false,
      width * height <= maximumPixels
    else {
      throw ThemeImageAssetError.invalidDimensions
    }

    let options =
      [
        kCGImageSourceShouldCache: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let provider = image.dataProvider,
      provider.data != nil
    else {
      throw ThemeImageAssetError.incompleteDecode
    }
  }
}
