import Foundation

public struct RenderedTheme: Sendable {
  public let batTheme: String
  public let ezaTheme: String
  public let themeJSON: Data
  public let kittyConfiguration: String
  public let sketchyBarPalette: String
  public let wallpaper: Data

  var files: [String: Data] {
    [
      ThemeRenderer.batOutputPath: Data(batTheme.utf8),
      ThemeRenderer.ezaOutputPath: Data(ezaTheme.utf8),
      ThemeRenderer.kittyOutputPath: Data(kittyConfiguration.utf8),
      ThemeRenderer.sketchyBarOutputPath: Data(sketchyBarPalette.utf8),
      ThemeRenderer.themeOutputPath: themeJSON,
      ThemeRenderer.wallpaperOutputPath: wallpaper,
    ]
  }
}

public struct ThemeRenderer: Sendable {
  static let batOutputPath = BatAdapter.outputPath
  static let ezaOutputPath = EzaAdapter.outputPath
  static let kittyOutputPath = KittyAdapter.outputPath
  static let sketchyBarOutputPath = SketchyBarAdapter.outputPath
  static let themeOutputPath = "theme.json"
  static let wallpaperOutputPath = WallpaperAdapter.outputPath
  static let outputPaths = Set([
    batOutputPath, ezaOutputPath, kittyOutputPath, sketchyBarOutputPath, themeOutputPath,
    wallpaperOutputPath,
  ])

  public init() {}

  public func render(package: ThemePackage, generationID: String) throws -> RenderedTheme {
    try render(
      package: package,
      generationID: generationID,
      wallpaperData: package.wallpaperData
    )
  }

  func render(
    package: ThemePackage,
    generationID: String,
    wallpaperData: Data
  ) throws -> RenderedTheme {
    let normalized = NormalizedTheme(package: package, generationID: generationID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var json = try encoder.encode(normalized)
    json.append(0x0a)

    return RenderedTheme(
      batTheme: BatAdapter.render(package: package),
      ezaTheme: EzaAdapter.render(package: package),
      themeJSON: json,
      kittyConfiguration: KittyAdapter.render(package: package),
      sketchyBarPalette: SketchyBarAdapter.render(package: package),
      wallpaper: wallpaperData
    )
  }

  static func maximumOutputSize(for path: String) -> Int {
    path == WallpaperAdapter.outputPath
      ? WallpaperAsset.maximumSize : BoundedRegularFile.maximumSize
  }

  public func write(_ rendered: RenderedTheme, to outputRoot: URL) throws {
    for (path, data) in rendered.files {
      let output = outputRoot.appending(path: path)
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: output, options: .atomic)
    }
  }
}
