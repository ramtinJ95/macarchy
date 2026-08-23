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
