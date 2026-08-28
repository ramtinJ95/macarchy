import CryptoKit
import Darwin
import Foundation

public struct GenerationManifest: Codable, Sendable {
  public static let currentSchemaVersion = 1

  public let manifestSchemaVersion: Int
  public let generationID: String
  public let themeID: String
  public let themeSchemaVersion: Int
  public let inputDigest: String
  public let rendererVersions: [String: Int]
  public let artifacts: [String: String]

  init(
    generationID: String,
    themeID: String,
    themeSchemaVersion: Int,
    inputDigest: String,
    rendererVersions: [String: Int],
    artifacts: [String: String]
  ) {
    manifestSchemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.themeID = themeID
    self.themeSchemaVersion = themeSchemaVersion
    self.inputDigest = inputDigest
    self.rendererVersions = rendererVersions
    self.artifacts = artifacts
  }

  static let encodedKeys = Set(CodingKeys.allCases.map(\.stringValue))

  enum CodingKeys: String, CodingKey, CaseIterable {
    case manifestSchemaVersion = "manifest_schema_version"
    case generationID = "generation_id"
    case themeID = "theme_id"
    case themeSchemaVersion = "theme_schema_version"
    case inputDigest = "input_digest"
    case rendererVersions = "renderer_versions"
    case artifacts
  }
}

struct GenerationIntegrityError: Error, CustomStringConvertible, Sendable {
  let reason: String

  var description: String { reason }
}

extension GenerationManifest {
  func validateArtifacts(at generationURL: URL) throws {
    let metadata: [String: RenderedArtifactMetadata]
    do {
      metadata = try ThemeRenderer.validatedArtifactMetadata()
    } catch {
      throw GenerationIntegrityError(
        reason: "renderer artifact metadata is invalid: \(String(describing: error))"
      )
    }
    let requiredPaths: Set<String>
    do {
      requiredPaths = try ThemeRenderer.requiredOutputPaths(rendererVersions: rendererVersions)
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
    try requireReadOnlyDirectory(generationURL, name: generationURL.lastPathComponent)
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
    }
  }

  private func requireReadOnlyDirectory(_ url: URL, name: String) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      let code = errno
      throw GenerationIntegrityError(
        reason: "cannot inspect \(name) (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    try requireIntegrity(metadata.st_mode & S_IFMT == S_IFDIR, "\(name) is not a directory")
    try requireIntegrity(metadata.st_mode & 0o222 == 0, "\(name) is writable")
  }

  private func requireIntegrity(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw GenerationIntegrityError(reason: reason) }
  }
}

package func sha256Digest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func isGenerationID(_ value: String) -> Bool {
  value.hasPrefix("g-")
    && value == value.lowercased()
    && UUID(uuidString: String(value.dropFirst(2))) != nil
}
