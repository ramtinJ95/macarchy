import Darwin
import Foundation
import ThemeCore

enum YabaiProviderPlanStatus: String, Codable, Sendable {
  case disabled
  case externallyManaged = "externally_managed"
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case recoveryRequired = "recovery_required"
  case blocked
}

struct YabaiProviderPlanInspection: Encodable, Sendable {
  let status: YabaiProviderPlanStatus
  let ownership: String
  let entryPoint: String
  let originalTarget: String?
  let source: String?
  let message: String
  let adoptionEvidenceDigest: String?

  enum CodingKeys: String, CodingKey {
    case status, ownership
    case entryPoint = "entry_point"
    case originalTarget = "original_target"
    case source, message
    case adoptionEvidenceDigest = "adoption_evidence_digest"
  }
}

enum YabaiOriginalKind: String, Codable, Sendable {
  case absent
  case regularFile = "regular_file"
  case entrySymlink = "entry_symlink"
  case directorySymlink = "directory_symlink"
}

struct YabaiAdoptionEvidence: Codable, Equatable, Sendable {
  let kind: YabaiOriginalKind
  let publicPath: String
  let linkTarget: String?
  let contentDigest: String?
  let permissions: Int?
  let device: UInt64?
  let inode: UInt64?
  let inventory: [String]

  var digest: String {
    let values =
      [
        kind.rawValue, publicPath, linkTarget ?? "", contentDigest ?? "",
        permissions.map(String.init) ?? "", device.map(String.init) ?? "",
        inode.map(String.init) ?? "",
      ] + inventory
    var data = Data()
    for value in values {
      let bytes = Data(value.utf8)
      data.append(Data("\(bytes.count):".utf8))
      data.append(bytes)
    }
    return sha256Digest(data)
  }
}

struct YabaiOwnershipRecord: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let generationID: String
  let managedTarget: String
  let original: YabaiAdoptionEvidence
  let retainedOriginalPath: String?
  let createdConfigurationDirectory: Bool
  let priorServiceRunning: Bool

  init(
    generationID: String,
    managedTarget: String,
    original: YabaiAdoptionEvidence,
    retainedOriginalPath: String?,
    createdConfigurationDirectory: Bool,
    priorServiceRunning: Bool
  ) {
    schemaVersion = 1
    self.generationID = generationID
    self.managedTarget = managedTarget
    self.original = original
    self.retainedOriginalPath = retainedOriginalPath
    self.createdConfigurationDirectory = createdConfigurationDirectory
    self.priorServiceRunning = priorServiceRunning
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case managedTarget = "managed_target"
    case original
    case retainedOriginalPath = "retained_original_path"
    case createdConfigurationDirectory = "created_configuration_directory"
    case priorServiceRunning = "prior_service_running"
  }
}

struct YabaiOwnershipStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "ownership.json") }

  func read() throws -> YabaiOwnershipRecord? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 32_768).data
    let record = try JSONDecoder().decode(YabaiOwnershipRecord.self, from: data)
    guard
      record.schemaVersion == 1,
      YabaiGenerationInspector.isGenerationID(record.generationID),
      record.original.publicPath.hasPrefix("/"),
      (record.original.kind == .absent) == (record.retainedOriginalPath == nil)
    else {
      throw YabaiDesktopError.invalidState("yabai ownership record is invalid")
    }
    return record
  }

  func write(_ record: YabaiOwnershipRecord) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}

struct YabaiProviderPlanInspector: Sendable {
  func inspect(
    homeDirectory: URL,
    stateRoot: URL,
    enabled: Bool,
    transactionPending: Bool = false
  ) -> YabaiProviderPlanInspection {
    let directory = homeDirectory.appending(path: ".config/yabai", directoryHint: .isDirectory)
    let entry = directory.appending(path: "yabairc")
    if transactionPending {
      return result(
        .recoveryRequired,
        ownership: "transaction_pending",
        entry: entry,
        message: "an interrupted yabai transaction must be recovered before planning changes"
      )
    }
    do {
      let ownership = try YabaiOwnershipStore(stateRoot: stateRoot).read()
      if !enabled {
        return ownership.map { inspectManaged($0, entry: entry) }
          ?? inspectDisabled(directory: directory, entry: entry)
      }
      if let ownership {
        return inspectManaged(ownership, entry: entry)
      }
      let evidence = try captureUnowned(directory: directory, entry: entry)
      switch evidence.kind {
      case .absent:
        return result(
          .installRequired,
          ownership: "absent",
          entry: entry,
          message: "no yabai configuration entry exists"
        )
      case .regularFile, .entrySymlink, .directorySymlink:
        return result(
          .adoptionRequired,
          ownership: evidence.kind.rawValue,
          entry: entry,
          originalTarget: evidence.linkTarget,
          source: sourceURL(for: evidence, directory: directory, entry: entry)?.path,
          message: "existing \(evidence.kind.rawValue) requires explicit adoption",
          adoptionEvidenceDigest: evidence.digest
        )
      }
    } catch {
      return result(
        .blocked,
        ownership: "uninspectable",
        entry: entry,
        message: String(describing: error)
      )
    }
  }

  func captureUnowned(directory: URL, entry: URL) throws -> YabaiAdoptionEvidence {
    var directoryMetadata = stat()
    guard lstat(directory.path, &directoryMetadata) == 0 else {
      if errno == ENOENT {
        return evidence(kind: .absent, publicPath: entry, metadata: nil)
      }
      throw YabaiDesktopError.system("inspect yabai configuration directory", directory, errno)
    }
    switch directoryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      guard directoryMetadata.st_nlink == 1, let target = readLink(directory) else {
        throw YabaiDesktopError.invalidState(
          "yabai directory symlink is not singly linked and readable")
      }
      let resolved = resolveLink(target, at: directory)
      let inventory = try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted()
      guard inventory == ["yabairc"] else {
        throw YabaiDesktopError.invalidState(
          "directory-symlink adoption requires only yabairc; found \(inventory.isEmpty ? "no entries" : inventory.joined(separator: ", "))"
        )
      }
      let source = resolved.appending(path: "yabairc")
      let data = try BoundedRegularFile.read(at: source).data
      return evidence(
        kind: .directorySymlink,
        publicPath: directory,
        metadata: directoryMetadata,
        linkTarget: target,
        contentDigest: sha256Digest(data),
        inventory: inventory
      )
    case S_IFDIR:
      break
    default:
      throw YabaiDesktopError.invalidState(
        "yabai configuration path is not a directory or directory symlink")
    }

    var entryMetadata = stat()
    guard lstat(entry.path, &entryMetadata) == 0 else {
      if errno == ENOENT {
        return evidence(kind: .absent, publicPath: entry, metadata: nil)
      }
      throw YabaiDesktopError.system("inspect yabairc", entry, errno)
    }
    guard entryMetadata.st_nlink == 1 else {
      throw YabaiDesktopError.invalidState("yabairc must have exactly one link")
    }
    switch entryMetadata.st_mode & S_IFMT {
    case S_IFREG:
      let data = try BoundedRegularFile.read(at: entry).data
      return evidence(
        kind: .regularFile,
        publicPath: entry,
        metadata: entryMetadata,
        contentDigest: sha256Digest(data)
      )
    case S_IFLNK:
      guard let target = readLink(entry) else {
        throw YabaiDesktopError.invalidState("cannot read yabairc symlink")
      }
      let source = resolveLink(target, at: entry)
      let data = try BoundedRegularFile.read(at: source).data
      return evidence(
        kind: .entrySymlink,
        publicPath: entry,
        metadata: entryMetadata,
        linkTarget: target,
        contentDigest: sha256Digest(data)
      )
    default:
      throw YabaiDesktopError.invalidState("yabairc is not a regular file or symbolic link")
    }
  }

  static func managedTarget(homeDirectory: URL, stateRoot: URL) -> String {
    let canonical = homeDirectory.appending(path: ".config/macarchy").standardizedFileURL
    if canonical == stateRoot.standardizedFileURL {
      return "../macarchy/desktop/yabai/current/yabairc"
    }
    return stateRoot.appending(path: "desktop/yabai/current/yabairc").path
  }

  private func inspectManaged(
    _ ownership: YabaiOwnershipRecord,
    entry: URL
  ) -> YabaiProviderPlanInspection {
    guard isManagedEntry(entry, target: ownership.managedTarget) else {
      return result(
        .blocked,
        ownership: "ownership_drift",
        entry: entry,
        message: "owned yabairc no longer matches the managed target"
      )
    }
    if ownership.retainedOriginalPath != nil {
      do {
        try YabaiProviderTransaction.authenticateRetained(ownership)
      } catch {
        return result(
          .blocked,
          ownership: "retained_original_drift",
          entry: entry,
          message: String(describing: error)
        )
      }
    }
    return result(
      .managed,
      ownership: "managed",
      entry: entry,
      message: "the yabai provider entry is owned by Macarchy"
    )
  }

  private func inspectDisabled(directory: URL, entry: URL) -> YabaiProviderPlanInspection {
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0 else {
      return result(
        errno == ENOENT ? .disabled : .externallyManaged,
        ownership: errno == ENOENT ? "absent" : "uninspectable",
        entry: entry,
        message: errno == ENOENT
          ? "desktop role is disabled and no yabai configuration exists"
          : "desktop role is disabled; uninspectable yabai state remains externally managed"
      )
    }
    return result(
      .externallyManaged,
      ownership: "external",
      entry: entry,
      message: "desktop role is disabled; existing yabai state remains externally managed"
    )
  }

  private func evidence(
    kind: YabaiOriginalKind,
    publicPath: URL,
    metadata: stat?,
    linkTarget: String? = nil,
    contentDigest: String? = nil,
    inventory: [String] = []
  ) -> YabaiAdoptionEvidence {
    YabaiAdoptionEvidence(
      kind: kind,
      publicPath: publicPath.path,
      linkTarget: linkTarget,
      contentDigest: contentDigest,
      permissions: metadata.map { Int($0.st_mode & 0o777) },
      device: metadata.map { UInt64($0.st_dev) },
      inode: metadata.map { UInt64($0.st_ino) },
      inventory: inventory
    )
  }

  private func sourceURL(
    for evidence: YabaiAdoptionEvidence,
    directory: URL,
    entry: URL
  ) -> URL? {
    switch evidence.kind {
    case .regularFile: entry
    case .entrySymlink: evidence.linkTarget.map { resolveLink($0, at: entry) }
    case .directorySymlink:
      evidence.linkTarget.map { resolveLink($0, at: directory).appending(path: "yabairc") }
    case .absent: nil
    }
  }

  private func isManagedEntry(_ entry: URL, target: String) -> Bool {
    var metadata = stat()
    return lstat(entry.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFLNK
      && readLink(entry) == target
  }

  private func readLink(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private func resolveLink(_ target: String, at link: URL) -> URL {
    if target.hasPrefix("/") { return URL(filePath: target).standardizedFileURL }
    return link.deletingLastPathComponent().appending(path: target).standardizedFileURL
  }

  private func result(
    _ status: YabaiProviderPlanStatus,
    ownership: String,
    entry: URL,
    originalTarget: String? = nil,
    source: String? = nil,
    message: String,
    adoptionEvidenceDigest: String? = nil
  ) -> YabaiProviderPlanInspection {
    YabaiProviderPlanInspection(
      status: status,
      ownership: ownership,
      entryPoint: entry.path,
      originalTarget: originalTarget,
      source: source,
      message: message,
      adoptionEvidenceDigest: adoptionEvidenceDigest
    )
  }
}

enum YabaiDesktopError: Error, CustomStringConvertible, Sendable {
  case invalidState(String)
  case lifecycle(String)
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .invalidState(let reason): reason
    case .lifecycle(let reason): "yabai lifecycle failed: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}
