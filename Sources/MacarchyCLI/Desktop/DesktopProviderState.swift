import Darwin
import Foundation
import ThemeCore

enum DesktopProviderPlanStatus: String, Codable, Sendable {
  case disabled
  case externallyManaged = "externally_managed"
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case recoveryRequired = "recovery_required"
  case blocked
}

struct DesktopProviderPlanInspection: Encodable, Sendable {
  let status: DesktopProviderPlanStatus
  let ownership: String
  let entryPoint: String
  let originalTarget: String?
  let source: String?
  let message: String
  let adoptionEvidenceDigest: String?

  static func result(
    _ status: DesktopProviderPlanStatus,
    ownership: String,
    entry: URL,
    originalTarget: String? = nil,
    source: String? = nil,
    message: String,
    adoptionEvidenceDigest: String? = nil
  ) -> Self {
    Self(
      status: status,
      ownership: ownership,
      entryPoint: entry.path,
      originalTarget: originalTarget,
      source: source,
      message: message,
      adoptionEvidenceDigest: adoptionEvidenceDigest
    )
  }

  enum CodingKeys: String, CodingKey {
    case status, ownership
    case entryPoint = "entry_point"
    case originalTarget = "original_target"
    case source, message
    case adoptionEvidenceDigest = "adoption_evidence_digest"
  }
}

enum DesktopOriginalKind: String, Codable, Sendable {
  case absent
  case regularFile = "regular_file"
  case entrySymlink = "entry_symlink"
  case directorySymlink = "directory_symlink"
}

/// Identity of a provider entry Macarchy adopted. The yabai and SketchyBar records persist
/// different JSON keys, so each keeps its own type and shares the identity rules here.
protocol DesktopAdoptionEvidence: Sendable {
  var kind: DesktopOriginalKind { get }
  var publicPath: String { get }
  var linkTarget: String? { get }
  var contentDigest: String? { get }
  var permissions: Int? { get }
  var device: UInt64? { get }
  var inode: UInt64? { get }
  var inventory: [String] { get }
  var volumeUUID: String? { get }

  init(
    kind: DesktopOriginalKind, publicPath: String, linkTarget: String?, contentDigest: String?,
    permissions: Int?, device: UInt64?, inode: UInt64?, inventory: [String], volumeUUID: String?)
}

extension DesktopAdoptionEvidence {
  static func capture(
    kind: DesktopOriginalKind,
    publicPath: URL,
    metadata: stat?,
    linkTarget: String? = nil,
    contentDigest: String? = nil,
    inventory: [String] = []
  ) throws -> Self {
    Self(
      kind: kind,
      publicPath: publicPath.path,
      linkTarget: linkTarget,
      contentDigest: contentDigest,
      permissions: metadata.map { Int($0.st_mode & 0o777) },
      device: metadata.map { UInt64($0.st_dev) },
      inode: metadata.map { UInt64($0.st_ino) },
      inventory: inventory,
      volumeUUID: try metadata.map {
        try RetainedOriginalIdentity.volumeUUID(at: publicPath, matching: $0)
      }
    )
  }

  /// Compare persisted identity after a reboot, not a same-operation approval snapshot.
  func matchesObserved(_ observed: Self?) -> Bool {
    guard let observed else { return false }
    return kind == observed.kind && publicPath == observed.publicPath
      && linkTarget == observed.linkTarget && contentDigest == observed.contentDigest
      && permissions == observed.permissions && inode == observed.inode
      && inventory == observed.inventory
      && (volumeUUID.map { $0 == observed.volumeUUID } ?? (device == observed.device))
  }

  var digest: String {
    var values: [String] = [
      kind.rawValue, publicPath, linkTarget ?? "", contentDigest ?? "",
      permissions.map(String.init) ?? "", device.map(String.init) ?? "",
      inode.map(String.init) ?? "",
    ]
    values += inventory
    if let volumeUUID {
      values.append(volumeUUID)
    }
    return lengthPrefixedSHA256Digest(values)
  }

  /// The file whose bytes `contentDigest` covers, for an entry named `entryName`.
  func sourceURL(directory: URL, entry: URL, entryName: String) -> URL? {
    switch kind {
    case .regularFile: entry
    case .entrySymlink: linkTarget.map { SymbolicLink.resolve($0, at: entry) }
    case .directorySymlink:
      linkTarget.map { SymbolicLink.resolve($0, at: directory).appending(path: entryName) }
    case .absent: nil
    }
  }
}

/// One JSON state record under the Desktop state root. Reads are bounded regular-file reads;
/// writes replace the file atomically. Each store keeps its own validation and errors.
struct DesktopStateFile: Sendable {
  let directory: URL
  let file: URL
  let maximumSize: Int

  init(stateRoot: URL, directory: String, name: String, maximumSize: Int) {
    self.directory = stateRoot.appending(path: directory, directoryHint: .isDirectory)
    file = self.directory.appending(path: name)
    self.maximumSize = maximumSize
  }

  var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

  func read<Value: Decodable>(_ type: Value.Type) throws -> Value? {
    guard exists else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: maximumSize).data
    return try JSONDecoder().decode(type, from: data)
  }

  func write(
    _ value: some Encodable, checkEncoded: (Data) throws -> Void = { _ in }
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try checkEncoded(data)
    try data.write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}

extension YabaiGenerationInspection {
  /// Whether the current generation was rendered from exactly these digests.
  func isCurrent(inputDigest: String?, renderedDigest: String?) -> Bool {
    status == .current && manifest?.inputDigest == inputDigest
      && manifest?.renderedDigest == renderedDigest
  }
}

extension SketchyBarGenerationInspection {
  /// Whether the current generation was rendered from exactly these digests.
  func isCurrent(inputDigest: String?, renderedDigest: String?) -> Bool {
    status == .current && manifest?.inputDigest == inputDigest
      && manifest?.renderedDigest == renderedDigest
  }
}

extension PortableProfile {
  /// The theme adapters whose output the selected desktop roles consume, sorted.
  var desktopThemeAdapterIDs: [String] {
    var ids = [String]()
    if desktop.provider == .yabaiSkhd { ids.append("wallpaper") }
    if topBar == .sketchybar { ids.append("sketchybar") }
    return ids.sorted()
  }
}
