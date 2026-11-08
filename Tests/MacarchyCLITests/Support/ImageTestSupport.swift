import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

func bitmap(width: Int, height: Int, space: CFString = CGColorSpace.sRGB) throws
  -> CGContext
{
  let colorSpace = try #require(CGColorSpace(name: space))
  let context = try #require(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)))
  context.clear(CGRect(x: 0, y: 0, width: width, height: height))
  return context
}

/// Opaque 32-pixel tiles of varying color, so lossy encodings have detail to compress.
func patternImage(width: Int, height: Int, space: CFString = CGColorSpace.sRGB) throws
  -> CGImage
{
  let context = try bitmap(width: width, height: height, space: space)
  let tile = 32
  for x in stride(from: 0, to: width, by: tile) {
    for y in stride(from: 0, to: height, by: tile) {
      context.setFillColor(
        CGColor(
          srgbRed: CGFloat(x % 256) / 255, green: CGFloat(y % 256) / 255,
          blue: CGFloat((x + y) % 256) / 255, alpha: 1))
      context.fill(CGRect(x: x, y: y, width: tile, height: tile))
    }
  }
  return try #require(context.makeImage())
}

/// Transparent left half, opaque red right half.
func halfTransparentImage(width: Int, height: Int) throws -> CGImage {
  let context = try bitmap(width: width, height: height)
  context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
  return try #require(context.makeImage())
}

func encodeImages(
  _ images: [CGImage], as type: UTType, properties: [CFString: Any] = [:]
) throws -> Data {
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil))
  for image in images {
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  }
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}

func jpegData(_ image: CGImage, properties: [CFString: Any] = [:]) throws -> Data {
  try encodeImages([image], as: .jpeg, properties: properties)
}

func pngData(_ image: CGImage) throws -> Data {
  try encodeImages([image], as: .png)
}

func properties(of data: Data) throws -> [CFString: Any] {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

func formatOf(_ data: Data) throws -> String? {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  return CGImageSourceGetType(source) as String?
}

func dimensions(_ data: Data) throws -> [Int] {
  let found = try properties(of: data)
  return [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].map {
    (found[$0] as? NSNumber)?.intValue ?? 0
  }
}

func orientation(_ data: Data) throws -> Int {
  (try properties(of: data)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
}

func profileName(_ data: Data) throws -> String? {
  try properties(of: data)[kCGImagePropertyProfileName] as? String
}

/// RGBA of one pixel after drawing the decoded image into a premultiplied sRGB bitmap.
func pixel(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  let context = try bitmap(width: image.width, height: image.height)
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let bytes = try #require(context.data)
  let offset = y * context.bytesPerRow + x * 4
  return (0..<4).map { bytes.load(fromByteOffset: offset + $0, as: UInt8.self) }
}
