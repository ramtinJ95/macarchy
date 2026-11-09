import Foundation
import ThemeCore

struct EnvironmentZedOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalMember: Data?

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalMember = "original_member"
  }

  var hasValidShape: Bool {
    guard path.hasPrefix("/"), originalFileExisted || originalMember == nil else { return false }
    guard let originalMember else { return true }
    guard originalMember.count <= BoundedRegularFile.maximumSize,
      let parsed = try? Self.document(
        Data("{".utf8) + originalMember + Data("}".utf8), at: URL(filePath: path))
    else { return false }
    return parsed.members.count == 1 && parsed.memberBytes("theme") == Array(originalMember)
  }

  static func document(_ data: Data, at url: URL) throws -> JSONCObjectDocument {
    try JSONCObjectDocument(data: data, id: "zed_configuration", target: url)
  }

  static func adopting(_ data: Data?, at url: URL) throws -> Self {
    let member = try data.flatMap { try document($0, at: url).memberBytes("theme") }.map {
      Data($0)
    }
    return Self(path: url.path, originalFileExisted: data != nil, originalMember: member)
  }
}

extension EnvironmentZedOwnership: EnvironmentStaticPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Zed settings", residueLabel: "Zed settings transaction residue",
    nonRegularMessage: "Zed settings are not an ordinary file")
  static let driftLabel = "Zed"
  static let ownershipChangedMessage = "Zed settings ownership changed unexpectedly"
  static let replacementLabel = "Zed theme member"
  static let replacementFailureLabel: String? = nil
  static let managedMember = Array(#""theme": "Macarchy""#.utf8)

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.zed }

  static func managed(from current: Data?, at url: URL) throws -> Data {
    guard let current else { return Data("{\n  \"theme\": \"Macarchy\"\n}\n".utf8) }
    let parsed = try document(current, at: url)
    let candidate =
      parsed.replacingMember("theme", with: managedMember)
      ?? parsed.insertingFirstMember(managedMember)
    return try bounded(candidate)
  }

  static func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try document(data, at: url).memberBytes("theme") == managedMember
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    guard try Self.matchesManaged(current, at: url) else {
      throw EnvironmentLifecycleError.drift(path)
    }
    let parsed = try Self.document(current, at: url)
    let restored =
      originalMember.flatMap { parsed.replacingMember("theme", with: Array($0)) }
      ?? parsed.removingMember("theme")!
    if !originalFileExisted, try Self.document(restored, at: url).members.isEmpty { return nil }
    return try Self.bounded(restored)
  }

  private static func bounded(_ data: Data) throws -> Data {
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw EnvironmentLifecycleError.blocked(
        "Zed theme member edit would exceed the bounded settings size")
    }
    return data
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try Self.document(data, at: url).memberBytes("theme") == originalMember.map { Array($0) }
  }
}

/// The initial rendered family also makes rollback independent of later generation collection.
/// Later refreshes use durable last-published evidence, independent of generation retention.
struct EnvironmentZedFamilyOwnership: Codable, Equatable, Sendable {
  let path: String
  let stateRoot: String
  let initialFamily: Data

  enum CodingKeys: String, CodingKey {
    case path
    case stateRoot = "state_root"
    case initialFamily = "initial_family"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/") && stateRoot.hasPrefix("/")
      && initialFamily.count <= BoundedRegularFile.maximumSize
      && (try? JSONSerialization.jsonObject(with: initialFamily)) != nil
  }
}

extension EnvironmentZedFamilyOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Zed theme family", residueLabel: "Zed theme family transaction residue",
    nonRegularMessage: "Zed theme family is not an ordinary file")
  static let driftLabel = "Zed theme family"
  static let ownershipChangedMessage = "Zed theme family ownership changed unexpectedly"
  static let replacementLabel = "Zed theme family"
  static let replacementFailureLabel: String? = nil

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.zedFamily }
  func managed(from current: Data?, at url: URL) throws -> Data { initialFamily }
  func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try data == initialFamily
      || ZedAdapter.matchesPublishedFamily(data, at: url, root: URL(filePath: stateRoot))
  }
  func restored(in current: Data, at url: URL) throws -> Data? {
    guard try matchesManaged(current, at: url) else { throw EnvironmentLifecycleError.drift(path) }
    return nil
  }
  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool { data == nil }
}

extension EnvironmentProviderInspector {
  func inspectZed(enabled: Bool, ownership: EnvironmentZedOwnership?, home: URL) throws
    -> KeyOwnedInspection<EnvironmentZedOwnership>
  {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    if enabled { try ZedAdapter.requireSupported(zedVersion()) }
    let url = ThemeConsumerPaths.zedConfigurationDirectory(home: home).appending(
      path: "settings.json")
    guard try !hasSymlinkAncestor(url, stoppingAt: home) else {
      throw EnvironmentLifecycleError.blocked("Zed adoption requires an ordinary settings path")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentZedOwnership.filesystem.read(url)
    let exact = try current.map { try EnvironmentZedOwnership.matchesManaged($0, at: url) } ?? false
    let proposed = try ownership ?? EnvironmentZedOwnership.adopting(current, at: url)
    let status: EnvironmentInspectionStatus =
      ownership == nil
      ? (current == nil ? .installRequired : .adoptionRequired)
      : (exact ? (enabled ? .managed : .restorationRequired) : .drifted)
    return (
      EnvironmentEntryInspection(
        id: "zed_configuration", path: url.path, status: status,
        ownership: ownership == nil ? "external" : "macarchy",
        message: "Own only Zed's top-level theme member; preserve comments and unrelated settings.",
        evidence: evidence),
      enabled ? proposed : nil, ownership == nil ? evidence : nil
    )
  }

  func inspectZedFamily(
    enabled: Bool, ownership: EnvironmentZedFamilyOwnership?, home: URL, root: URL
  ) throws
    -> KeyOwnedInspection<EnvironmentZedFamilyOwnership>
  {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    let url = ThemeConsumerPaths.zedConfigurationDirectory(home: home).appending(
      path: "themes/macarchy.json")
    guard try !hasSymlinkAncestor(url, stoppingAt: home) else {
      throw EnvironmentLifecycleError.blocked("Zed theme ownership requires an ordinary path")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentZedFamilyOwnership.filesystem.read(url)
    let proposed: EnvironmentZedFamilyOwnership
    let status: EnvironmentInspectionStatus
    if let ownership {
      proposed = ownership
      let exact = try current.map { try ownership.matchesManaged($0, at: url) } ?? false
      status = exact ? (enabled ? .managed : .restorationRequired) : .drifted
    } else {
      guard current == nil else {
        throw EnvironmentLifecycleError.blocked(
          "Zed themes/macarchy.json already exists without Macarchy ownership; move it before setup"
        )
      }
      let initial: Data
      if let bootstrapTheme {
        initial = Data(try ZedAdapter.render(package: bootstrapTheme).utf8)
      } else {
        initial = try ZedAdapter.activeFamily(root: root)
      }
      proposed = EnvironmentZedFamilyOwnership(
        path: url.path, stateRoot: root.path, initialFamily: initial)
      status = .installRequired
    }
    return (
      EnvironmentEntryInspection(
        id: "zed_family", path: url.path, status: status,
        ownership: ownership == nil ? "external" : "macarchy",
        message:
          "Own the regular Macarchy theme family file; replace it atomically for live reload.",
        evidence: evidence),
      enabled ? proposed : nil, ownership == nil ? evidence : nil
    )
  }
}
