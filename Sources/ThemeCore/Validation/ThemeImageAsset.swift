import Foundation
import ImageIO

enum ThemeImageAssetError: Error, CustomStringConvertible, Sendable {
  case mediaTypeMismatch
  case invalidDimensions
  case incompleteDecode

  var description: String {
    switch self {
    case .mediaTypeMismatch:
      "the bytes do not decode as the filename's PNG, JPEG, or WebP type"
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
  private static let validationCache = ThemeImageValidationCache()

  static func load(at url: URL, format: ThemeBackgroundFormat) throws -> Data {
    let data = try BoundedRegularFile.read(at: url, maximumSize: maximumSize).data
    try validate(data: data, format: format)
    return data
  }

  static func validate(data: Data, format: ThemeBackgroundFormat) throws {
    let key = "\(format.rawValue):\(sha256Digest(data))"
    try validationCache.validate(key: key) {
      try validateUncached(data: data, format: format)
    }
  }

  private static func validateUncached(data: Data, format: ThemeBackgroundFormat) throws {
    let source = try source(data: data, format: format)

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

  static func validateMediaType(data: Data, format: ThemeBackgroundFormat) throws {
    _ = try source(data: data, format: format)
  }

  private static func source(
    data: Data,
    format: ThemeBackgroundFormat
  ) throws -> CGImageSource {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      (CGImageSourceGetType(source) as String?) == format.mediaType
    else {
      throw ThemeImageAssetError.mediaTypeMismatch
    }
    return source
  }
}

private final class ThemeImageValidationCache: @unchecked Sendable {
  private let condition = NSCondition()
  private var completed: Set<String> = []
  private var inProgress: Set<String> = []

  func validate(key: String, operation: () throws -> Void) throws {
    condition.lock()
    while inProgress.contains(key) {
      condition.wait()
    }
    if completed.contains(key) {
      condition.unlock()
      return
    }
    inProgress.insert(key)
    condition.unlock()

    do {
      try operation()
      condition.lock()
      inProgress.remove(key)
      completed.insert(key)
      condition.broadcast()
      condition.unlock()
    } catch {
      condition.lock()
      inProgress.remove(key)
      condition.broadcast()
      condition.unlock()
      throw error
    }
  }
}
