import Darwin
import Foundation
import ThemeCore

enum KeybindingApplyOperation: String, Codable, Sendable {
  case adoptEntry = "adopt_entry"
  case installEntry = "install_entry"
  case teardownEntry = "teardown_entry"
  case updateGeneration = "update_generation"

  /// Install and adopt are the operations that change the skhd entry point itself.
  var mutatesEntry: Bool { self == .installEntry || self == .adoptEntry }

  /// The lifecycle action that reactivates skhd after this operation's entry state changes.
  var reactivationLifecycle: KeybindingLifecycleAction {
    self == .updateGeneration ? .reload : .restart
  }
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

  var isRestorationFinalizing: Bool {
    self == .restorationFinalizing || self == .restorationFinalized
  }
}

struct KeybindingApplyTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let operation: KeybindingApplyOperation
  let phase: KeybindingApplyPhase
  let generationID: String
  let previousGenerationID: String?
  let generationCreated: Bool
  var service: UserServiceChange?

  init(
    operation: KeybindingApplyOperation,
    phase: KeybindingApplyPhase,
    generationID: String,
    previousGenerationID: String?,
    generationCreated: Bool,
    service: UserServiceChange? = nil
  ) {
    schemaVersion = service == nil ? 1 : 2
    self.operation = operation
    self.phase = phase
    self.generationID = generationID
    self.previousGenerationID = previousGenerationID
    self.generationCreated = generationCreated
    self.service = service
  }

  var isFinalizingTeardown: Bool {
    operation == .teardownEntry && phase.isRestorationFinalizing
  }

  func withPhase(_ phase: KeybindingApplyPhase) -> Self {
    Self(
      operation: operation,
      phase: phase,
      generationID: generationID,
      previousGenerationID: previousGenerationID,
      generationCreated: generationCreated,
      service: service
    )
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case operation, phase
    case generationID = "generation_id"
    case previousGenerationID = "previous_generation_id"
    case generationCreated = "generation_created"
    case service
  }
}

struct KeybindingApplyTransactionStore: Sendable {
  let stateRoot: URL

  private var files: KeybindingStateFiles { KeybindingStateFiles(stateRoot: stateRoot) }

  func read() throws -> KeybindingApplyTransaction? {
    guard let data = try files.read("transaction.json") else { return nil }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw KeybindingApplyTransactionError.invalid("transaction root must be an object")
    }
    let allowed = Set(KeybindingApplyTransaction.CodingKeys.allCases.map(\.stringValue))
    let required = allowed.subtracting(["previous_generation_id", "service"])
    guard Set(object.keys).isSubset(of: allowed), Set(object.keys).isSuperset(of: required) else {
      throw KeybindingApplyTransactionError.invalid("transaction fields are incomplete or unknown")
    }
    let transaction: KeybindingApplyTransaction
    do {
      transaction = try JSONDecoder().decode(KeybindingApplyTransaction.self, from: data)
    } catch {
      throw KeybindingApplyTransactionError.invalid(String(describing: error))
    }
    guard
      (transaction.schemaVersion == 1 && transaction.service == nil)
        || (transaction.schemaVersion == 2 && transaction.service != nil)
    else {
      throw KeybindingApplyTransactionError.invalid("unsupported transaction schema")
    }
    guard transaction.service?.isValid ?? true else {
      throw KeybindingApplyTransactionError.invalid("invalid service transaction evidence")
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
    try files.write(transaction, to: "transaction.json")
  }

  func remove() throws {
    try files.remove("transaction.json", label: "transaction", ignoringMissingDirectory: false)
  }
}

/// The JSON state files under `keybindings/` in the state root.
private struct KeybindingStateFiles {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
  }

  /// Returns nil when the directory or the file is absent.
  func read(_ name: String) throws -> Data? {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: directory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer { Darwin.close(descriptor) }
    do {
      return try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: name,
        url: directory.appending(path: name),
        maximumSize: 16_384
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
  }

  func write(_ value: some Encodable, to name: String) throws {
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
      name: name,
      url: directory.appending(path: name),
      data: try encoder.encode(value),
      mode: 0o600
    )
  }

  func remove(_ name: String, label: String, ignoringMissingDirectory: Bool) throws {
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: directory)
    } catch let error as PinnedFilesystemError
      where error.code == ENOENT && ignoringMissingDirectory
    {
      return
    }
    defer { Darwin.close(descriptor) }
    let removed = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw KeybindingApplyTransactionError.system(
        "remove \(label)",
        directory.appending(path: name),
        errno
      )
    }
    guard fsync(descriptor) == 0 else {
      throw KeybindingApplyTransactionError.system("sync \(label) removal", directory, errno)
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

  var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion
      && KeybindingGenerationInspector.isGenerationID(generationID)
      && [.start, .restart, .reload].contains(action)
      && !providerEntryPoint.isEmpty
      && !providerTarget.isEmpty
      && processID > 0
      && executablePath == KeybindingProcessInspector.supportedExecutablePath
      && !arguments.isEmpty
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

  private var files: KeybindingStateFiles { KeybindingStateFiles(stateRoot: stateRoot) }

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
    guard evidence.isValid else {
      throw KeybindingApplyTransactionError.invalid("lifecycle evidence is incomplete")
    }
    try files.write(evidence, to: "lifecycle.json")
  }

  func remove() throws {
    try files.remove("lifecycle.json", label: "lifecycle evidence", ignoringMissingDirectory: true)
  }

  private func read() throws -> KeybindingLifecycleEvidence? {
    guard let data = try files.read("lifecycle.json") else { return nil }
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
    guard evidence.isValid else {
      throw KeybindingApplyTransactionError.invalid("lifecycle evidence values are invalid")
    }
    return evidence
  }
}
