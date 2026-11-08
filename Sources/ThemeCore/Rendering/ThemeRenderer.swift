import Foundation

public struct ThemeRenderer: Sendable {
  static let capabilitiesOutputPath = "generated/capabilities.json"
  static let themeOutputPath = "theme.json"
  // Renderers owned here rather than by the consumer catalog. Their IDs and versions are
  // persisted in generation manifests.
  private static let internalRenderers = [
    (
      id: "capabilities", version: 1,
      artifact: RenderedArtifactMetadata(path: capabilitiesOutputPath, requirement: .optional)
    ),
    (id: "normalized_theme", version: 1, artifact: RenderedArtifactMetadata(path: themeOutputPath)),
  ]
  static let internalRendererVersions = Dictionary(
    uniqueKeysWithValues: internalRenderers.map { ($0.id, $0.version) })
  private static let internalArtifactMetadata = internalRenderers.map { $0.artifact }
  private let catalog: ConsumerCatalog

  static func validatedArtifactMetadata(
    catalog: ConsumerCatalog = .shared
  ) throws -> [String: RenderedArtifactMetadata] {
    let collection = try RenderedTheme(
      artifacts: (catalog.artifactMetadata + internalArtifactMetadata).map {
        RenderedArtifact(metadata: $0, data: Data())
      }
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

  public init() {
    catalog = .shared
  }

  package init(catalog: ConsumerCatalog) {
    self.catalog = catalog
  }

  public func render(package: ThemePackage, generationID: String) throws -> RenderedTheme {
    try render(
      package: package,
      generationID: generationID,
      wallpaperData: package.firstBackgroundData
    )
  }

  func render(
    package: ThemePackage,
    generationID: String,
    wallpaperData: Data?
  ) throws -> RenderedTheme {
    let normalized = NormalizedTheme(package: package, generationID: generationID)
    let json = try prettyJSONDocument(normalized)
    let capabilities = try prettyJSONDocument(
      GeneratedThemeCapabilities(unsupportedAdapters: [])
    )
    let metadata = try Self.validatedArtifactMetadata(catalog: catalog)
    var artifacts = [
      try artifact(metadata, Self.capabilitiesOutputPath, capabilities),
      try artifact(metadata, Self.themeOutputPath, json),
    ]
    for entry in catalog.entries {
      guard let renderer = entry.renderer else { continue }
      if entry.id == .wallpaper, wallpaperData == nil { continue }
      let outputs = try renderer.render(package, generationID, wallpaperData)
      let expectedPaths = Set(renderer.artifacts.map(\.path))
      let outputPaths = outputs.map(\.path)
      guard Set(outputPaths) == expectedPaths, Set(outputPaths).count == outputPaths.count else {
        throw GenerationIntegrityError(
          reason: "renderer '\(renderer.id)' output does not match its declared artifacts"
        )
      }
      artifacts.append(
        contentsOf: try outputs.map { output in
          try artifact(metadata, output.path, output.data)
        }
      )
    }
    return try RenderedTheme(artifacts: artifacts)
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
  package static let namedThemeAdapterIDs =
    ConsumerCatalog.shared.namedThemeFallbackConsumerIDs

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
