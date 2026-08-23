import Foundation

public struct RenderedTheme: Sendable {
  public let themeJSON: Data
  public let kittyConfiguration: String

  var files: [String: Data] {
    [
      ThemeRenderer.kittyOutputPath: Data(kittyConfiguration.utf8),
      ThemeRenderer.themeOutputPath: themeJSON,
    ]
  }
}

public struct ThemeRenderer: Sendable {
  static let kittyOutputPath = KittyAdapter.outputPath
  static let themeOutputPath = "theme.json"
  static let outputPaths = Set([kittyOutputPath, themeOutputPath])

  public init() {}

  public func render(package: ThemePackage, generationID: String) throws -> RenderedTheme {
    let normalized = NormalizedTheme(package: package, generationID: generationID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var json = try encoder.encode(normalized)
    json.append(0x0a)

    return RenderedTheme(
      themeJSON: json,
      kittyConfiguration: KittyAdapter.render(package: package)
    )
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
