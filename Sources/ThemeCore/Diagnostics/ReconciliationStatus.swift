import Darwin
import Foundation

public enum AdapterStatus: String, Codable, CaseIterable, Sendable {
  case applied
  case pending
  case restartRequired = "restart_required"
  case unsupported
  case disabled
  case drifted
  case failed
}

public enum AdapterRequirement: String, Codable, Sendable {
  case required
  case optional
}

public struct AdapterResult: Codable, Equatable, Sendable {
  public let adapterID: String
  public let requirement: AdapterRequirement
  public let status: AdapterStatus
  public let message: String?

  public init(
    adapterID: String,
    requirement: AdapterRequirement,
    status: AdapterStatus,
    message: String? = nil
  ) {
    self.adapterID = adapterID
    self.requirement = requirement
    self.status = status
    self.message = message
  }

  enum CodingKeys: String, CodingKey {
    case adapterID = "adapter_id"
    case requirement, status, message
  }
}

public struct ReconciliationRecord: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let generationID: String
  public let themeID: String
  public let results: [AdapterResult]

  init(manifest: GenerationManifest, results: [AdapterResult]) throws {
    let sorted = results.sorted { $0.adapterID < $1.adapterID }
    guard Set(sorted.map(\.adapterID)).count == sorted.count else {
      throw ReconciliationStatusError.duplicateAdapterID
    }
    schemaVersion = Self.currentSchemaVersion
    generationID = manifest.generationID
    themeID = manifest.themeID
    self.results = sorted
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case themeID = "theme_id"
    case results
  }
}

public enum ReconciliationState: Equatable, Sendable {
  case missing(activeGenerationID: String)
  case current(ReconciliationRecord)
  case stale(activeGenerationID: String, record: ReconciliationRecord)
}

public enum ReconciliationStatusError: Error, CustomStringConvertible, Sendable {
  case cannotReplace(Int32)
  case duplicateAdapterID
  case generationChanged(expected: String, active: String)
  case noActiveGeneration
  case unsupportedSchemaVersion(Int)

  public var description: String {
    switch self {
    case .cannotReplace(let code):
      "Cannot atomically replace reconciliation status (errno \(code)): \(String(cString: strerror(code)))"
    case .duplicateAdapterID:
      "Reconciliation results contain a duplicate adapter identifier"
    case .generationChanged(let expected, let active):
      "Cannot persist reconciliation for generation '\(expected)' because '\(active)' is active"
    case .noActiveGeneration:
      "Cannot read reconciliation status without an active generation"
    case .unsupportedSchemaVersion(let version):
      "Unsupported reconciliation status schema version \(version)"
    }
  }
}

public struct ReconciliationStatusStore: Sendable {
  private let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  public func persist(
    manifest: GenerationManifest,
    results: [AdapterResult]
  ) throws -> ReconciliationRecord {
    let record = try ReconciliationRecord(manifest: manifest, results: results)
    try requireActiveGeneration(manifest.generationID)

    let stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true
    )
    let statusURL = stateDirectory.appending(path: "reconciliation.json")
    let temporaryURL = stateDirectory.appending(
      path: ".reconciliation-\(UUID().uuidString.lowercased()).json")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(0x0a)
    try data.write(to: temporaryURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporaryURL.path
    )
    try requireActiveGeneration(manifest.generationID)

    let result = temporaryURL.path.withCString { source in
      statusURL.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw ReconciliationStatusError.cannotReplace(errno)
    }
    return record
  }

  public func read() throws -> ReconciliationState {
    let active = try activeManifest()
    let statusURL = root.appending(path: "state/reconciliation.json")
    guard FileManager.default.fileExists(atPath: statusURL.path) else {
      return .missing(activeGenerationID: active.generationID)
    }

    let record = try JSONDecoder().decode(
      ReconciliationRecord.self,
      from: Data(contentsOf: statusURL)
    )
    guard record.schemaVersion == ReconciliationRecord.currentSchemaVersion else {
      throw ReconciliationStatusError.unsupportedSchemaVersion(record.schemaVersion)
    }
    guard
      record.generationID == active.generationID,
      record.themeID == active.themeID
    else {
      return .stale(activeGenerationID: active.generationID, record: record)
    }
    return .current(record)
  }

  private func requireActiveGeneration(_ expectedGenerationID: String) throws {
    let activeGenerationID = try activeManifest().generationID
    guard activeGenerationID == expectedGenerationID else {
      throw ReconciliationStatusError.generationChanged(
        expected: expectedGenerationID,
        active: activeGenerationID
      )
    }
  }

  private func activeManifest() throws -> GenerationManifest {
    let url = root.appending(path: "current/manifest.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReconciliationStatusError.noActiveGeneration
    }
    return try JSONDecoder().decode(
      GenerationManifest.self,
      from: Data(contentsOf: url)
    )
  }
}
