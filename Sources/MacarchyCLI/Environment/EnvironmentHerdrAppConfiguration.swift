import Foundation
import ThemeCore

struct EnvironmentHerdrAppOwnership: Codable, Equatable, Sendable {
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
    _ = try JSONSerialization.jsonObject(with: data)
    return try JSONCObjectDocument(data: data, id: "herdr_app_configuration", target: url)
  }

  static func adopting(_ data: Data?, at url: URL) throws -> Self {
    let member = try data.flatMap { try document($0, at: url).memberBytes("theme") }.map {
      Data($0)
    }
    return Self(path: url.path, originalFileExisted: data != nil, originalMember: member)
  }
}

extension EnvironmentHerdrAppOwnership: EnvironmentStaticPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Herdr app settings",
    residueLabel: "Herdr app settings transaction residue",
    nonRegularMessage: "Herdr app settings are not an ordinary file")
  static let driftLabel = "Herdr app"
  static let ownershipChangedMessage = "Herdr app settings ownership changed unexpectedly"
  static let replacementLabel = "Herdr app theme member"
  static let replacementFailureLabel: String? = nil
  static let managedMember = Array(#""theme": "macarchy-current""#.utf8)

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.herdrApp }

  static func managed(from current: Data?, at url: URL) throws -> Data {
    guard let current else { return Data("{\n  \"theme\": \"macarchy-current\"\n}\n".utf8) }
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
        "Herdr app theme member edit would exceed the bounded settings size")
    }
    return data
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    return try Self.document(data, at: url).memberBytes("theme") == originalMember.map { Array($0) }
  }
}

/// The initial rendered palette also makes rollback independent of later generation collection.
/// Later refreshes use durable last-published evidence, independent of generation retention.
struct EnvironmentHerdrAppPaletteOwnership: Codable, Equatable, Sendable {
  let path: String
  let stateRoot: String
  let initialPalette: Data

  enum CodingKeys: String, CodingKey {
    case path
    case stateRoot = "state_root"
    case initialPalette = "initial_palette"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/") && stateRoot.hasPrefix("/")
      && initialPalette.count <= BoundedRegularFile.maximumSize
      && (try? JSONSerialization.jsonObject(with: initialPalette)) != nil
  }
}

extension EnvironmentHerdrAppPaletteOwnership: EnvironmentSelectedPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "Herdr app theme palette",
    residueLabel: "Herdr app theme palette transaction residue",
    nonRegularMessage: "Herdr app theme palette is not an ordinary file")
  static let driftLabel = "Herdr app theme palette"
  static let ownershipChangedMessage = "Herdr app theme palette ownership changed unexpectedly"
  static let replacementLabel = "Herdr app theme palette"
  static let replacementFailureLabel: String? = nil

  static func owned(by ownership: EnvironmentOwnership?) -> Self? { ownership?.herdrAppPalette }
  func managed(from current: Data?, at url: URL) throws -> Data { initialPalette }
  func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    try data == initialPalette
      || HerdrAppAdapter.matchesPublishedPalette(data, at: url, root: URL(filePath: stateRoot))
  }
  func restored(in current: Data, at url: URL) throws -> Data? {
    guard try matchesManaged(current, at: url) else { throw EnvironmentLifecycleError.drift(path) }
    return nil
  }
  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool { data == nil }
}

extension EnvironmentProviderInspector {
  func inspectHerdrApp(enabled: Bool, ownership: EnvironmentHerdrAppOwnership?, home: URL) throws
    -> KeyOwnedInspection<EnvironmentHerdrAppOwnership>
  {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    if enabled {
      try HerdrAppAdapter.requireConfigurationHome(
        ThemeConsumerPaths.herdrAppConfigurationDirectory(home: home))
      try HerdrAppAdapter.requireSupported(herdrAppVersion())
    }
    let url = ThemeConsumerPaths.herdrAppConfigurationDirectory(home: home).appending(
      path: "settings.json")
    guard try !hasSymlinkAncestor(url, stoppingAt: home) else {
      throw EnvironmentLifecycleError.blocked(
        "Herdr app adoption requires an ordinary settings path")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentHerdrAppOwnership.filesystem.read(url)
    let exact =
      try current.map { try EnvironmentHerdrAppOwnership.matchesManaged($0, at: url) } ?? false
    let proposed = try ownership ?? EnvironmentHerdrAppOwnership.adopting(current, at: url)
    let status: EnvironmentInspectionStatus =
      ownership == nil
      ? (current == nil ? .installRequired : .adoptionRequired)
      : (exact ? (enabled ? .managed : .restorationRequired) : .drifted)
    return (
      EnvironmentEntryInspection(
        id: "herdr_app_configuration", path: url.path, status: status,
        ownership: ownership == nil ? "external" : "macarchy",
        message:
          "Own only Herdr app's top-level theme member; preserve comments and unrelated settings.",
        evidence: evidence),
      enabled ? proposed : nil, ownership == nil ? evidence : nil
    )
  }

  func inspectHerdrAppPalette(
    enabled: Bool, ownership: EnvironmentHerdrAppPaletteOwnership?, home: URL, root: URL
  ) throws
    -> KeyOwnedInspection<EnvironmentHerdrAppPaletteOwnership>
  {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    let url = ThemeConsumerPaths.herdrAppConfigurationDirectory(home: home).appending(
      path: "themes/macarchy-current.json")
    guard try !hasSymlinkAncestor(url, stoppingAt: home) else {
      throw EnvironmentLifecycleError.blocked("Herdr app theme ownership requires an ordinary path")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentHerdrAppPaletteOwnership.filesystem.read(url)
    let proposed: EnvironmentHerdrAppPaletteOwnership
    let status: EnvironmentInspectionStatus
    if let ownership {
      proposed = ownership
      let exact = try current.map { try ownership.matchesManaged($0, at: url) } ?? false
      status = exact ? (enabled ? .managed : .restorationRequired) : .drifted
    } else {
      guard current == nil else {
        throw EnvironmentLifecycleError.blocked(
          "Herdr app themes/macarchy-current.json already exists without Macarchy ownership; move it before setup"
        )
      }
      let initial: Data
      if let bootstrapTheme {
        initial = Data(try HerdrAppAdapter.render(package: bootstrapTheme).utf8)
      } else {
        initial = try HerdrAppAdapter.activePalette(root: root)
      }
      proposed = EnvironmentHerdrAppPaletteOwnership(
        path: url.path, stateRoot: root.path, initialPalette: initial)
      status = .installRequired
    }
    return (
      EnvironmentEntryInspection(
        id: "herdr_app_palette", path: url.path, status: status,
        ownership: ownership == nil ? "external" : "macarchy",
        message:
          "Own the regular Macarchy theme palette file; replace it atomically for live reload.",
        evidence: evidence),
      enabled ? proposed : nil, ownership == nil ? evidence : nil
    )
  }
}
