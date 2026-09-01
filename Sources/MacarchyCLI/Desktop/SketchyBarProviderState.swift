import Darwin
import Foundation
import ThemeCore

enum SketchyBarProviderPlanStatus: String, Codable, Sendable {
  case disabled
  case externallyManaged = "externally_managed"
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
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

private enum SketchyBarOriginalKind: String {
  case absent
  case regularFile = "regular_file"
  case entrySymlink = "entry_symlink"
  case directorySymlink = "directory_symlink"
}

private struct SketchyBarAdoptionEvidence {
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
}

struct SketchyBarProviderPlanInspector: Sendable {
  func inspect(
    homeDirectory: URL,
    stateRoot: URL,
    enabled: Bool,
    generation: SketchyBarGenerationInspection
  ) -> SketchyBarProviderPlanInspection {
    let directory = homeDirectory.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    let entry = directory.appending(path: "sketchybarrc")
    if !enabled {
      return inspectDisabled(directory: directory, entry: entry)
    }
    if managedEntryTarget(directory: directory, entry: entry)
      == Self.managedTarget(homeDirectory: homeDirectory, stateRoot: stateRoot)
    {
      guard generation.status == .current else {
        return result(
          .blocked,
          ownership: "managed_target_without_generation",
          entry: entry,
          message: "SketchyBar points at Macarchy state without a valid selected generation"
        )
      }
      return result(
        .managed,
        ownership: "managed",
        entry: entry,
        message: "the SketchyBar entry points to the selected Macarchy generation"
      )
    }
    do {
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
    if canonical == stateRoot.standardizedFileURL {
      return "../macarchy/desktop/sketchybar/current/sketchybarrc"
    }
    return stateRoot.appending(path: "desktop/sketchybar/current/sketchybarrc").path
  }

  private func captureUnowned(
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
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .invalidState(let reason): reason
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}
