import Darwin
import Foundation
import ThemeCore

enum SketchyBarProviderPlanStatus: String, Codable, Sendable {
  case disabled
  case externallyManaged = "externally_managed"
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case recoveryRequired = "recovery_required"
  case blocked
}

enum SketchyBarPalettePlanStatus: String, Codable, Sendable {
  case disabled
  case unavailable
  case refreshRequired = "refresh_required"
  case current
  case invalid
}

struct SketchyBarPalettePlanInspection: Encodable, Sendable {
  let status: SketchyBarPalettePlanStatus
  let generationID: String?
  let message: String

  enum CodingKeys: String, CodingKey {
    case status, message
    case generationID = "generation_id"
  }
}

struct SketchyBarPalettePlanInspector: Sendable {
  func inspect(stateRoot: URL, enabled: Bool) -> SketchyBarPalettePlanInspection {
    guard enabled else {
      return SketchyBarPalettePlanInspection(
        status: .disabled,
        generationID: nil,
        message: "top-bar role is disabled"
      )
    }
    do {
      let manifest = try ReconciliationStatusStore(root: stateRoot).activeManifest()
      let rendererVersion = manifest.rendererVersions[
        SketchyBarConfigurationComposer.providerID,
        default: 0
      ]
      guard
        rendererVersion >= 2,
        manifest.artifacts[SketchyBarConfigurationComposer.paletteArtifactPath] != nil
      else {
        return SketchyBarPalettePlanInspection(
          status: .refreshRequired,
          generationID: manifest.generationID,
          message: "the active theme predates the managed SketchyBar shell palette"
        )
      }
      return SketchyBarPalettePlanInspection(
        status: .current,
        generationID: manifest.generationID,
        message: "the active theme contains the managed SketchyBar shell palette"
      )
    } catch ReconciliationStatusError.noActiveGeneration {
      return SketchyBarPalettePlanInspection(
        status: .unavailable,
        generationID: nil,
        message: "no canonical theme generation is active"
      )
    } catch {
      return SketchyBarPalettePlanInspection(
        status: .invalid,
        generationID: nil,
        message: String(describing: error)
      )
    }
  }
}

struct SketchyBarProviderPlanInspection: Encodable, Sendable {
  let status: SketchyBarProviderPlanStatus
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

enum SketchyBarOriginalKind: String, Codable, Sendable {
  case absent
  case regularFile = "regular_file"
  case entrySymlink = "entry_symlink"
  case directorySymlink = "directory_symlink"
}

struct SketchyBarAdoptionEvidence: Codable, Equatable, Sendable {
  let kind: SketchyBarOriginalKind
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

  var isValid: Bool {
    guard
      publicPath.hasPrefix("/"),
      URL(filePath: publicPath).standardizedFileURL.path == publicPath,
      inventory == inventory.sorted(),
      Set(inventory).count == inventory.count,
      inventory.count <= 1_024
    else { return false }
    let hasIdentity =
      permissions.map { (0...0o777).contains($0) } == true
      && device != nil
      && inode != nil
      && contentDigest.map(Self.isDigest) == true
    switch kind {
    case .absent:
      return linkTarget == nil && contentDigest == nil && permissions == nil
        && device == nil && inode == nil && inventory.isEmpty
    case .regularFile:
      return hasIdentity && linkTarget == nil && inventory.isEmpty
    case .entrySymlink:
      return hasIdentity && validLinkTarget && inventory.isEmpty
    case .directorySymlink:
      return hasIdentity && validLinkTarget && inventory.contains("sketchybarrc")
    }
  }

  private var validLinkTarget: Bool {
    linkTarget.map {
      !$0.isEmpty && $0.utf8.count <= Int(PATH_MAX) && !$0.contains("\0")
    } == true
  }

  private static func isDigest(_ value: String) -> Bool {
    guard value.count == 71, value.hasPrefix("sha256:") else { return false }
    return value.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case publicPath = "public_path"
    case linkTarget = "link_target"
    case contentDigest = "content_digest"
    case permissions, device, inode, inventory
  }
}

struct SketchyBarOwnershipRecord: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let generationID: String
  let managedTarget: String
  let original: SketchyBarAdoptionEvidence
  let retainedOriginalPath: String?
  let createdConfigurationDirectory: Bool
  let priorServiceRunning: Bool

  init(
    generationID: String,
    managedTarget: String,
    original: SketchyBarAdoptionEvidence,
    retainedOriginalPath: String?,
    createdConfigurationDirectory: Bool,
    priorServiceRunning: Bool
  ) {
    schemaVersion = 2
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

struct SketchyBarOwnershipStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/sketchybar", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "ownership.json") }

  func read() throws -> SketchyBarOwnershipRecord? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 32_768).data
    let record = try JSONDecoder().decode(SketchyBarOwnershipRecord.self, from: data)
    guard Self.isValid(record, stateRoot: stateRoot) else {
      throw SketchyBarDesktopError.invalidState("SketchyBar ownership record is invalid")
    }
    return record
  }

  static func isValid(_ record: SketchyBarOwnershipRecord, stateRoot: URL) -> Bool {
    guard
      record.schemaVersion == 2,
      SketchyBarGenerationInspector.isGenerationID(record.generationID),
      record.original.isValid,
      !record.managedTarget.isEmpty,
      !record.managedTarget.contains("\0"),
      !record.managedTarget.contains("\n"),
      !record.createdConfigurationDirectory || record.original.kind == .absent
    else { return false }
    guard record.original.kind != .absent else {
      return record.retainedOriginalPath == nil
    }
    guard let retainedPath = record.retainedOriginalPath else { return false }
    let retained = URL(filePath: retainedPath).standardizedFileURL
    let provider = stateRoot.standardizedFileURL.appending(
      path: "desktop/sketchybar",
      directoryHint: .isDirectory
    )
    let name = retained.lastPathComponent
    let nonce = String(name.dropFirst("retained-".count))
    return retained.path == retainedPath
      && retained.deletingLastPathComponent().path == provider.path
      && name.hasPrefix("retained-")
      && nonce == nonce.lowercased()
      && UUID(uuidString: nonce) != nil
  }

  func write(_ record: SketchyBarOwnershipRecord) throws {
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

struct SketchyBarProviderPlanInspector: Sendable {
  func inspect(
    homeDirectory: URL,
    stateRoot: URL,
    enabled: Bool,
    generation: SketchyBarGenerationInspection,
    transactionPending: Bool = false
  ) -> SketchyBarProviderPlanInspection {
    let directory = homeDirectory.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    let entry = directory.appending(path: "sketchybarrc")
    if transactionPending {
      return result(
        .recoveryRequired,
        ownership: "transaction_pending",
        entry: entry,
        message: "an interrupted SketchyBar transaction must be recovered before planning changes"
      )
    }
    do {
      if let ownership = try SketchyBarOwnershipStore(stateRoot: stateRoot).read() {
        return try inspectManaged(
          ownership,
          entry: entry,
          expectedTarget: Self.managedTarget(homeDirectory: homeDirectory, stateRoot: stateRoot),
          generation: generation
        )
      }
      if !enabled {
        return inspectDisabled(directory: directory, entry: entry)
      }
      if managedEntryTarget(directory: directory, entry: entry)
        == Self.managedTarget(homeDirectory: homeDirectory, stateRoot: stateRoot)
      {
        return result(
          .blocked,
          ownership: "managed_target_without_ownership",
          entry: entry,
          message: "SketchyBar points at Macarchy state without an ownership record"
        )
      }
      let evidence = try captureUnowned(directory: directory, entry: entry)
      switch evidence.kind {
      case .absent:
        return result(
          .installRequired,
          ownership: "absent",
          entry: entry,
          message: "no SketchyBar configuration entry exists"
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

  static func managedTarget(homeDirectory: URL, stateRoot: URL) -> String {
    let canonical = homeDirectory.appending(path: ".config/macarchy").standardizedFileURL
    if canonical.path == stateRoot.standardizedFileURL.path {
      return "../macarchy/desktop/sketchybar/current/sketchybarrc"
    }
    return stateRoot.appending(path: "desktop/sketchybar/current/sketchybarrc").path
  }

  func captureUnowned(
    directory: URL,
    entry: URL
  ) throws -> SketchyBarAdoptionEvidence {
    var directoryMetadata = stat()
    guard lstat(directory.path, &directoryMetadata) == 0 else {
      if errno == ENOENT {
        return evidence(kind: .absent, publicPath: entry, metadata: nil)
      }
      throw SketchyBarDesktopError.system(
        "inspect SketchyBar configuration directory",
        directory,
        errno
      )
    }
    switch directoryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      guard directoryMetadata.st_nlink == 1, let target = readLink(directory) else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar directory symlink is not singly linked and readable"
        )
      }
      let resolved = resolveLink(target, at: directory)
      let targetDescriptor = try PinnedFilesystem.openDirectory(at: resolved)
      defer { Darwin.close(targetDescriptor) }
      let inventory = try PinnedFilesystem.directoryEntries(
        descriptor: targetDescriptor,
        url: resolved,
        limit: 1_024
      )
      guard !inventory.truncated else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar directory contains more than 1024 top-level entries"
        )
      }
      guard inventory.entries.contains("sketchybarrc") else {
        throw SketchyBarDesktopError.invalidState(
          "SketchyBar directory symlink does not contain sketchybarrc"
        )
      }
      let source = resolved.appending(path: "sketchybarrc")
      let data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: targetDescriptor,
        name: "sketchybarrc",
        url: source
      ).data
      return evidence(
        kind: .directorySymlink,
        publicPath: directory,
        metadata: directoryMetadata,
        linkTarget: target,
        contentDigest: sha256Digest(data),
        inventory: inventory.entries
      )
    case S_IFDIR:
      break
    default:
      throw SketchyBarDesktopError.invalidState(
        "SketchyBar configuration path is not a directory or directory symlink"
      )
    }

    var entryMetadata = stat()
    guard lstat(entry.path, &entryMetadata) == 0 else {
      if errno == ENOENT {
        return evidence(kind: .absent, publicPath: entry, metadata: nil)
      }
      throw SketchyBarDesktopError.system("inspect sketchybarrc", entry, errno)
    }
    guard entryMetadata.st_nlink == 1 else {
      throw SketchyBarDesktopError.invalidState("sketchybarrc must have exactly one link")
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
        throw SketchyBarDesktopError.invalidState("cannot read sketchybarrc symlink")
      }
      let data = try BoundedRegularFile.read(at: resolveLink(target, at: entry)).data
      return evidence(
        kind: .entrySymlink,
        publicPath: entry,
        metadata: entryMetadata,
        linkTarget: target,
        contentDigest: sha256Digest(data)
      )
    default:
      throw SketchyBarDesktopError.invalidState(
        "sketchybarrc is not a regular file or symbolic link"
      )
    }
  }

  private func inspectManaged(
    _ ownership: SketchyBarOwnershipRecord,
    entry: URL,
    expectedTarget: String,
    generation: SketchyBarGenerationInspection
  ) throws -> SketchyBarProviderPlanInspection {
    let expectedPublicPath =
      ownership.original.kind == .directorySymlink
      ? entry.deletingLastPathComponent().path : entry.path
    guard
      ownership.managedTarget == expectedTarget,
      ownership.original.publicPath == expectedPublicPath,
      managedEntryTarget(directory: entry.deletingLastPathComponent(), entry: entry)
        == ownership.managedTarget
    else {
      return result(
        .blocked,
        ownership: "ownership_drift",
        entry: entry,
        message: "owned sketchybarrc no longer matches the managed target"
      )
    }
    guard
      generation.status == .current,
      generation.generationID == ownership.generationID
    else {
      return result(
        .blocked,
        ownership: "generation_drift",
        entry: entry,
        message: "SketchyBar ownership does not match a valid selected generation"
      )
    }
    try SketchyBarProviderTransaction.authenticateRetained(ownership)
    return result(
      .managed,
      ownership: "managed",
      entry: entry,
      message: "the SketchyBar provider entry is owned by Macarchy"
    )
  }

  private func inspectDisabled(
    directory: URL,
    entry: URL
  ) -> SketchyBarProviderPlanInspection {
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0 else {
      return result(
        errno == ENOENT ? .disabled : .externallyManaged,
        ownership: errno == ENOENT ? "absent" : "uninspectable",
        entry: entry,
        message: errno == ENOENT
          ? "top-bar role is disabled and no SketchyBar configuration exists"
          : "top-bar role is disabled; uninspectable SketchyBar state remains externally managed"
      )
    }
    return result(
      .externallyManaged,
      ownership: "external",
      entry: entry,
      message: "top-bar role is disabled; existing SketchyBar state remains externally managed"
    )
  }

  private func evidence(
    kind: SketchyBarOriginalKind,
    publicPath: URL,
    metadata: stat?,
    linkTarget: String? = nil,
    contentDigest: String? = nil,
    inventory: [String] = []
  ) -> SketchyBarAdoptionEvidence {
    SketchyBarAdoptionEvidence(
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
    for evidence: SketchyBarAdoptionEvidence,
    directory: URL,
    entry: URL
  ) -> URL? {
    switch evidence.kind {
    case .regularFile: entry
    case .entrySymlink: evidence.linkTarget.map { resolveLink($0, at: entry) }
    case .directorySymlink:
      evidence.linkTarget.map { resolveLink($0, at: directory).appending(path: "sketchybarrc") }
    case .absent: nil
    }
  }

  private func readLink(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(url.path, &buffer, buffer.count - 1)
    guard count >= 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private func managedEntryTarget(directory: URL, entry: URL) -> String? {
    var directoryMetadata = stat()
    guard
      lstat(directory.path, &directoryMetadata) == 0,
      directoryMetadata.st_mode & S_IFMT == S_IFDIR
    else { return nil }
    var entryMetadata = stat()
    guard
      lstat(entry.path, &entryMetadata) == 0,
      entryMetadata.st_mode & S_IFMT == S_IFLNK,
      entryMetadata.st_nlink == 1
    else { return nil }
    return readLink(entry)
  }

  private func resolveLink(_ target: String, at link: URL) -> URL {
    if target.hasPrefix("/") { return URL(filePath: target).standardizedFileURL }
    return link.deletingLastPathComponent().appending(path: target).standardizedFileURL
  }

  private func result(
    _ status: SketchyBarProviderPlanStatus,
    ownership: String,
    entry: URL,
    originalTarget: String? = nil,
    source: String? = nil,
    message: String,
    adoptionEvidenceDigest: String? = nil
  ) -> SketchyBarProviderPlanInspection {
    SketchyBarProviderPlanInspection(
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

enum SketchyBarDesktopError: Error, CustomStringConvertible, Sendable {
  case invalidState(String)
  case lifecycle(String)
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .invalidState(let reason): reason
    case .lifecycle(let reason): reason
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}
