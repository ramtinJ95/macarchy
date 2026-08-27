import Foundation

public struct RenderedTheme: Sendable {
  public let atuinTheme: String
  public let batTheme: String
  public let btopTheme: String
  let capabilities: Data
  public let ezaTheme: String
  public let herdrTheme: String?
  public let themeJSON: Data
  public let kittyConfiguration: String
  public let neovimTheme: String?
  public let piTheme: String
  public let sketchyBarPalette: String
  public let spicetifyTheme: String
  public let starshipPalette: String
  public let tuicrTheme: String
  public let wallpaper: Data
  public let yaziFlavor: String

  var files: [String: Data] {
    var files = [
      ThemeRenderer.atuinOutputPath: Data(atuinTheme.utf8),
      ThemeRenderer.batOutputPath: Data(batTheme.utf8),
      ThemeRenderer.btopOutputPath: Data(btopTheme.utf8),
      ThemeRenderer.capabilitiesOutputPath: capabilities,
      ThemeRenderer.ezaOutputPath: Data(ezaTheme.utf8),
      ThemeRenderer.kittyOutputPath: Data(kittyConfiguration.utf8),
      ThemeRenderer.piOutputPath: Data(piTheme.utf8),
      ThemeRenderer.sketchyBarOutputPath: Data(sketchyBarPalette.utf8),
      ThemeRenderer.spicetifyOutputPath: Data(spicetifyTheme.utf8),
      ThemeRenderer.starshipOutputPath: Data(starshipPalette.utf8),
      ThemeRenderer.themeOutputPath: themeJSON,
      ThemeRenderer.tuicrOutputPath: Data(tuicrTheme.utf8),
      ThemeRenderer.wallpaperOutputPath: wallpaper,
      ThemeRenderer.yaziFlavorOutputPath: Data(yaziFlavor.utf8),
      ThemeRenderer.yaziSyntaxOutputPath: Data(batTheme.utf8),
    ]
    if let herdrTheme {
      files[ThemeRenderer.herdrOutputPath] = Data(herdrTheme.utf8)
    }
    if let neovimTheme {
      files[ThemeRenderer.neovimOutputPath] = Data(neovimTheme.utf8)
    }
    return files
  }
}

public struct ThemeRenderer: Sendable {
  static let atuinOutputPath = AtuinAdapter.outputPath
  static let batOutputPath = BatAdapter.outputPath
  static let btopOutputPath = BtopAdapter.outputPath
  static let capabilitiesOutputPath = "generated/capabilities.json"
  static let ezaOutputPath = EzaAdapter.outputPath
  static let herdrOutputPath = HerdrAdapter.outputPath
  static let kittyOutputPath = KittyAdapter.outputPath
  static let neovimOutputPath = NeovimAdapter.outputPath
  static let piOutputPath = PiAdapter.outputPath
  static let sketchyBarOutputPath = SketchyBarAdapter.outputPath
  static let spicetifyOutputPath = SpicetifyAdapter.outputPath
  static let starshipOutputPath = StarshipAdapter.outputPath
  static let themeOutputPath = "theme.json"
  static let tuicrOutputPath = TuicrAdapter.outputPath
  static let wallpaperOutputPath = WallpaperAdapter.outputPath
  static let yaziFlavorOutputPath = YaziAdapter.flavorOutputPath
  static let yaziSyntaxOutputPath = YaziAdapter.syntaxOutputPath
  static let requiredOutputPaths = Set([
    atuinOutputPath, batOutputPath, btopOutputPath, ezaOutputPath,
    kittyOutputPath, piOutputPath, sketchyBarOutputPath,
    spicetifyOutputPath, starshipOutputPath, themeOutputPath, tuicrOutputPath, wallpaperOutputPath,
    yaziFlavorOutputPath, yaziSyntaxOutputPath,
  ])
  static let capabilityOutputPaths = Set([
    capabilitiesOutputPath, herdrOutputPath, neovimOutputPath,
  ])
  static let outputPaths = requiredOutputPaths.union(capabilityOutputPaths)

  public init() {}

  public func render(package: ThemePackage, generationID: String) throws -> RenderedTheme {
    try render(
      package: package,
      generationID: generationID,
      wallpaperData: package.wallpaperData,
      namedThemeFallbacks: [:]
    )
  }

  func render(
    package: ThemePackage,
    generationID: String,
    wallpaperData: Data,
    namedThemeFallbacks: [String: String] = [:]
  ) throws -> RenderedTheme {
    let normalized = NormalizedTheme(package: package, generationID: generationID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var json = try encoder.encode(normalized)
    json.append(0x0a)
    var capabilities = try encoder.encode(
      GeneratedThemeCapabilities(
        unsupportedAdapters: [HerdrAdapter.id, NeovimAdapter.id].filter {
          package.mappings[$0] == nil
        }
      )
    )
    capabilities.append(0x0a)

    return RenderedTheme(
      atuinTheme: AtuinAdapter.render(package: package),
      batTheme: BatAdapter.render(package: package),
      btopTheme: BtopAdapter.render(package: package),
      capabilities: capabilities,
      ezaTheme: EzaAdapter.render(package: package),
      herdrTheme: package.mappings[HerdrAdapter.id] == nil
        ? namedThemeFallbacks[HerdrAdapter.id] : try HerdrAdapter.render(package: package),
      themeJSON: json,
      kittyConfiguration: KittyAdapter.render(package: package),
      neovimTheme: package.mappings[NeovimAdapter.id] == nil
        ? namedThemeFallbacks[NeovimAdapter.id]
        : try NeovimAdapter.render(package: package, generationID: generationID),
      piTheme: try PiAdapter.render(package: package),
      sketchyBarPalette: SketchyBarAdapter.render(package: package),
      spicetifyTheme: SpicetifyAdapter.render(package: package),
      starshipPalette: StarshipAdapter.render(package: package),
      tuicrTheme: TuicrAdapter.render(package: package),
      wallpaper: wallpaperData,
      yaziFlavor: YaziAdapter.renderFlavor(package: package)
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

package struct GeneratedThemeCapabilities: Codable, Sendable {
  static let currentSchemaVersion = 1
  package static let namedThemeAdapterIDs = Set([HerdrAdapter.id, NeovimAdapter.id])

  let schemaVersion: Int
  let unsupportedAdapters: [String]

  init(unsupportedAdapters: [String]) {
    schemaVersion = Self.currentSchemaVersion
    self.unsupportedAdapters = unsupportedAdapters.sorted()
  }

  func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw GenerationIntegrityError(reason: "unsupported capabilities schema version")
    }
    guard unsupportedAdapters == unsupportedAdapters.sorted(),
      Set(unsupportedAdapters).count == unsupportedAdapters.count,
      Set(unsupportedAdapters).isSubset(of: Self.namedThemeAdapterIDs)
    else {
      throw GenerationIntegrityError(reason: "capabilities contain invalid adapter identifiers")
    }
    return self
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case unsupportedAdapters = "unsupported_adapters"
  }
}
