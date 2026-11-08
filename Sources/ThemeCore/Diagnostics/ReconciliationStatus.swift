import Darwin
import Foundation

public enum AdapterStatus: String, Codable, Sendable {
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
  public let carriedForwardFromGenerationID: String?

  public init(
    adapterID: String,
    requirement: AdapterRequirement,
    status: AdapterStatus,
    message: String? = nil,
    carriedForwardFromGenerationID: String? = nil
  ) {
    self.adapterID = adapterID
    self.requirement = requirement
    self.status = status
    self.message = message
    self.carriedForwardFromGenerationID = carriedForwardFromGenerationID
  }

  enum CodingKeys: String, CodingKey {
    case adapterID = "adapter_id"
    case requirement, status, message
    case carriedForwardFromGenerationID = "carried_forward_from_generation_id"
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
    try Self.validateCarriedGenerationIDs(sorted)
    schemaVersion = Self.currentSchemaVersion
    generationID = manifest.generationID
    themeID = manifest.themeID
    self.results = sorted
  }

  func validated() throws -> Self {
    guard Set(results.map(\.adapterID)).count == results.count else {
      throw ReconciliationStatusError.duplicateAdapterID
    }
    guard results == results.sorted(by: { $0.adapterID < $1.adapterID }) else {
      throw ReconciliationStatusError.nondeterministicResultOrder
    }
    try Self.validateCarriedGenerationIDs(results)
    return self
  }

  private static func validateCarriedGenerationIDs(_ results: [AdapterResult]) throws {
    guard
      results.allSatisfy({
        $0.carriedForwardFromGenerationID.map(isGenerationID) ?? true
      })
    else {
      throw ReconciliationStatusError.invalidStatus(
        "carried-forward generation identifier is invalid"
      )
    }
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

public enum ReconciliationStatusError: Error, CustomStringConvertible, Equatable, Sendable {
  case cannotReplace(Int32)
  case duplicateAdapterID
  case generationChanged(expected: String, active: String)
  case invalidActiveGeneration(String)
  case invalidStatus(String)
  case noActiveGeneration
  case nondeterministicResultOrder
  case unsupportedSchemaVersion(Int)

  public var description: String {
    switch self {
    case .cannotReplace(let code):
      "Cannot atomically replace reconciliation status (errno \(code)): \(String(cString: strerror(code)))"
    case .duplicateAdapterID:
      "Reconciliation results contain a duplicate adapter identifier"
    case .generationChanged(let expected, let active):
      "Cannot persist reconciliation for generation '\(expected)' because '\(active)' is active"
    case .invalidActiveGeneration(let reason):
      "Invalid active generation: \(reason)"
    case .invalidStatus(let reason):
      "Invalid reconciliation status: \(reason)"
    case .noActiveGeneration:
      "Reconciliation status requires an active generation"
    case .nondeterministicResultOrder:
      "Reconciliation results are not ordered by adapter identifier"
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

    try StateFile.replaceByRename(
      at: StateLayout(root: root).reconciliationStatus,
      temporaryName: ".reconciliation-\(UUID().uuidString.lowercased()).json",
      temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(record) },
      tooLargeError: ReconciliationStatusError.invalidStatus("exceeds the 1 MiB file limit"),
      beforeRename: { try requireActiveGeneration(manifest.generationID) },
      renameError: ReconciliationStatusError.cannotReplace
    )
    return record
  }

  public func read() throws -> ReconciliationState {
    let active = try ThemeGenerationReader(root: root).activeManifest()
    return try reconciliationState(for: active)
  }

  package func reconciliationState(
    for active: GenerationManifest
  ) throws -> ReconciliationState {
    let statusURL = StateLayout(root: root).reconciliationStatus
    let file: BoundedRegularFile?
    do {
      file = try BoundedRegularFile.readIfPresent(at: statusURL)
    } catch {
      throw ReconciliationStatusError.invalidStatus(String(describing: error))
    }
    guard let data = file?.data else { return .missing(activeGenerationID: active.generationID) }

    let decoded = try JSONDecoder().decode(
      ReconciliationRecord.self,
      from: data
    )
    guard decoded.schemaVersion == ReconciliationRecord.currentSchemaVersion else {
      throw ReconciliationStatusError.unsupportedSchemaVersion(decoded.schemaVersion)
    }
    let record = try decoded.validated()
    guard
      record.generationID == active.generationID,
      record.themeID == active.themeID
    else {
      return .stale(activeGenerationID: active.generationID, record: record)
    }
    return .current(record)
  }

  private func requireActiveGeneration(_ expectedGenerationID: String) throws {
    let activeGenerationID = try ThemeGenerationReader(root: root).activeManifest().generationID
    guard activeGenerationID == expectedGenerationID else {
      throw ReconciliationStatusError.generationChanged(
        expected: expectedGenerationID,
        active: activeGenerationID
      )
    }
  }

}
