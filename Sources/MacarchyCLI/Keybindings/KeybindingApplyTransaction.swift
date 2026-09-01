import Darwin
import Foundation
import ThemeCore

enum KeybindingApplyOperation: String, Codable, Sendable {
  case adoptEntry = "adopt_entry"
  case installEntry = "install_entry"
  case teardownEntry = "teardown_entry"
  case updateGeneration = "update_generation"
}

enum KeybindingApplyPhase: String, Codable, Sendable {
  case staging
  case staged
  case currentSelected = "current_selected"
  case entryInstalled = "entry_installed"
  case entryRestored = "entry_restored"
  case activating
  case restorationFinalizing = "restoration_finalizing"
  case restorationFinalized = "restoration_finalized"
}

struct KeybindingApplyTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let operation: KeybindingApplyOperation
  let phase: KeybindingApplyPhase
  let generationID: String
  let previousGenerationID: String?
  let generationCreated: Bool

  init(
    operation: KeybindingApplyOperation,
    phase: KeybindingApplyPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool
  ) {
    schemaVersion = 1
    self.operation = operation
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
  }

  func withPhase(_ phase: KeybindingApplyPhase) -> Self {
    Self(
      operation: operation,
      phase: phase,
      generationID: generationID,
      previousGenerationID: previousGenerationID,
      generationCreated: generationCreated
    )
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case operation, phase
    case generationID = "generation_id"
    case previousGenerationID = "previous_generation_id"
    case generationCreated = "generation_created"
  }
}

struct KeybindingApplyTransactionStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
  }

  private var file: URL {
    directory.appending(path: "transaction.json")
  }

  func read() throws -> KeybindingApplyTransaction? {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: directory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer { Darwin.close(descriptor) }
    let data: Data
    do {
      data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: "transaction.json",
        url: file,
        maximumSize: 16_384
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw KeybindingApplyTransactionError.invalid("transaction root must be an object")
    }
    let allowed = Set(KeybindingApplyTransaction.CodingKeys.allCases.map(\.stringValue))
    let required = allowed.subtracting(["previous_generation_id"])
    guard Set(object.keys).isSubset(of: allowed), Set(object.keys).isSuperset(of: required) else {
      throw KeybindingApplyTransactionError.invalid("transaction fields are incomplete or unknown")
    }
    let transaction: KeybindingApplyTransaction
    do {
      transaction = try JSONDecoder().decode(KeybindingApplyTransaction.self, from: data)
    } catch {
      throw KeybindingApplyTransactionError.invalid(String(describing: error))
    }
    guard transaction.schemaVersion == 1 else {
      throw KeybindingApplyTransactionError.invalid("unsupported transaction schema")
    }
    guard KeybindingGenerationInspector.isGenerationID(transaction.generationID) else {
      throw KeybindingApplyTransactionError.invalid("transaction generation identity is invalid")
    }
    if let previous = transaction.previousGenerationID,
      !KeybindingGenerationInspector.isGenerationID(previous)
    {
      throw KeybindingApplyTransactionError.invalid(
        "transaction previous generation identity is invalid"
      )
    }
    if transaction.generationCreated,
      transaction.previousGenerationID == transaction.generationID
    {
      throw KeybindingApplyTransactionError.invalid(
        "a created generation cannot equal the previous generation"
      )
    }
    if !transaction.generationCreated,
      transaction.previousGenerationID != transaction.generationID
    {
      throw KeybindingApplyTransactionError.invalid(
        "an existing generation must equal the previous generation"
      )
    }
    if transaction.operation == .updateGeneration,
      transaction.previousGenerationID == nil
    {
      throw KeybindingApplyTransactionError.invalid(
        "generation update requires a previous generation"
      )
    }
    if transaction.operation == .updateGeneration,
      [
        .entryInstalled, .entryRestored, .restorationFinalizing, .restorationFinalized,
      ].contains(transaction.phase)
    {
      throw KeybindingApplyTransactionError.invalid(
        "generation update cannot contain an entry-change phase"
      )
    }
    if transaction.operation != .teardownEntry,
      transaction.phase == .entryRestored
    {
      throw KeybindingApplyTransactionError.invalid(
        "only teardown can contain an entry-restored phase"
      )
    }
    if transaction.operation == .installEntry || transaction.operation == .adoptEntry {
      guard transaction.phase != .entryRestored else {
        throw KeybindingApplyTransactionError.invalid(
          "entry installation cannot contain a teardown restoration phase"
        )
      }
    }
    if transaction.operation == .teardownEntry {
      guard
        transaction.previousGenerationID == transaction.generationID,
        !transaction.generationCreated,
        ![.staging, .entryInstalled].contains(transaction.phase)
      else {
        throw KeybindingApplyTransactionError.invalid(
          "teardown transaction generation or phase is invalid"
        )
      }
    }
    return transaction
  }

  func write(_ transaction: KeybindingApplyTransaction) throws {
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    defer { Darwin.close(stateDescriptor) }
    let descriptor = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: stateDescriptor,
      name: "keybindings",
      url: directory
    )
    defer { Darwin.close(descriptor) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: descriptor,
      name: "transaction.json",
      url: file,
      data: try encoder.encode(transaction),
      mode: 0o600
    )
  }

  func remove() throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    let removed = "transaction.json".withCString {
      Darwin.unlinkat(descriptor, $0, 0)
    }
    guard removed == 0 || errno == ENOENT else {
      throw KeybindingApplyTransactionError.system("remove transaction", file, errno)
    }
    guard fsync(descriptor) == 0 else {
      throw KeybindingApplyTransactionError.system("sync transaction removal", directory, errno)
    }
  }
}

enum KeybindingApplyTransactionError: Error, CustomStringConvertible, Sendable {
  case invalid(String)
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .invalid(let reason):
      "invalid keybinding apply transaction: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

struct KeybindingLifecycleEvidence: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let generationID: String
  let providerEntryPoint: String
  let providerTarget: String
  let action: KeybindingLifecycleAction
  let processID: Int32
  let executablePath: String
  let arguments: [String]

  init(
    generationID: String,
    providerEntryPoint: String,
    providerTarget: String,
    action: KeybindingLifecycleAction,
    process: KeybindingProcessInspection
  ) throws {
    guard
      process.status == .running,
      let processID = process.processID,
      let executablePath = process.executablePath
    else {
      throw KeybindingApplyTransactionError.invalid(
        "lifecycle evidence requires complete running process evidence"
      )
    }
    schemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.providerEntryPoint = providerEntryPoint
    self.providerTarget = providerTarget
    self.action = action
    self.processID = processID
    self.executablePath = executablePath
    arguments = process.arguments
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case providerEntryPoint = "provider_entry_point"
    case providerTarget = "provider_target"
    case action
    case processID = "process_id"
    case executablePath = "executable_path"
    case arguments
  }
}

enum KeybindingLifecycleEvidenceStatus: String, Encodable, Sendable {
  case matched
  case missing
  case stale
  case invalid
}

struct KeybindingLifecycleEvidenceInspection: Encodable, Equatable, Sendable {
  let status: KeybindingLifecycleEvidenceStatus
  let evidence: KeybindingLifecycleEvidence?
  let message: String
}

struct KeybindingLifecycleEvidenceStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "lifecycle.json") }

  func inspect(
    generation: KeybindingGenerationInspection,
    provider: KeybindingProviderInspection,
    process: KeybindingProcessInspection
  ) -> KeybindingLifecycleEvidenceInspection {
    do {
      guard let evidence = try read() else {
        return KeybindingLifecycleEvidenceInspection(
          status: .missing,
          evidence: nil,
          message: "No successful skhd lifecycle evidence has been recorded."
        )
      }
      guard
        generation.status == .current,
        evidence.generationID == generation.generationID,
        evidence.providerEntryPoint == provider.entryPoint,
        evidence.providerTarget == provider.expectedTarget,
        process.status == .running,
        evidence.processID == process.processID,
        evidence.executablePath == process.executablePath,
        evidence.arguments == process.arguments
      else {
        return KeybindingLifecycleEvidenceInspection(
          status: .stale,
          evidence: evidence,
          message: "Recorded skhd lifecycle evidence belongs to different canonical provider state."
        )
      }
      return KeybindingLifecycleEvidenceInspection(
        status: .matched,
        evidence: evidence,
        message:
          "The recorded \(evidence.action.rawValue) succeeded for generation "
          + "\(evidence.generationID) with observable process evidence."
      )
    } catch {
      return KeybindingLifecycleEvidenceInspection(
        status: .invalid,
        evidence: nil,
        message: "skhd lifecycle evidence is invalid: \(error)"
      )
    }
  }

  func write(_ evidence: KeybindingLifecycleEvidence) throws {
    guard
      evidence.schemaVersion == KeybindingLifecycleEvidence.currentSchemaVersion,
      KeybindingGenerationInspector.isGenerationID(evidence.generationID),
      evidence.action != .none,
      !evidence.providerEntryPoint.isEmpty,
      !evidence.providerTarget.isEmpty,
      evidence.processID > 0,
      evidence.executablePath == KeybindingProcessInspector.supportedExecutablePath,
      !evidence.arguments.isEmpty
    else {
      throw KeybindingApplyTransactionError.invalid("lifecycle evidence is incomplete")
    }
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    defer { Darwin.close(stateDescriptor) }
    let descriptor = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: stateDescriptor,
      name: "keybindings",
      url: directory
    )
    defer { Darwin.close(descriptor) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: descriptor,
      name: "lifecycle.json",
      url: file,
      data: try encoder.encode(evidence),
      mode: 0o600
    )
  }

  func remove() throws {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: directory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(descriptor) }
    let removed = "lifecycle.json".withCString { Darwin.unlinkat(descriptor, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw KeybindingApplyTransactionError.system("remove lifecycle evidence", file, errno)
    }
    guard fsync(descriptor) == 0 else {
      throw KeybindingApplyTransactionError.system(
        "sync lifecycle evidence removal",
        directory,
        errno
      )
    }
  }

  private func read() throws -> KeybindingLifecycleEvidence? {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: directory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer { Darwin.close(descriptor) }
    let data: Data
    do {
      data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: "lifecycle.json",
        url: file,
        maximumSize: 16_384
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw KeybindingApplyTransactionError.invalid("lifecycle evidence root must be an object")
    }
    let allowed = Set(KeybindingLifecycleEvidence.CodingKeys.allCases.map(\.stringValue))
    guard Set(object.keys) == allowed else {
      throw KeybindingApplyTransactionError.invalid(
        "lifecycle evidence fields are incomplete or unknown"
      )
    }
    let evidence = try JSONDecoder().decode(KeybindingLifecycleEvidence.self, from: data)
    guard
      evidence.schemaVersion == KeybindingLifecycleEvidence.currentSchemaVersion,
      KeybindingGenerationInspector.isGenerationID(evidence.generationID),
      evidence.action != .none,
      !evidence.providerEntryPoint.isEmpty,
      !evidence.providerTarget.isEmpty,
      evidence.processID > 0,
      evidence.executablePath == KeybindingProcessInspector.supportedExecutablePath,
      !evidence.arguments.isEmpty
    else {
      throw KeybindingApplyTransactionError.invalid("lifecycle evidence values are invalid")
    }
    return evidence
  }
}
