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

  func validated() throws -> Self {
    guard Set(results.map(\.adapterID)).count == results.count else {
      throw ReconciliationStatusError.duplicateAdapterID
    }
    guard results == results.sorted(by: { $0.adapterID < $1.adapterID }) else {
      throw ReconciliationStatusError.nondeterministicResultOrder
    }
    return self
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
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw ReconciliationStatusError.invalidStatus("exceeds the 1 MiB file limit")
    }
    try data.write(to: temporaryURL)
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
    return try reconciliationState(for: active)
  }

  package func reconciliationState(
    for active: GenerationManifest
  ) throws -> ReconciliationState {
    let statusURL = root.appending(path: "state/reconciliation.json")
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: statusURL).data
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      return .missing(activeGenerationID: active.generationID)
    } catch {
      throw ReconciliationStatusError.invalidStatus(String(describing: error))
    }

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
    let activeGenerationID = try activeManifest().generationID
    guard activeGenerationID == expectedGenerationID else {
      throw ReconciliationStatusError.generationChanged(
        expected: expectedGenerationID,
        active: activeGenerationID
      )
    }
  }

  package func activeManifest() throws -> GenerationManifest {
    for _ in 0..<3 {
      let generationID = try activeGenerationID()
      let generationURL = root.appending(
        path: "generations/\(generationID)",
        directoryHint: .isDirectory
      )
      do {
        try requireDirectory(generationURL, role: "generation '\(generationID)'")
        let manifestFile = try BoundedRegularFile.read(
          at: generationURL.appending(path: "manifest.json")
        )
        guard manifestFile.permissions & 0o222 == 0 else {
          throw ReconciliationStatusError.invalidActiveGeneration("manifest.json is writable")
        }
        let manifest = try decodeActiveManifest(manifestFile.data, generationID: generationID)
        try manifest.validateArtifacts(at: generationURL)
        if try activeGenerationID() == generationID {
          return manifest
        }
      } catch {
        if (try? activeGenerationID()) != generationID { continue }
        if let error = error as? ReconciliationStatusError { throw error }
        throw ReconciliationStatusError.invalidActiveGeneration(String(describing: error))
      }
    }
    throw ReconciliationStatusError.invalidActiveGeneration(
      "current changed repeatedly while it was being read"
    )
  }

  private func activeGenerationID() throws -> String {
    let currentURL = root.appending(path: "current")
    var metadata = stat()
    guard lstat(currentURL.path, &metadata) == 0 else {
      let code = errno
      if code == ENOENT { throw ReconciliationStatusError.noActiveGeneration }
      throw ReconciliationStatusError.invalidActiveGeneration(
        "cannot inspect current (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else {
      throw ReconciliationStatusError.invalidActiveGeneration("current is not a symbolic link")
    }

    let destination: String
    do {
      destination = try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
    } catch {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "cannot read current symbolic link: \(String(describing: error))"
      )
    }
    let components = destination.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.count == 2,
      components[0] == "generations",
      isGenerationID(String(components[1]))
    else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "current target '\(destination)' is not generations/g-<uuid>"
      )
    }
    return String(components[1])
  }

  private func decodeActiveManifest(
    _ data: Data,
    generationID: String
  ) throws -> GenerationManifest {
    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let object, Set(object.keys) == GenerationManifest.encodedKeys else {
        throw ReconciliationStatusError.invalidActiveGeneration(
          "manifest.json contains unknown or missing fields"
        )
      }
      let manifest = try JSONDecoder().decode(GenerationManifest.self, from: data)
      guard manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion else {
        throw ReconciliationStatusError.invalidActiveGeneration(
          "unsupported manifest schema version \(manifest.manifestSchemaVersion)"
        )
      }
      guard manifest.generationID == generationID else {
        throw ReconciliationStatusError.invalidActiveGeneration(
          "manifest generation_id '\(manifest.generationID)' does not match '\(generationID)'"
        )
      }
      return manifest
    } catch let error as ReconciliationStatusError {
      throw error
    } catch {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "manifest.json cannot be decoded: \(String(describing: error))"
      )
    }
  }

  private func requireDirectory(_ url: URL, role: String) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      let code = errno
      throw ReconciliationStatusError.invalidActiveGeneration(
        "\(role) cannot be inspected (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
      throw ReconciliationStatusError.invalidActiveGeneration("\(role) is not a directory")
    }
  }

}
