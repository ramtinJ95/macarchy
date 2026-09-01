import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func readRecords(context: Context) throws -> [SetupOwnershipRecord] {
    guard try itemExists(context.manifestURL) else { return [] }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: context.manifestURL,
        maximumSize: 65_536
      ).data
    } catch {
      throw SetupOwnershipError.system(
        "read", context.manifestURL, String(describing: error))
    }
    do {
      return try validatedOwnershipRecords(from: data, context: context)
    } catch {
      throw error.setupReaderError
    }
  }

  func keybindingOwnershipRecord(context: Context) throws -> SetupOwnershipRecord? {
    try readRecords(context: context).first {
      $0.id == KeybindingProviderInspector.ownershipID
    }
  }

  func keybindingOwnershipRecord(
    from data: Data,
    context: Context
  ) throws(SetupOwnershipManifestValidationError) -> SetupOwnershipRecord? {
    try validatedOwnershipRecords(from: data, context: context).first {
      $0.id == KeybindingProviderInspector.ownershipID
    }
  }

  private func validatedOwnershipRecords(
    from data: Data,
    context: Context
  ) throws(SetupOwnershipManifestValidationError) -> [SetupOwnershipRecord] {
    let manifest: SetupOwnershipManifest
    do {
      try validateManifestKeys(data)
      manifest = try JSONDecoder().decode(SetupOwnershipManifest.self, from: data)
    } catch {
      throw SetupOwnershipManifestValidationError.invalidPayload(String(describing: error))
    }
    guard manifest.schemaVersion == SetupOwnershipManifest.currentSchemaVersion else {
      throw SetupOwnershipManifestValidationError.unsupportedSchema(manifest.schemaVersion)
    }
    guard Set(manifest.records.map(\.id)).count == manifest.records.count else {
      throw SetupOwnershipManifestValidationError.duplicateIntegrationIdentifiers
    }
    do {
      for record in manifest.records {
        try validateOwnershipRecord(record, context: context)
      }
    } catch {
      throw SetupOwnershipManifestValidationError.invalidRecord(error)
    }
    return manifest.records
  }

  func validateOwnershipRecord(
    _ record: SetupOwnershipRecord,
    context: Context
  ) throws {
    if record.id == KeybindingProviderInspector.ownershipID {
      try KeybindingProviderInspector.validateOwnershipRecord(record, context: context)
      return
    }
    guard
      record.originalKind == nil,
      record.originalLinkDestination == nil,
      record.originalFileMode == nil,
      record.originalMetadataDigest == nil,
      record.originalDevice == nil,
      record.originalInode == nil,
      record.originalSourceDigest == nil,
      record.originalInventory == nil,
      record.retainedOriginalPath == nil,
      record.claimNonce == nil
    else {
      throw SetupOwnershipError.invalidManifest(
        "non-keybinding integration \(record.id) contains keybinding adoption evidence"
      )
    }
    let steps = consumerSetupPlans(context: context).flatMap(\.steps)
    guard
      let step = steps.first(where: { $0.id == record.id }),
      let validate = step.validateOwnershipRecord
    else {
      throw SetupOwnershipError.invalidManifest("unknown integration \(record.id)")
    }
    try validate(record)
  }

  func validateManifestKeys(_ data: Data) throws {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data)
    } catch {
      return
    }
    guard let manifest = value as? [String: Any] else { return }
    let manifestKeys = Set(SetupOwnershipManifest.CodingKeys.allCases.map(\.stringValue))
    let unknownManifestKeys = Set(manifest.keys).subtracting(manifestKeys)
    guard unknownManifestKeys.isEmpty else {
      throw SetupOwnershipError.invalidManifest(
        "unknown manifest fields: \(unknownManifestKeys.sorted().joined(separator: ", "))"
      )
    }
    guard let records = manifest["records"] as? [[String: Any]] else { return }
    let recordKeys = Set(SetupOwnershipRecord.CodingKeys.allCases.map(\.stringValue))
    for (index, record) in records.enumerated() {
      let unknownRecordKeys = Set(record.keys).subtracting(recordKeys)
      guard unknownRecordKeys.isEmpty else {
        throw SetupOwnershipError.invalidManifest(
          "unknown fields in record \(index): \(unknownRecordKeys.sorted().joined(separator: ", "))"
        )
      }
    }
  }

  func save(
    record: SetupOwnershipRecord,
    records: inout [SetupOwnershipRecord],
    context: Context
  ) throws {
    records.removeAll { $0.id == record.id }
    records.append(record)
    records.sort { $0.id < $1.id }
    try persist(records: records, context: context)
  }

  func persist(records: [SetupOwnershipRecord], context: Context) throws {
    do {
      let stateRootDescriptor = try PinnedFilesystem.openDirectory(at: context.stateRoot)
      defer { Darwin.close(stateRootDescriptor) }
      let stateDirectory = context.stateRoot.appending(path: "state", directoryHint: .isDirectory)
      let stateDescriptor = try PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: stateRootDescriptor,
        name: "state",
        url: stateDirectory,
        mode: 0o700
      )
      defer { Darwin.close(stateDescriptor) }
      let setupDirectory = stateDirectory.appending(path: "setup", directoryHint: .isDirectory)
      let setupDescriptor = try PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: stateDescriptor,
        name: "setup",
        url: setupDirectory,
        mode: 0o700
      )
      defer { Darwin.close(setupDescriptor) }
      if records.isEmpty {
        let removed = "ownership.json".withCString {
          Darwin.unlinkat(setupDescriptor, $0, 0)
        }
        guard removed == 0 || errno == ENOENT, fsync(setupDescriptor) == 0 else {
          throw PinnedFilesystemError(
            operation: "remove setup ownership manifest",
            url: context.manifestURL,
            code: errno
          )
        }
        return
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try PinnedFilesystem.replaceRegularFileAtomically(
        parentDescriptor: setupDescriptor,
        name: "ownership.json",
        url: context.manifestURL,
        data: try encoder.encode(SetupOwnershipManifest(records: records)),
        mode: 0o600
      )
    } catch {
      throw SetupOwnershipError.system(
        "write", context.manifestURL, String(describing: error))
    }
  }

}

enum SetupOwnershipManifestValidationError: Error {
  case invalidPayload(String)
  case unsupportedSchema(Int)
  case duplicateIntegrationIdentifiers
  case invalidRecord(any Error)

  var setupReaderError: any Error {
    switch self {
    case .invalidPayload(let reason):
      SetupOwnershipError.invalidManifest(reason)
    case .unsupportedSchema(let version):
      SetupOwnershipError.invalidManifest("unsupported schema version \(version)")
    case .duplicateIntegrationIdentifiers:
      SetupOwnershipError.invalidManifest("integration identifiers must be unique")
    case .invalidRecord(let error):
      error
    }
  }

  var providerInspectionMessage: String {
    switch self {
    case .invalidPayload(let reason):
      "setup ownership evidence is invalid: \(reason)"
    case .unsupportedSchema:
      "setup ownership evidence has an unsupported schema"
    case .duplicateIntegrationIdentifiers:
      "setup ownership evidence contains duplicate integration identifiers"
    case .invalidRecord(let error):
      "setup ownership evidence contains an invalid record: \(error)"
    }
  }
}

struct SetupOwnershipManifest: Codable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let records: [SetupOwnershipRecord]

  init(records: [SetupOwnershipRecord]) {
    schemaVersion = Self.currentSchemaVersion
    self.records = records
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case records
  }
}

struct SetupOwnershipRecord: Codable, Equatable {
  enum Kind: String, Codable, Equatable {
    case jsonSelector = "json_selector"
    case regularFile = "regular_file"
    case spicetifySelection = "spicetify_selection"
    case symbolicLink = "symbolic_link"
  }

  enum Phase: String, Codable, Equatable {
    case applied
    case prepared
    case teardownPrepared = "teardown_prepared"
  }

  enum OriginalKind: String, Codable, Equatable {
    case absent
    case directorySymbolicLink = "directory_symbolic_link"
    case regularFile = "regular_file"
    case symbolicLink = "symbolic_link"
  }

  let id: String
  let phase: Phase
  let kind: Kind
  let targetPath: String
  let backupPath: String?
  let originalDigest: String?
  let installedDigest: String
  let linkDestination: String?
  let replacementDigest: String?
  let originalKind: OriginalKind?
  let originalLinkDestination: String?
  let originalFileMode: UInt16?
  let originalMetadataDigest: String?
  let originalDevice: UInt64?
  let originalInode: UInt64?
  let originalSourceDigest: String?
  let originalInventory: [String]?
  let retainedOriginalPath: String?
  let claimNonce: String?

  var applied: SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: id,
      phase: .applied,
      kind: kind,
      targetPath: targetPath,
      backupPath: backupPath,
      originalDigest: originalDigest,
      installedDigest: installedDigest,
      linkDestination: linkDestination,
      replacementDigest: nil,
      originalKind: originalKind,
      originalLinkDestination: originalLinkDestination,
      originalFileMode: originalFileMode,
      originalMetadataDigest: originalMetadataDigest,
      originalDevice: originalDevice,
      originalInode: originalInode,
      originalSourceDigest: originalSourceDigest,
      originalInventory: originalInventory,
      retainedOriginalPath: retainedOriginalPath,
      claimNonce: claimNonce
    )
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case phase
    case kind
    case targetPath = "target_path"
    case backupPath = "backup_path"
    case originalDigest = "original_digest"
    case installedDigest = "installed_digest"
    case linkDestination = "link_destination"
    case replacementDigest = "replacement_digest"
    case originalKind = "original_kind"
    case originalLinkDestination = "original_link_destination"
    case originalFileMode = "original_file_mode"
    case originalMetadataDigest = "original_metadata_digest"
    case originalDevice = "original_device"
    case originalInode = "original_inode"
    case originalSourceDigest = "original_source_digest"
    case originalInventory = "original_inventory"
    case retainedOriginalPath = "retained_original_path"
    case claimNonce = "claim_nonce"
  }

  init(
    id: String,
    phase: Phase,
    kind: Kind,
    targetPath: String,
    backupPath: String?,
    originalDigest: String?,
    installedDigest: String,
    linkDestination: String?,
    replacementDigest: String? = nil,
    originalKind: OriginalKind? = nil,
    originalLinkDestination: String? = nil,
    originalFileMode: UInt16? = nil,
    originalMetadataDigest: String? = nil,
    originalDevice: UInt64? = nil,
    originalInode: UInt64? = nil,
    originalSourceDigest: String? = nil,
    originalInventory: [String]? = nil,
    retainedOriginalPath: String? = nil,
    claimNonce: String? = nil
  ) {
    self.id = id
    self.phase = phase
    self.kind = kind
    self.targetPath = targetPath
    self.backupPath = backupPath
    self.originalDigest = originalDigest
    self.installedDigest = installedDigest
    self.linkDestination = linkDestination
    self.replacementDigest = replacementDigest
    self.originalKind = originalKind
    self.originalLinkDestination = originalLinkDestination
    self.originalFileMode = originalFileMode
    self.originalMetadataDigest = originalMetadataDigest
    self.originalDevice = originalDevice
    self.originalInode = originalInode
    self.originalSourceDigest = originalSourceDigest
    self.originalInventory = originalInventory
    self.retainedOriginalPath = retainedOriginalPath
    self.claimNonce = claimNonce
  }

}
