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
      switch record.id {
      case Self.integrationID:
        try validateRegularFileRecord(
          record,
          target: context.kittyConfiguration,
          backupURL: context.backupURL,
          context: context
        )
      case Self.batSelectorID:
        try validateRegularFileRecord(
          record,
          target: context.batConfiguration,
          backupURL: context.batSelectorBackup,
          context: context
        )
      case Self.batThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.batThemeLink,
          destination: context.batThemeDestination
        )
      case Self.ezaEnvironmentID:
        try validateRegularFileRecord(
          record,
          target: context.shellConfiguration,
          backupURL: context.ezaEnvironmentBackup,
          context: context
        )
      case Self.ezaThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.ezaThemeLink,
          destination: context.ezaThemeDestination
        )
      case Self.btopThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.btopThemeLink,
          destination: context.btopThemeDestination
        )
      case Self.yaziSelectorID:
        try validateRegularFileRecord(
          record,
          target: context.yaziConfiguration,
          backupURL: context.yaziSelectorBackup,
          context: context
        )
      case Self.yaziFlavorLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.yaziFlavorLink,
          destination: context.yaziFlavorDestination
        )
      case Self.yaziSyntaxLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.yaziSyntaxLink,
          destination: context.yaziSyntaxDestination
        )
      case Self.atuinSelectorID:
        try validateRegularFileRecord(
          record,
          target: context.atuinConfiguration,
          backupURL: context.atuinSelectorBackup,
          context: context
        )
      case Self.atuinThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.atuinThemeLink,
          destination: context.atuinThemeDestination
        )
      case Self.neovimThemeLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.neovimThemeLink,
          destination: context.neovimThemeDestination
        )
      case Self.starshipConfigurationLinkID:
        try validateThemeLinkRecord(
          record,
          target: context.starshipConfigurationLink,
          destination: context.starshipBridgeDestination
        )
      default:
        throw SetupOwnershipError.invalidManifest("unknown integration \(record.id)")
      }
    }
    return manifest.records
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
    if records.isEmpty {
      try removeRegularFileIfPresent(
        context.manifestURL,
        unsafe: .invalidManifest("ownership path is not an ordinary file")
      )
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: context.manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(SetupOwnershipManifest(records: records)).write(
        to: context.manifestURL,
        options: .atomic
      )
    } catch {
      throw SetupOwnershipError.system(
        "write", context.manifestURL, String(describing: error))
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
    case regularFile = "regular_file"
    case symbolicLink = "symbolic_link"
  }

  enum Phase: String, Codable, Equatable {
    case applied
    case prepared
  }

  let id: String
  let phase: Phase
  let kind: Kind
  let targetPath: String
  let backupPath: String?
  let originalDigest: String?
  let installedDigest: String
  let linkDestination: String?

  var applied: SetupOwnershipRecord {
    SetupOwnershipRecord(
      id: id,
      phase: .applied,
      kind: kind,
      targetPath: targetPath,
      backupPath: backupPath,
      originalDigest: originalDigest,
      installedDigest: installedDigest,
      linkDestination: linkDestination
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
  }

  init(
    id: String,
    phase: Phase,
    kind: Kind,
    targetPath: String,
    backupPath: String?,
    originalDigest: String?,
    installedDigest: String,
    linkDestination: String?
  ) {
    self.id = id
    self.phase = phase
    self.kind = kind
    self.targetPath = targetPath
    self.backupPath = backupPath
    self.originalDigest = originalDigest
    self.installedDigest = installedDigest
    self.linkDestination = linkDestination
  }

}
