import Darwin
import Foundation
import ThemeCore

enum KeybindingProviderStatus: String, Encodable, Sendable {
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case blocked
}

struct KeybindingProviderInspection: Encodable, Sendable {
  let status: KeybindingProviderStatus
  let entryPoint: String
  let ownership: String
  let source: String?
  let originalTarget: String?
  let expectedTarget: String
  let message: String
  let sourceConfiguration: String?

  enum CodingKeys: String, CodingKey {
    case status, entryPoint, ownership, source, originalTarget, expectedTarget, message
  }
}

struct KeybindingProviderInspector: Sendable {
  static let managedTarget = "../macarchy/keybindings/current/skhdrc"
  static let ownershipID = "keybindings.skhd-entry"

  func inspect(
    homeDirectory: URL,
    stateRoot: URL,
    generation: KeybindingGenerationInspection
  ) -> KeybindingProviderInspection {
    let home = homeDirectory.standardizedFileURL
    let stateRoot = stateRoot.standardizedFileURL
    let configurationDirectory = home.appending(path: ".config", directoryHint: .isDirectory)
    let directory = configurationDirectory.appending(
      path: "skhd",
      directoryHint: .isDirectory
    )
    let entry = directory.appending(path: "skhdrc")
    let expectedTarget = expectedTarget(home: home, stateRoot: stateRoot)

    let homeDescriptor: Int32
    do {
      homeDescriptor = try PinnedFilesystem.openDirectory(at: home)
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "unsafe_ancestor",
        message: "cannot open the selected home without following symlinks: \(error)"
      )
    }
    defer { Darwin.close(homeDescriptor) }

    let configurationDescriptor: Int32
    do {
      configurationDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: homeDescriptor,
        name: ".config",
        url: configurationDirectory
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return result(
        .installRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "absent",
        message: "skhd configuration directory and entry point are absent"
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "unsafe_ancestor",
        message: "~/.config is not a pinned ordinary directory: \(error)"
      )
    }
    defer { Darwin.close(configurationDescriptor) }

    let claimed: Bool
    switch entryOwnershipClaim(
      homeDirectory: home,
      stateRoot: stateRoot,
      entry: entry,
      expectedTarget: expectedTarget
    ) {
    case .invalid(let message):
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "invalid_ownership_evidence",
        message: message
      )
    case .prepared:
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "recovery_required",
        message: "keybinding entry ownership transaction is prepared but incomplete"
      )
    case .claimed:
      claimed = true
    case .unclaimed:
      claimed = false
    }

    let directoryMetadata: stat
    do {
      directoryMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: configurationDescriptor,
        name: "skhd",
        url: directory
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      if claimed {
        return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
      }
      return result(
        .installRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "absent",
        message: "skhd configuration directory and entry point are absent"
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "unknown",
        message: "cannot inspect skhd configuration directory: \(error)"
      )
    }

    switch directoryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      if claimed {
        return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
      }
      return inspectDirectorySymlink(
        configurationDescriptor: configurationDescriptor,
        configurationDirectory: configurationDirectory,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget
      )
    case S_IFDIR:
      return inspectEntry(
        configurationDescriptor: configurationDescriptor,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        stateRoot: stateRoot,
        generation: generation,
        claimed: claimed
      )
    default:
      if claimed {
        return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
      }
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "conflict",
        message: "~/.config/skhd is neither a directory nor a symbolic link"
      )
    }
  }

  private func inspectDirectorySymlink(
    configurationDescriptor: Int32,
    configurationDirectory: URL,
    directory: URL,
    entry: URL,
    expectedTarget: String
  ) -> KeybindingProviderInspection {
    let target: String
    do {
      target = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: configurationDescriptor,
        name: "skhd",
        url: directory
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        message: "cannot read skhd directory symlink: \(error)"
      )
    }
    let targetDirectory = Self.resolveSymlink(
      target,
      relativeTo: configurationDirectory
    )
    let targetDescriptor: Int32
    do {
      targetDescriptor = try PinnedFilesystem.openDirectory(at: targetDirectory)
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "skhd directory symlink target is not a pinned ordinary directory: \(error)"
      )
    }
    defer { Darwin.close(targetDescriptor) }

    let inventory: (entries: [String], truncated: Bool)
    do {
      inventory = try PinnedFilesystem.directoryEntries(
        descriptor: targetDescriptor,
        url: targetDirectory,
        limit: 2
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "cannot inventory the skhd directory symlink target: \(error)"
      )
    }
    guard inventory.entries == ["skhdrc"], !inventory.truncated else {
      let entries = inventory.entries.isEmpty ? "none" : inventory.entries.joined(separator: ", ")
      let suffix = inventory.truncated ? ", additional entries omitted" : ""
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "directory-level adoption requires only skhdrc; found: \(entries)\(suffix)"
      )
    }

    do {
      let source = try sourceConfiguration(
        parentDescriptor: targetDescriptor,
        parentURL: targetDirectory,
        name: "skhdrc"
      )
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        source: source.url,
        originalTarget: target,
        message: "eligible directory-level symlink requires explicit adoption",
        sourceConfiguration: source.text
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "directory-level skhdrc is not a bounded regular file: \(error)"
      )
    }
  }

  private func inspectEntry(
    configurationDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    stateRoot: URL,
    generation: KeybindingGenerationInspection,
    claimed: Bool
  ) -> KeybindingProviderInspection {
    let directoryDescriptor: Int32
    do {
      directoryDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: configurationDescriptor,
        name: "skhd",
        url: directory
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "ordinary_directory",
        message: "cannot pin the ordinary skhd directory: \(error)"
      )
    }
    defer { Darwin.close(directoryDescriptor) }

    let entryMetadata: stat
    do {
      entryMetadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      if claimed {
        return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
      }
      return result(
        .installRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "ordinary_directory",
        message: "skhd entry point is absent"
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "ordinary_directory",
        message: "cannot inspect skhd entry point: \(error)"
      )
    }

    if entryMetadata.st_mode & S_IFMT == S_IFLNK {
      let target: String
      do {
        target = try PinnedFilesystem.symlinkDestination(
          parentDescriptor: directoryDescriptor,
          name: "skhdrc",
          url: entry
        )
      } catch {
        return result(
          .blocked,
          entry: entry,
          expectedTarget: expectedTarget,
          ownership: "entry_symlink",
          message: "cannot read skhd entry-point symlink: \(error)"
        )
      }
      if target == expectedTarget {
        if claimed {
          return result(
            .managed,
            entry: entry,
            expectedTarget: expectedTarget,
            ownership: "manifest_claimed_symlink",
            originalTarget: target,
            message: "ownership manifest claims the matching entry-point link"
          )
        }
        guard generation.status == .current, let configuration = generation.configuration else {
          return result(
            .blocked,
            entry: entry,
            expectedTarget: expectedTarget,
            ownership: "matching_unclaimed_unreadable",
            originalTarget: target,
            message: "matching unclaimed link has no valid current generation to preview"
          )
        }
        return result(
          .adoptionRequired,
          entry: entry,
          expectedTarget: expectedTarget,
          ownership: "matching_unclaimed_symlink",
          source: stateRoot.appending(path: "keybindings/current/skhdrc"),
          originalTarget: target,
          message: "entry-point link matches the plan but has no Macarchy ownership evidence",
          sourceConfiguration: configuration
        )
      }
      if target == Self.managedTarget, expectedTarget != Self.managedTarget {
        return result(
          .blocked,
          entry: entry,
          expectedTarget: expectedTarget,
          ownership: "state_root_mismatch",
          originalTarget: target,
          message: "entry-point link targets the canonical state root, not the selected state root"
        )
      }
    }

    if claimed {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }

    do {
      let source = try sourceConfiguration(
        parentDescriptor: directoryDescriptor,
        parentURL: directory,
        name: "skhdrc"
      )
      let target =
        entryMetadata.st_mode & S_IFMT == S_IFLNK
        ? try PinnedFilesystem.symlinkDestination(
          parentDescriptor: directoryDescriptor,
          name: "skhdrc",
          url: entry
        ) : nil
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: target == nil ? "regular_file" : "entry_symlink",
        source: source.url,
        originalTarget: target,
        message: "existing skhd entry point requires explicit adoption",
        sourceConfiguration: source.text
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "conflict",
        message: "existing skhd entry point is not a bounded regular file: \(error)"
      )
    }
  }

  private func sourceConfiguration(
    parentDescriptor: Int32,
    parentURL: URL,
    name: String
  ) throws -> (url: URL, text: String) {
    let sourceURL = parentURL.appending(path: name)
    let metadata = try PinnedFilesystem.metadata(
      parentDescriptor: parentDescriptor,
      name: name,
      url: sourceURL
    )
    let resolvedURL: URL
    let file: BoundedRegularFile
    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      resolvedURL = sourceURL
      file = try PinnedFilesystem.readRegularFile(
        parentDescriptor: parentDescriptor,
        name: name,
        url: sourceURL
      )
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: name,
        url: sourceURL
      )
      resolvedURL = Self.resolveSymlink(destination, relativeTo: parentURL)
      file = try PinnedFilesystem.readRegularFile(at: resolvedURL)
    default:
      throw PinnedFilesystemError(
        operation: "read unsupported configuration item",
        url: sourceURL,
        code: EINVAL
      )
    }
    guard let text = String(data: file.data, encoding: .utf8) else {
      throw PinnedFilesystemError(
        operation: "decode configuration as UTF-8", url: resolvedURL, code: EILSEQ)
    }
    return (resolvedURL, text)
  }

  private func expectedTarget(home: URL, stateRoot: URL) -> String {
    let canonical = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
      .standardizedFileURL
    if stateRoot == canonical { return Self.managedTarget }
    return stateRoot.appending(path: "keybindings/current/skhdrc").path
  }

  private func entryOwnershipClaim(
    homeDirectory: URL,
    stateRoot: URL,
    entry: URL,
    expectedTarget: String
  ) -> EntryOwnershipClaim {
    let setupDirectory = stateRoot.appending(path: "state/setup", directoryHint: .isDirectory)
    let manifestURL = setupDirectory.appending(path: "ownership.json")
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: setupDirectory)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .unclaimed
    } catch {
      return .invalid("cannot inspect setup ownership evidence: \(error)")
    }
    defer { Darwin.close(descriptor) }

    let data: Data
    do {
      data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: descriptor,
        name: "ownership.json",
        url: manifestURL,
        maximumSize: 65_536
      ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .unclaimed
    } catch {
      return .invalid("cannot read setup ownership evidence: \(error)")
    }
    let manifest: SetupOwnershipManifest
    do {
      try SetupOwnershipManager().validateManifestKeys(data)
      manifest = try JSONDecoder().decode(SetupOwnershipManifest.self, from: data)
    } catch {
      return .invalid("setup ownership evidence is invalid: \(error)")
    }
    guard manifest.schemaVersion == SetupOwnershipManifest.currentSchemaVersion else {
      return .invalid("setup ownership evidence has an unsupported schema")
    }
    guard Set(manifest.records.map(\.id)).count == manifest.records.count else {
      return .invalid("setup ownership evidence contains duplicate integration identifiers")
    }
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    do {
      for record in manifest.records {
        try manager.validateOwnershipRecord(record, context: context)
      }
    } catch {
      return .invalid("setup ownership evidence contains an invalid record: \(error)")
    }
    guard let record = manifest.records.first(where: { $0.id == Self.ownershipID }) else {
      return .unclaimed
    }
    guard record.targetPath == entry.path, record.linkDestination == expectedTarget else {
      return .invalid("keybinding entry ownership record does not match the selected paths")
    }
    return record.phase == .applied ? .claimed : .prepared
  }

  static func validateOwnershipRecord(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let target = context.homeDirectory.appending(path: ".config/skhd/skhdrc")
    let expectedTarget = Self.managedTarget
    guard
      [.prepared, .applied].contains(record.phase),
      record.kind == .symbolicLink,
      record.targetPath == target.path,
      record.backupPath == nil,
      record.originalDigest == nil,
      record.installedDigest == sha256Digest(Data(expectedTarget.utf8)),
      record.linkDestination == expectedTarget,
      record.replacementDigest == nil
    else {
      throw SetupOwnershipError.invalidManifest(
        "keybinding entry ownership record does not match the managed provider link"
      )
    }
  }

  private func ownershipDrift(
    entry: URL,
    expectedTarget: String
  ) -> KeybindingProviderInspection {
    result(
      .blocked,
      entry: entry,
      expectedTarget: expectedTarget,
      ownership: "ownership_drift",
      message: "ownership manifest claims the skhd entry point, but filesystem state differs"
    )
  }

  private static func resolveSymlink(_ destination: String, relativeTo parent: URL) -> URL {
    if NSString(string: destination).isAbsolutePath {
      return URL(filePath: destination).standardizedFileURL
    }
    return parent.appending(path: destination).standardizedFileURL
  }

  private func result(
    _ status: KeybindingProviderStatus,
    entry: URL,
    expectedTarget: String,
    ownership: String,
    source: URL? = nil,
    originalTarget: String? = nil,
    message: String,
    sourceConfiguration: String? = nil
  ) -> KeybindingProviderInspection {
    KeybindingProviderInspection(
      status: status,
      entryPoint: entry.path,
      ownership: ownership,
      source: source?.path,
      originalTarget: originalTarget,
      expectedTarget: expectedTarget,
      message: message,
      sourceConfiguration: sourceConfiguration
    )
  }
}

private enum EntryOwnershipClaim {
  case claimed
  case prepared
  case unclaimed
  case invalid(String)
}
