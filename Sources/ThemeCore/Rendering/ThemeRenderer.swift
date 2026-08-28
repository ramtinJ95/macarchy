import Foundation

public struct ThemeRenderer: Sendable {
  static let capabilitiesOutputPath = "generated/capabilities.json"
  static let themeOutputPath = "theme.json"
  static let artifactMetadata = [
    RenderedArtifactMetadata(path: AtuinAdapter.outputPath),
    RenderedArtifactMetadata(path: TextMateThemeArtifact.outputPath),
    RenderedArtifactMetadata(path: BtopAdapter.outputPath),
    RenderedArtifactMetadata(path: capabilitiesOutputPath, requirement: .optional),
    RenderedArtifactMetadata(path: EzaAdapter.outputPath),
    RenderedArtifactMetadata(
      path: HerdrAdapter.outputPath,
      requirement: .requiredWhenRendererVersion(renderer: .herdr, minimumVersion: 3)
    ),
    RenderedArtifactMetadata(path: KittyAdapter.outputPath),
    RenderedArtifactMetadata(
      path: NeovimAdapter.outputPath,
      requirement: .requiredWhenRendererVersion(renderer: .neovim, minimumVersion: 4)
    ),
    RenderedArtifactMetadata(path: PiAdapter.outputPath),
    RenderedArtifactMetadata(path: SketchyBarAdapter.outputPath),
    RenderedArtifactMetadata(
      path: SlackAdapter.outputPath,
      requirement: .requiredWhenRendererVersion(renderer: .slack, minimumVersion: 1)
    ),
    RenderedArtifactMetadata(path: SpicetifyAdapter.outputPath),
    RenderedArtifactMetadata(path: StarshipAdapter.outputPath),
    RenderedArtifactMetadata(path: themeOutputPath),
    RenderedArtifactMetadata(path: TuicrAdapter.outputPath),
    RenderedArtifactMetadata(
      path: WallpaperAdapter.outputPath,
      sizePolicy: .wallpaper
    ),
    RenderedArtifactMetadata(path: YaziAdapter.flavorOutputPath),
    RenderedArtifactMetadata(path: TextMateThemeArtifact.yaziOutputPath),
  ]

  static func validatedArtifactMetadata() throws -> [String: RenderedArtifactMetadata] {
    let collection = try RenderedTheme(
      artifacts: artifactMetadata.map { RenderedArtifact(metadata: $0, data: Data()) }
    )
    return Dictionary(uniqueKeysWithValues: collection.artifacts.map { ($0.path, $0.metadata) })
  }

  static func requiredOutputPaths(rendererVersions: [String: Int]) throws -> Set<String> {
    Set(
      try validatedArtifactMetadata().values.compactMap { metadata in
        metadata.requirement.isRequired(rendererVersions: rendererVersions)
          ? metadata.path : nil
      }
    )
  }

  public init() {}

  public func render(package: ThemePackage, generationID: String) throws -> RenderedTheme {
    try render(package: package, generationID: generationID, wallpaperData: package.wallpaperData)
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
    var capabilities = try encoder.encode(
      GeneratedThemeCapabilities(unsupportedAdapters: [])
    )
    capabilities.append(0x0a)
    let textMateTheme = TextMateThemeArtifact.render(package: package)
    let metadata = try Self.validatedArtifactMetadata()

    return try RenderedTheme(
      artifacts: [
        artifact(metadata, AtuinAdapter.outputPath, AtuinAdapter.render(package: package)),
        artifact(metadata, TextMateThemeArtifact.outputPath, textMateTheme),
        artifact(metadata, BtopAdapter.outputPath, BtopAdapter.render(package: package)),
        artifact(metadata, Self.capabilitiesOutputPath, capabilities),
        artifact(metadata, EzaAdapter.outputPath, EzaAdapter.render(package: package)),
        artifact(metadata, HerdrAdapter.outputPath, try HerdrAdapter.render(package: package)),
        artifact(metadata, KittyAdapter.outputPath, KittyAdapter.render(package: package)),
        artifact(
          metadata,
          NeovimAdapter.outputPath,
          try NeovimAdapter.render(package: package, generationID: generationID)
        ),
        artifact(metadata, PiAdapter.outputPath, try PiAdapter.render(package: package)),
        artifact(
          metadata,
          SketchyBarAdapter.outputPath,
          SketchyBarAdapter.render(package: package)
        ),
        artifact(metadata, SlackAdapter.outputPath, SlackAdapter.render(package: package)),
        artifact(
          metadata,
          SpicetifyAdapter.outputPath,
          SpicetifyAdapter.render(package: package)
        ),
        artifact(
          metadata,
          StarshipAdapter.outputPath,
          StarshipAdapter.render(package: package)
        ),
        artifact(metadata, Self.themeOutputPath, json),
        artifact(metadata, TuicrAdapter.outputPath, TuicrAdapter.render(package: package)),
        artifact(metadata, WallpaperAdapter.outputPath, wallpaperData),
        artifact(
          metadata,
          YaziAdapter.flavorOutputPath,
          YaziAdapter.renderFlavor(package: package)
        ),
        artifact(metadata, TextMateThemeArtifact.yaziOutputPath, textMateTheme),
      ]
    )
  }

  private func artifact(
    _ metadata: [String: RenderedArtifactMetadata],
    _ path: String,
    _ string: String
  ) throws -> RenderedArtifact {
    try artifact(metadata, path, Data(string.utf8))
  }

  private func artifact(
    _ metadata: [String: RenderedArtifactMetadata],
    _ path: String,
    _ data: Data
  ) throws -> RenderedArtifact {
    guard let artifactMetadata = metadata[path] else {
      throw RenderedArtifactCollectionError.missingMetadata(path)
    }
    return RenderedArtifact(metadata: artifactMetadata, data: data)
  }

  public func write(_ rendered: RenderedTheme, to outputRoot: URL) throws {
    try rendered.validateDataSizes()
    for artifact in rendered.artifacts {
      let output = outputRoot.appending(path: artifact.path)
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try artifact.data.write(to: output, options: .atomic)
    }
  }
}

package struct GeneratedThemeCapabilities: Codable, Sendable {
  static let currentSchemaVersion = 1
  // Both IDs remain valid for backward-compatible validation of M5 generations.
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
