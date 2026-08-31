import CryptoKit
import Darwin
import Foundation

public struct GenerationManifest: Codable, Sendable {
  public static let currentSchemaVersion = 2
  package static let legacySchemaVersion = 1

  public let manifestSchemaVersion: Int
  public let generationID: String
  public let themeID: String
  public let themeSchemaVersion: Int
  public let inputDigest: String
  public let themeDigest: String
  public let background: GenerationBackground?
  public let rendererVersions: [String: Int]
  public let artifacts: [String: String]

  init(
    generationID: String,
    themeID: String,
    themeSchemaVersion: Int,
    inputDigest: String,
    themeDigest: String,
    background: GenerationBackground? = nil,
    rendererVersions: [String: Int],
    artifacts: [String: String]
  ) {
    manifestSchemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.themeID = themeID
    self.themeSchemaVersion = themeSchemaVersion
    self.inputDigest = inputDigest
    self.themeDigest = themeDigest
    self.background = background
    self.rendererVersions = rendererVersions
    self.artifacts = artifacts
  }

  static let encodedKeys = Set(CodingKeys.allCases.map(\.stringValue))
  private static let legacyEncodedKeys = encodedKeys.subtracting(["theme_digest", "background"])

  static func encodedKeys(schemaVersion: Int) -> Set<String>? {
    switch schemaVersion {
    case legacySchemaVersion: legacyEncodedKeys
    case currentSchemaVersion: encodedKeys
    default: nil
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case manifestSchemaVersion = "manifest_schema_version"
    case generationID = "generation_id"
    case themeID = "theme_id"
    case themeSchemaVersion = "theme_schema_version"
    case inputDigest = "input_digest"
    case themeDigest = "theme_digest"
    case background
    case rendererVersions = "renderer_versions"
    case artifacts
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    manifestSchemaVersion = try container.decode(Int.self, forKey: .manifestSchemaVersion)
    generationID = try container.decode(String.self, forKey: .generationID)
    themeID = try container.decode(String.self, forKey: .themeID)
    themeSchemaVersion = try container.decode(Int.self, forKey: .themeSchemaVersion)
    inputDigest = try container.decode(String.self, forKey: .inputDigest)
    themeDigest =
      manifestSchemaVersion == Self.legacySchemaVersion
      ? ""
      : try container.decode(String.self, forKey: .themeDigest)
    background = try container.decodeIfPresent(GenerationBackground.self, forKey: .background)
    rendererVersions = try container.decode([String: Int].self, forKey: .rendererVersions)
    artifacts = try container.decode([String: String].self, forKey: .artifacts)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(manifestSchemaVersion, forKey: .manifestSchemaVersion)
    try container.encode(generationID, forKey: .generationID)
    try container.encode(themeID, forKey: .themeID)
    try container.encode(themeSchemaVersion, forKey: .themeSchemaVersion)
    try container.encode(inputDigest, forKey: .inputDigest)
    if manifestSchemaVersion >= Self.currentSchemaVersion {
      try container.encode(themeDigest, forKey: .themeDigest)
      if let background {
        try container.encode(background, forKey: .background)
      } else {
        try container.encodeNil(forKey: .background)
      }
    }
    try container.encode(rendererVersions, forKey: .rendererVersions)
    try container.encode(artifacts, forKey: .artifacts)
  }
}

struct GenerationIntegrityError: Error, CustomStringConvertible, Sendable {
  let reason: String

  var description: String { reason }
}

extension GenerationManifest {
  func validateArtifacts(
    at generationURL: URL,
    requireReadOnlyGenerationDirectory: Bool = true
  ) throws {
    let metadata: [String: RenderedArtifactMetadata]
    do {
      metadata = try ThemeRenderer.validatedArtifactMetadata()
    } catch {
      throw GenerationIntegrityError(
        reason: "renderer artifact metadata is invalid: \(String(describing: error))"
      )
    }
    var requiredPaths: Set<String>
    do {
      requiredPaths = try ThemeRenderer.requiredOutputPaths(rendererVersions: rendererVersions)
      if manifestSchemaVersion == Self.legacySchemaVersion {
        requiredPaths.insert(WallpaperAdapter.outputPath)
      }
    } catch {
      throw GenerationIntegrityError(
        reason: "renderer artifact requirements are invalid: \(String(describing: error))"
      )
    }
    try requireIntegrity(
      Set(artifacts.keys).isSubset(of: Set(metadata.keys))
        && Set(artifacts.keys).isSuperset(of: requiredPaths),
      "artifact manifest is missing a required output or contains an unknown output"
    )
    try requireIntegrity(isSHA256Digest(inputDigest), "input digest is invalid")
    if manifestSchemaVersion == Self.currentSchemaVersion {
      try requireIntegrity(isSHA256Digest(themeDigest), "theme digest is invalid")
      try requireIntegrity(
        background.map { ThemeSchema.isThemeID($0.id) } ?? true,
        "background identifier is invalid"
      )
      try requireIntegrity(
        (background != nil) == (artifacts[WallpaperAdapter.outputPath] != nil),
        "background identity and wallpaper artifact presence disagree"
      )
    }
    if requireReadOnlyGenerationDirectory {
      try requireReadOnlyDirectory(generationURL, name: generationURL.lastPathComponent)
    } else {
      try requireDirectory(generationURL, name: generationURL.lastPathComponent)
    }
    try requireReadOnlyDirectory(
      generationURL.appending(path: "generated", directoryHint: .isDirectory),
      name: "generated"
    )

    for path in artifacts.keys.sorted() {
      let artifact: BoundedRegularFile
      do {
        guard let artifactMetadata = metadata[path] else {
          throw GenerationIntegrityError(reason: "unknown artifact path \(path)")
        }
        artifact = try BoundedRegularFile.read(
          at: generationURL.appending(path: path),
          maximumSize: artifactMetadata.maximumSize
        )
      } catch {
        throw GenerationIntegrityError(
          reason: "cannot safely read \(path): \(String(describing: error))"
        )
      }
      try requireIntegrity(artifact.permissions & 0o222 == 0, "\(path) is writable")
      try requireIntegrity(
        artifacts[path] == sha256Digest(artifact.data),
        "artifact digest does not match \(path)"
      )
      if path == WallpaperAdapter.outputPath, let background {
        do {
          try ThemeImageAsset.validateMediaType(data: artifact.data, format: background.format)
        } catch {
          throw GenerationIntegrityError(
            reason: "wallpaper artifact does not match background format: \(error)"
          )
        }
      }
    }
  }

  private func requireReadOnlyDirectory(_ url: URL, name: String) throws {
    let metadata = try directoryMetadata(url, name: name)
    try requireIntegrity(metadata.st_mode & 0o222 == 0, "\(name) is writable")
  }

  private func requireDirectory(_ url: URL, name: String) throws {
    _ = try directoryMetadata(url, name: name)
  }

  private func directoryMetadata(_ url: URL, name: String) throws -> stat {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      let code = errno
      throw GenerationIntegrityError(
        reason: "cannot inspect \(name) (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    try requireIntegrity(metadata.st_mode & S_IFMT == S_IFDIR, "\(name) is not a directory")
    return metadata
  }

  private func requireIntegrity(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw GenerationIntegrityError(reason: reason) }
  }
}

package func sha256Digest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func isSHA256Digest(_ value: String) -> Bool {
  let digest = value.dropFirst("sha256:".count)
  return value.hasPrefix("sha256:")
    && digest.count == 64
    && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
}

func isGenerationID(_ value: String) -> Bool {
  value.hasPrefix("g-")
    && value == value.lowercased()
    && UUID(uuidString: String(value.dropFirst(2))) != nil
}
