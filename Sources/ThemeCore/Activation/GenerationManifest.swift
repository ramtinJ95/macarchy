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
    try requireIntegrity(
      Set(artifacts.keys) == ThemeRenderer.outputPaths,
      "artifact manifest does not contain exactly the required outputs"
    )
    try requireReadOnlyDirectory(generationURL, name: generationURL.lastPathComponent)
    try requireReadOnlyDirectory(
      generationURL.appending(path: "generated", directoryHint: .isDirectory),
      name: "generated"
    )

    for path in ThemeRenderer.outputPaths.sorted() {
      let artifact: BoundedRegularFile
      do {
        artifact = try BoundedRegularFile.read(at: generationURL.appending(path: path))
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

func sha256Digest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
