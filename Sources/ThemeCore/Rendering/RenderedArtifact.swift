import Foundation

public struct RenderedArtifact: Sendable {
  public let path: String
  public let data: Data
  package let sizePolicy: RenderedArtifactSizePolicy
  package let requirement: RenderedArtifactRequirement

  package init(
    path: String,
    data: Data,
    sizePolicy: RenderedArtifactSizePolicy = .ordinary,
    requirement: RenderedArtifactRequirement = .required
  ) {
    self.path = path
    self.data = data
    self.sizePolicy = sizePolicy
    self.requirement = requirement
  }

  package init(metadata: RenderedArtifactMetadata, data: Data) {
    self.init(
      path: metadata.path,
      data: data,
      sizePolicy: metadata.sizePolicy,
      requirement: metadata.requirement
    )
  }

  package var maximumSize: Int { sizePolicy.maximumSize }

  package var metadata: RenderedArtifactMetadata {
    RenderedArtifactMetadata(
      path: path,
      sizePolicy: sizePolicy,
      requirement: requirement
    )
  }
}

public struct RenderedTheme: Sendable {
  public let artifacts: [RenderedArtifact]

  // Preserve the v0.3 ThemeCore rendering contract while artifacts become the
  // authoritative storage. New code should consume `artifacts` by path.
  public var atuinTheme: String { requiredString(atPath: AtuinAdapter.outputPath) }
  public var batTheme: String { requiredString(atPath: TextMateThemeArtifact.outputPath) }
  public var btopTheme: String { requiredString(atPath: BtopAdapter.outputPath) }
  public var ezaTheme: String { requiredString(atPath: EzaAdapter.outputPath) }
  public var herdrTheme: String { requiredString(atPath: HerdrAdapter.outputPath) }
  public var themeJSON: Data { requiredData(atPath: ThemeRenderer.themeOutputPath) }
  public var kittyConfiguration: String { requiredString(atPath: KittyAdapter.outputPath) }
  public var neovimTheme: String { requiredString(atPath: NeovimAdapter.outputPath) }
  public var piTheme: String { requiredString(atPath: PiAdapter.outputPath) }
  public var sketchyBarPalette: String { requiredString(atPath: SketchyBarAdapter.outputPath) }
  public var slackTheme: String { requiredString(atPath: SlackAdapter.outputPath) }
  public var spicetifyTheme: String { requiredString(atPath: SpicetifyAdapter.outputPath) }
  public var starshipPalette: String { requiredString(atPath: StarshipAdapter.outputPath) }
  public var tuicrTheme: String { requiredString(atPath: TuicrAdapter.outputPath) }
  public var wallpaper: Data? { artifact(atPath: WallpaperAdapter.outputPath)?.data }
  public var yaziFlavor: String { requiredString(atPath: YaziAdapter.flavorOutputPath) }

  package init(artifacts: [RenderedArtifact]) throws {
    var validatedPaths: [(path: String, components: [String])] = []
    for artifact in artifacts {
      guard Self.isValidPath(artifact.path) else {
        throw RenderedArtifactCollectionError.invalidPath(artifact.path)
      }
      guard artifact.data.count <= artifact.maximumSize else {
        throw RenderedArtifactCollectionError.dataTooLarge(
          path: artifact.path,
          size: artifact.data.count,
          maximumSize: artifact.maximumSize
        )
      }
      guard artifact.requirement.isValid else {
        throw RenderedArtifactCollectionError.invalidRequirement(path: artifact.path)
      }

      let components = Self.comparisonComponents(for: artifact.path)
      for existing in validatedPaths {
        if existing.path.utf8.elementsEqual(artifact.path.utf8) {
          throw RenderedArtifactCollectionError.duplicatePath(artifact.path)
        }
        if existing.components == components {
          throw RenderedArtifactCollectionError.equivalentPaths(
            existing.path,
            artifact.path
          )
        }
        if Self.isComponentPrefix(existing.components, of: components) {
          throw RenderedArtifactCollectionError.componentPrefixCollision(
            file: existing.path,
            descendant: artifact.path
          )
        }
        if Self.isComponentPrefix(components, of: existing.components) {
          throw RenderedArtifactCollectionError.componentPrefixCollision(
            file: artifact.path,
            descendant: existing.path
          )
        }
      }
      validatedPaths.append((artifact.path, components))
    }
    self.artifacts = artifacts
  }

  public func artifact(atPath path: String) -> RenderedArtifact? {
    artifacts.first { $0.path == path }
  }

  package var manifestArtifacts: [String: String] {
    Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, sha256Digest($0.data)) })
  }

  package func validateDataSizes() throws {
    for artifact in artifacts where artifact.data.count > artifact.maximumSize {
      throw RenderedArtifactCollectionError.dataTooLarge(
        path: artifact.path,
        size: artifact.data.count,
        maximumSize: artifact.maximumSize
      )
    }
  }

  private func requiredData(atPath path: String) -> Data {
    guard let artifact = artifact(atPath: path) else {
      preconditionFailure("Rendered theme is missing required artifact '\(path)'")
    }
    return artifact.data
  }

  private func requiredString(atPath path: String) -> String {
    String(decoding: requiredData(atPath: path), as: UTF8.self)
  }

  private static func isValidPath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  private static func comparisonComponents(for path: String) -> [String] {
    path.split(separator: "/").map {
      String($0)
        .decomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .decomposedStringWithCanonicalMapping
    }
  }

  private static func isComponentPrefix(_ prefix: [String], of path: [String]) -> Bool {
    prefix.count < path.count && zip(prefix, path).allSatisfy(==)
  }
}

package enum RenderedArtifactSizePolicy: Equatable, Sendable {
  case ordinary
  case wallpaper

  package init?(maximumSize: Int) {
    switch maximumSize {
    case BoundedRegularFile.maximumSize:
      self = .ordinary
    case WallpaperAsset.maximumSize:
      self = .wallpaper
    default:
      return nil
    }
  }

  package var maximumSize: Int {
    switch self {
    case .ordinary:
      BoundedRegularFile.maximumSize
    case .wallpaper:
      WallpaperAsset.maximumSize
    }
  }
}

package struct RenderedArtifactMetadata: Sendable {
  package let path: String
  package let sizePolicy: RenderedArtifactSizePolicy
  package let requirement: RenderedArtifactRequirement

  package init(
    path: String,
    sizePolicy: RenderedArtifactSizePolicy = .ordinary,
    requirement: RenderedArtifactRequirement = .required
  ) {
    self.path = path
    self.sizePolicy = sizePolicy
    self.requirement = requirement
  }

  package var maximumSize: Int { sizePolicy.maximumSize }
}

package enum RenderedArtifactRequirement: Equatable, Sendable {
  case required
  case requiredWhenRendererVersion(
    renderer: VersionGatedRendererIdentity,
    minimumVersion: Int
  )
  case optional

  package func isRequired(rendererVersions: [String: Int]) -> Bool {
    switch self {
    case .required:
      true
    case .requiredWhenRendererVersion(let renderer, let minimumVersion):
      rendererVersions[renderer.id, default: 0] >= minimumVersion
    case .optional:
      false
    }
  }

  fileprivate var isValid: Bool {
    switch self {
    case .required, .optional:
      true
    case .requiredWhenRendererVersion(_, let minimumVersion):
      minimumVersion > 0
    }
  }
}

package struct VersionGatedRendererIdentity: Equatable, Hashable, Sendable {
  package let id: String

  package init(id: String) {
    self.id = id
  }

  package static let herdr = VersionGatedRendererIdentity(id: HerdrAdapter.id)
  package static let neovim = VersionGatedRendererIdentity(id: NeovimAdapter.id)
  package static let slack = VersionGatedRendererIdentity(id: SlackAdapter.id)
}

package enum RenderedArtifactCollectionError: Error, CustomStringConvertible, Equatable, Sendable {
  case componentPrefixCollision(file: String, descendant: String)
  case dataTooLarge(path: String, size: Int, maximumSize: Int)
  case duplicatePath(String)
  case equivalentPaths(String, String)
  case invalidPath(String)
  case invalidRequirement(path: String)
  case missingMetadata(String)

  package var description: String {
    switch self {
    case .componentPrefixCollision(let file, let descendant):
      "Rendered artifact path '\(file)' is a file prefix of '\(descendant)'"
    case .dataTooLarge(let path, let size, let maximumSize):
      "Rendered artifact '\(path)' is \(size) bytes; maximum is \(maximumSize) bytes"
    case .duplicatePath(let path):
      "Rendered artifacts contain duplicate path '\(path)'"
    case .equivalentPaths(let first, let second):
      "Rendered artifact paths '\(first)' and '\(second)' are filesystem-equivalent"
    case .invalidPath(let path):
      "Rendered artifact path '\(path)' is not a safe relative path"
    case .invalidRequirement(let path):
      "Rendered artifact '\(path)' has an invalid requirement policy"
    case .missingMetadata(let path):
      "Rendered artifact '\(path)' has no declared metadata"
    }
  }
}
