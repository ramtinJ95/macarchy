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
    let manifest: SetupOwnershipManifest
    do {
      try validateManifestKeys(data)
      manifest = try JSONDecoder().decode(SetupOwnershipManifest.self, from: data)
    } catch {
      throw SetupOwnershipError.invalidManifest(String(describing: error))
    }
    guard manifest.schemaVersion == SetupOwnershipManifest.currentSchemaVersion else {
      throw SetupOwnershipError.invalidManifest(
        "unsupported schema version \(manifest.schemaVersion)"
      )
    }
    guard Set(manifest.records.map(\.id)).count == manifest.records.count else {
      throw SetupOwnershipError.invalidManifest("integration identifiers must be unique")
    }
    for record in manifest.records {
      try validateOwnershipRecord(record, context: context)
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
      record.originalMetadataDigest == nil
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
      let stateDescriptor = try openOrCreateManifestDirectory(
        parentDescriptor: stateRootDescriptor,
        name: "state",
        url: stateDirectory
      )
      defer { Darwin.close(stateDescriptor) }
      let setupDirectory = stateDirectory.appending(path: "setup", directoryHint: .isDirectory)
      let setupDescriptor = try openOrCreateManifestDirectory(
        parentDescriptor: stateDescriptor,
        name: "setup",
        url: setupDirectory
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

  private func openOrCreateManifestDirectory(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> Int32 {
    do {
      return try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return try PinnedFilesystem.createDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url,
        mode: 0o700
      )
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
      originalMetadataDigest: originalMetadataDigest
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
    originalMetadataDigest: String? = nil
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
  }

}
