import Foundation
import ImageIO
import TestSupport
import Testing

@testable import ThemeCore

let herdrReloadSuccess =
  #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"#
  + #""status":"applied","type":"config_reload"}}"#

/// Thrown inside an exit test: the child reports the reason and exits unsuccessfully after
/// its cleanup has run.
struct ExitTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// Built-in theme packages are immutable values, so tests share one load of each.
enum BuiltInThemePackages {
  static let catppuccinMocha = Result { try load("catppuccin-mocha") }
  static let tokyoNight = Result { try load("tokyo-night") }

  private static func load(_ id: String) throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(id)", directoryHint: .isDirectory))
  }
}

/// Re-encodes the first image of `png` as JPEG.
func jpegData(from png: Data) throws -> Data {
  let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  let output = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return output as Data
}

extension ThemePackage {
  /// The default background's bytes; the package must have one.
  var defaultBackgroundData: Data {
    guard let data = firstBackgroundData else {
      preconditionFailure("Theme package has no default background")
    }
    return data
  }
}

extension RenderedArtifactSizePolicy {
  /// The policy whose limit is exactly `maximumSize`, or nil when none has it.
  init?(maximumSize: Int) {
    guard
      let policy = [Self.ordinary, .wallpaper].first(where: { $0.maximumSize == maximumSize })
    else {
      return nil
    }
    self = policy
  }
}
