import Darwin
import Foundation
import ThemeCore

enum KeybindingApplyOperation: String, Codable, Sendable {
  case installEntry = "install_entry"
  case updateGeneration = "update_generation"
}

enum KeybindingApplyPhase: String, Codable, Sendable {
  case staged
  case currentSelected = "current_selected"
  case entryPrepared = "entry_prepared"
  case entryInstalled = "entry_installed"
  case activating
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
    return transaction
  }

  func write(_ transaction: KeybindingApplyTransaction) throws {
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
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
