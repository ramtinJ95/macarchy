import Darwin
import Foundation
import ThemeCore

enum KeybindingProviderStatus: String, Encodable, Sendable {
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case blocked
}

struct KeybindingAdoptionEvidence: Equatable, Sendable {
  enum Kind: String, Sendable {
    case absent
    case directorySymbolicLink = "directory_symbolic_link"
    case legacyFallback = "legacy_fallback"
    case regularFile = "regular_file"
    case symbolicLink = "symbolic_link"
  }

  let kind: Kind
  let linkDestination: String?
  let contentDigest: String?
  let inventory: [String]

  var digest: String {
    let values = [kind.rawValue, linkDestination ?? "", contentDigest ?? ""] + inventory
    var data = Data()
    for value in values {
      let bytes = Data(value.utf8)
      data.append(Data("\(bytes.count):".utf8))
      data.append(bytes)
    }
    return sha256Digest(data)
  }
}

struct KeybindingProviderInspection: Encodable, Sendable {
  let status: KeybindingProviderStatus
  let entryPoint: String
  let ownership: String
  let source: String?
  let originalTarget: String?
  let expectedTarget: String
  let message: String
  let adoptionEvidenceDigest: String?
  let retainedOriginalRequirement: String?
  let retainedOriginalStatus: String?
  let sourceConfiguration: String?
  let adoptionEvidence: KeybindingAdoptionEvidence?

  enum CodingKeys: String, CodingKey {
    case status, entryPoint, ownership, source, originalTarget, expectedTarget, message
    case adoptionEvidenceDigest = "adoption_evidence_digest"
    case retainedOriginalRequirement = "retained_original_requirement"
    case retainedOriginalStatus = "retained_original_status"
  }
}

struct KeybindingProviderInspector: Sendable {
  static let managedTarget = "../macarchy/keybindings/current/skhdrc"
  static let ownershipID = "keybindings.skhd-entry"
  static let claimMarkerAttribute = KeybindingProviderPrimitives.claimMarkerAttribute

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

    return inspectConfigurationDirectory(
      homeDescriptor: homeDescriptor,
      home: home,
      stateRoot: stateRoot,
      configurationDirectory: configurationDirectory,
      directory: directory,
      entry: entry,
      expectedTarget: expectedTarget,
      generation: generation
    )
  }

  private func inspectConfigurationDirectory(
    homeDescriptor: Int32,
    home: URL,
    stateRoot: URL,
    configurationDirectory: URL,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    generation: KeybindingGenerationInspection
  ) -> KeybindingProviderInspection {

    let configurationDescriptor: Int32
    do {
      configurationDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: homeDescriptor,
        name: ".config",
        url: configurationDirectory
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return inspectMissingPreferredEntry(
        homeDescriptor: homeDescriptor,
        home: home,
        entry: entry,
        expectedTarget: expectedTarget,
        installOwnership: "absent",
        installMessage: "skhd configuration directory and entry point are absent",
        fallbackCanBeAdopted: false
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

    let ownershipRecord: SetupOwnershipRecord?
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
    case .claimed(let record):
      ownershipRecord = record
    case .unclaimed:
      ownershipRecord = nil
    }
    let claimed = ownershipRecord != nil

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
      return inspectMissingPreferredEntry(
        homeDescriptor: homeDescriptor,
        home: home,
        entry: entry,
        expectedTarget: expectedTarget,
        installOwnership: "absent",
        installMessage: "skhd configuration directory and entry point are absent",
        fallbackCanBeAdopted: false
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
      return inspectDirectorySymlinkState(
        metadata: directoryMetadata,
        configurationDescriptor: configurationDescriptor,
        configurationDirectory: configurationDirectory,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        claimed: claimed
      )
    case S_IFDIR:
      return inspectOrdinaryDirectoryEntry(
        configurationDescriptor: configurationDescriptor,
        home: home,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        stateRoot: stateRoot,
        generation: generation,
        ownershipRecord: ownershipRecord
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

  private func inspectDirectorySymlinkState(
    metadata: stat,
    configurationDescriptor: Int32,
    configurationDirectory: URL,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    claimed: Bool
  ) -> KeybindingProviderInspection {
    if claimed {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }
    do {
      try Self.requireAdoptableSymlink(
        metadata,
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
        message: "skhd directory symlink cannot be adopted: \(error)"
      )
    }
    return inspectDirectorySymlink(
      configurationDescriptor: configurationDescriptor,
      configurationDirectory: configurationDirectory,
      directory: directory,
      entry: entry,
      expectedTarget: expectedTarget
    )
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
    let targetDirectory = KeybindingProviderPrimitives.resolveSymlink(
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
      let sourceURL = targetDirectory.appending(path: "skhdrc")
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: targetDescriptor,
        name: "skhdrc",
        url: sourceURL
      )
      guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
        throw PinnedFilesystemError(
          operation: "read unsupported directory-level skhdrc",
          url: sourceURL,
          code: EINVAL
        )
      }
      let file = try PinnedFilesystem.readRegularFile(
        parentDescriptor: targetDescriptor,
        name: "skhdrc",
        url: sourceURL
      )
      guard let sourceConfiguration = String(data: file.data, encoding: .utf8) else {
        throw PinnedFilesystemError(
          operation: "decode configuration as UTF-8",
          url: sourceURL,
          code: EILSEQ
        )
      }
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "directory_symlink",
        source: sourceURL,
        originalTarget: target,
        message:
          "eligible directory-level symlink requires explicit adoption; its exact inode will be retained as an authenticated claim until teardown",
        sourceConfiguration: sourceConfiguration,
        retainedOriginalRequirement: "exact_inode",
        retainedOriginalStatus: "will_retain",
        adoptionEvidence: KeybindingAdoptionEvidence(
          kind: .directorySymbolicLink,
          linkDestination: target,
          contentDigest: sha256Digest(file.data),
          inventory: inventory.entries
        )
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

  private func inspectOrdinaryDirectoryEntry(
    configurationDescriptor: Int32,
    home: URL,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    stateRoot: URL,
    generation: KeybindingGenerationInspection,
    ownershipRecord: SetupOwnershipRecord?
  ) -> KeybindingProviderInspection {
    let claimed = ownershipRecord != nil
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
      return inspectMissingEntry(
        home: home,
        entry: entry,
        expectedTarget: expectedTarget,
        claimed: claimed
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

    switch entryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      return inspectEntrySymlink(
        metadata: entryMetadata,
        directoryDescriptor: directoryDescriptor,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        stateRoot: stateRoot,
        generation: generation,
        ownershipRecord: ownershipRecord
      )
    case S_IFREG:
      return inspectRegularEntry(
        directoryDescriptor: directoryDescriptor,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        ownershipRecord: ownershipRecord
      )
    default:
      return inspectUnsupportedEntry(
        directoryDescriptor: directoryDescriptor,
        directory: directory,
        entry: entry,
        expectedTarget: expectedTarget,
        ownershipRecord: ownershipRecord
      )
    }
  }

  private func inspectMissingEntry(
    home: URL,
    entry: URL,
    expectedTarget: String,
    claimed: Bool
  ) -> KeybindingProviderInspection {
    if claimed {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }
    let homeDescriptor: Int32
    do {
      homeDescriptor = try PinnedFilesystem.openDirectory(at: home)
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "unsafe_ancestor",
        message: "cannot reopen the selected home to inspect ~/.skhdrc: \(error)"
      )
    }
    defer { Darwin.close(homeDescriptor) }
    return inspectMissingPreferredEntry(
      homeDescriptor: homeDescriptor,
      home: home,
      entry: entry,
      expectedTarget: expectedTarget,
      installOwnership: "ordinary_directory",
      installMessage: "skhd entry point is absent",
      fallbackCanBeAdopted: true
    )
  }

  private func inspectEntrySymlink(
    metadata: stat,
    directoryDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    stateRoot: URL,
    generation: KeybindingGenerationInspection,
    ownershipRecord: SetupOwnershipRecord?
  ) -> KeybindingProviderInspection {
    if ownershipRecord == nil {
      do {
        try Self.requireAdoptableSymlink(
          metadata,
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
          message: "skhd entry-point symlink cannot be adopted: \(error)"
        )
      }
    }

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
      return inspectMatchingEntrySymlink(
        directoryDescriptor: directoryDescriptor,
        entry: entry,
        expectedTarget: expectedTarget,
        stateRoot: stateRoot,
        generation: generation,
        ownershipRecord: ownershipRecord,
        target: target
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
    if ownershipRecord != nil {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }

    return inspectAdoptableEntrySymlink(
      directoryDescriptor: directoryDescriptor,
      directory: directory,
      entry: entry,
      expectedTarget: expectedTarget
    )
  }

  private func inspectMatchingEntrySymlink(
    directoryDescriptor: Int32,
    entry: URL,
    expectedTarget: String,
    stateRoot: URL,
    generation: KeybindingGenerationInspection,
    ownershipRecord: SetupOwnershipRecord?,
    target: String
  ) -> KeybindingProviderInspection {
    if let ownershipRecord {
      do {
        try validateManagedOwnershipMarkers(
          directoryDescriptor: directoryDescriptor,
          entry: entry,
          record: ownershipRecord
        )
      } catch {
        guard ownershipRecord.retainedOriginalPath != nil else {
          return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
        }
        return result(
          .blocked,
          entry: entry,
          expectedTarget: expectedTarget,
          ownership: "retained_original_drift",
          message:
            "the authenticated retained-original claim is missing, drifted, or no longer bound to its persisted path",
          retainedOriginalRequirement: "exact_inode",
          retainedOriginalStatus: "drifted"
        )
      }
      let legacySymlink =
        ownershipRecord.retainedOriginalPath == nil
        && [.symbolicLink, .directorySymbolicLink].contains(
          ownershipRecord.originalKind ?? .absent
        )
      let exactRestoration = legacySymlink || ownershipRecord.retainedOriginalPath != nil
      let retainedStatus: String?
      if ownershipRecord.retainedOriginalPath != nil {
        retainedStatus = "authenticated"
      } else {
        retainedStatus = legacySymlink ? "legacy_unavailable" : nil
      }
      return result(
        .managed,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: legacySymlink
          ? "manifest_claimed_symlink_legacy_restore" : "manifest_claimed_symlink",
        originalTarget: target,
        message: legacySymlink
          ? "legacy ownership predates retained-original claims; teardown can safely "
            + "recreate the reviewed link text but cannot claim exact symlink inode metadata"
          : "ownership manifest claims the matching entry-point link",
        retainedOriginalRequirement: exactRestoration ? "exact_inode" : nil,
        retainedOriginalStatus: retainedStatus
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
      sourceConfiguration: configuration,
      retainedOriginalRequirement: "exact_inode",
      retainedOriginalStatus: "will_retain",
      adoptionEvidence: KeybindingAdoptionEvidence(
        kind: .symbolicLink,
        linkDestination: target,
        contentDigest: sha256Digest(Data(configuration.utf8)),
        inventory: []
      )
    )
  }

  private func inspectAdoptableEntrySymlink(
    directoryDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String
  ) -> KeybindingProviderInspection {
    do {
      let source = try sourceConfiguration(
        parentDescriptor: directoryDescriptor,
        parentURL: directory,
        name: "skhdrc"
      )
      let target = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directoryDescriptor,
        name: "skhdrc",
        url: entry
      )
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "entry_symlink",
        source: source.url,
        originalTarget: target,
        message:
          "existing skhd entry-point symlink requires explicit adoption; its exact inode will be retained as an authenticated claim until teardown",
        sourceConfiguration: source.text,
        retainedOriginalRequirement: "exact_inode",
        retainedOriginalStatus: "will_retain",
        adoptionEvidence: KeybindingAdoptionEvidence(
          kind: .symbolicLink,
          linkDestination: target,
          contentDigest: sha256Digest(source.data),
          inventory: []
        )
      )
    } catch {
      return unsupportedEntryResult(entry: entry, expectedTarget: expectedTarget, error: error)
    }
  }

  private func inspectRegularEntry(
    directoryDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    ownershipRecord: SetupOwnershipRecord?
  ) -> KeybindingProviderInspection {
    if ownershipRecord != nil {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }

    return inspectAdoptableRegularEntry(
      directoryDescriptor: directoryDescriptor,
      directory: directory,
      entry: entry,
      expectedTarget: expectedTarget
    )
  }

  private func inspectUnsupportedEntry(
    directoryDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String,
    ownershipRecord: SetupOwnershipRecord?
  ) -> KeybindingProviderInspection {
    if ownershipRecord != nil {
      return ownershipDrift(entry: entry, expectedTarget: expectedTarget)
    }

    // Preserve the second no-follow observation made by the original state machine.
    // A concurrent replacement can become an adoptable regular entry before this read.
    return inspectAdoptableRegularEntry(
      directoryDescriptor: directoryDescriptor,
      directory: directory,
      entry: entry,
      expectedTarget: expectedTarget
    )
  }

  private func inspectAdoptableRegularEntry(
    directoryDescriptor: Int32,
    directory: URL,
    entry: URL,
    expectedTarget: String
  ) -> KeybindingProviderInspection {

    do {
      let source = try sourceConfiguration(
        parentDescriptor: directoryDescriptor,
        parentURL: directory,
        name: "skhdrc"
      )
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "regular_file",
        source: source.url,
        message: "existing skhd entry point requires explicit adoption",
        sourceConfiguration: source.text,
        adoptionEvidence: KeybindingAdoptionEvidence(
          kind: .regularFile,
          linkDestination: nil,
          contentDigest: sha256Digest(source.data),
          inventory: []
        )
      )
    } catch {
      return unsupportedEntryResult(entry: entry, expectedTarget: expectedTarget, error: error)
    }
  }

  private func unsupportedEntryResult(
    entry: URL,
    expectedTarget: String,
    error: Error
  ) -> KeybindingProviderInspection {
    result(
      .blocked,
      entry: entry,
      expectedTarget: expectedTarget,
      ownership: "conflict",
      message: "existing skhd entry point is not a bounded regular file: \(error)"
    )
  }

  private func sourceConfiguration(
    parentDescriptor: Int32,
    parentURL: URL,
    name: String
  ) throws -> (url: URL, text: String, data: Data) {
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
      guard metadata.st_nlink == 1 else {
        throw PinnedFilesystemError(
          operation: "reject multiply linked configuration item",
          url: sourceURL,
          code: EMLINK
        )
      }
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
      resolvedURL = KeybindingProviderPrimitives.resolveSymlink(
        destination,
        relativeTo: parentURL
      )
      var resolvedMetadata = stat()
      guard
        lstat(resolvedURL.path, &resolvedMetadata) == 0,
        resolvedMetadata.st_mode & S_IFMT == S_IFREG,
        resolvedMetadata.st_nlink == 1
      else {
        throw PinnedFilesystemError(
          operation: "reject unsupported or multiply linked configuration target",
          url: resolvedURL,
          code: EMLINK
        )
      }
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
    return (resolvedURL, text, file.data)
  }

  func legacyFallbackEvidence(homeDirectory: URL) throws -> KeybindingAdoptionEvidence {
    let home = homeDirectory.standardizedFileURL
    let descriptor = try PinnedFilesystem.openDirectory(at: home)
    defer { Darwin.close(descriptor) }
    let fallback = home.appending(path: ".skhdrc")
    let metadata = try PinnedFilesystem.metadata(
      parentDescriptor: descriptor,
      name: ".skhdrc",
      url: fallback
    )
    guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFLNK else {
      throw PinnedFilesystemError(
        operation: "reject unsupported fallback configuration item",
        url: fallback,
        code: EINVAL
      )
    }
    let source = try sourceConfiguration(
      parentDescriptor: descriptor,
      parentURL: home,
      name: ".skhdrc"
    )
    let destination =
      metadata.st_mode & S_IFMT == S_IFLNK
      ? try PinnedFilesystem.symlinkDestination(
        parentDescriptor: descriptor,
        name: ".skhdrc",
        url: fallback
      ) : nil
    return KeybindingAdoptionEvidence(
      kind: .legacyFallback,
      linkDestination: destination,
      contentDigest: sha256Digest(source.data),
      inventory: []
    )
  }

  private func inspectMissingPreferredEntry(
    homeDescriptor: Int32,
    home: URL,
    entry: URL,
    expectedTarget: String,
    installOwnership: String,
    installMessage: String,
    fallbackCanBeAdopted: Bool
  ) -> KeybindingProviderInspection {
    let fallback = home.appending(path: ".skhdrc")
    do {
      _ = try PinnedFilesystem.metadata(
        parentDescriptor: homeDescriptor,
        name: ".skhdrc",
        url: fallback
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return result(
        .installRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: installOwnership,
        message: installMessage,
        adoptionEvidence: Self.absentEvidence
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "legacy_fallback_conflict",
        message: "cannot inspect fallback ~/.skhdrc without following the preferred path: \(error)"
      )
    }

    guard fallbackCanBeAdopted else {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "legacy_fallback_requires_directory",
        source: fallback,
        message: "fallback ~/.skhdrc exists; create and review an ordinary ~/.config/skhd "
          + "directory before Macarchy can install a preferred entry without shadowing it"
      )
    }
    do {
      let source = try sourceConfiguration(
        parentDescriptor: homeDescriptor,
        parentURL: home,
        name: ".skhdrc"
      )
      let evidence = try legacyFallbackEvidence(homeDirectory: home)
      return result(
        .adoptionRequired,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "legacy_fallback",
        source: source.url,
        originalTarget: evidence.linkDestination,
        message: "fallback ~/.skhdrc is authoritative until reviewed adoption installs the "
          + "preferred managed entry; the fallback remains untouched for teardown",
        sourceConfiguration: source.text,
        adoptionEvidence: evidence
      )
    } catch {
      return result(
        .blocked,
        entry: entry,
        expectedTarget: expectedTarget,
        ownership: "legacy_fallback_conflict",
        source: fallback,
        message: "fallback ~/.skhdrc is not a bounded supported file or symlink: \(error)"
      )
    }
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
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
    let record: SetupOwnershipRecord?
    do {
      record = try manager.keybindingOwnershipRecord(from: data, context: context)
    } catch {
      return .invalid(error.providerInspectionMessage)
    }
    guard let record else {
      return .unclaimed
    }
    guard record.targetPath == entry.path, record.linkDestination == expectedTarget else {
      return .invalid("keybinding entry ownership record does not match the selected paths")
    }
    return record.phase == .applied ? .claimed(record) : .prepared
  }

  private func validateManagedOwnershipMarkers(
    directoryDescriptor: Int32,
    entry: URL,
    record: SetupOwnershipRecord
  ) throws {
    if Self.isLegacyCleanInstallRecord(record) {
      guard
        try Self.markerIsAbsent(
          parentDescriptor: directoryDescriptor,
          name: "skhdrc",
          record: record
        )
      else { throw SetupOwnershipError.ownershipDrift(entry) }
      return
    }
    guard
      try Self.markerMatches(parentDescriptor: directoryDescriptor, name: "skhdrc", record: record)
    else { throw SetupOwnershipError.ownershipDrift(entry) }
    if record.originalKind == .directorySymbolicLink {
      guard try Self.markerMatches(descriptor: directoryDescriptor, record: record) else {
        throw SetupOwnershipError.ownershipDrift(entry.deletingLastPathComponent())
      }
    }
    if record.retainedOriginalPath != nil {
      let home = entry.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      try KeybindingProviderTransaction(homeDirectory: home)
        .preflightRetainedOriginalClaim(record)
    }
  }

  private static func markerMatches(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw SetupOwnershipError.ownershipDrift(URL(filePath: record.targetPath))
    }
    defer { Darwin.close(descriptor) }
    return try markerMatches(descriptor: descriptor, record: record)
  }

  private static func markerIsAbsent(
    parentDescriptor: Int32,
    name: String,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw SetupOwnershipError.ownershipDrift(URL(filePath: record.targetPath))
    }
    defer { Darwin.close(descriptor) }
    do {
      return try !KeybindingProviderPrimitives.claimMarkerExists(descriptor: descriptor)
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw SetupOwnershipError.system(
        "inspect legacy keybinding ownership marker",
        URL(filePath: record.targetPath),
        String(cString: strerror(failure.code))
      )
    }
  }

  private static func markerMatches(
    descriptor: Int32,
    record: SetupOwnershipRecord
  ) throws -> Bool {
    guard let nonce = record.claimNonce else { return false }
    do {
      return try KeybindingProviderPrimitives.claimMarkerMatches(
        descriptor: descriptor,
        nonce: nonce
      )
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw SetupOwnershipError.system(
        "read keybinding ownership marker",
        URL(filePath: record.targetPath),
        String(cString: strerror(failure.code))
      )
    }
  }

  static func requireAdoptableSymlink(
    _ metadata: stat,
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws {
    guard metadata.st_mode & S_IFMT == S_IFLNK, metadata.st_nlink == 1 else {
      throw KeybindingsApplyError.blocked(
        "symbolic link must have exactly one filesystem link"
      )
    }
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw SetupOwnershipError.system(
        "inspect adopted keybinding symlink",
        url,
        String(cString: strerror(errno))
      )
    }
    defer { Darwin.close(descriptor) }
    var pinned = stat()
    guard
      fstat(descriptor, &pinned) == 0,
      pinned.st_dev == metadata.st_dev,
      pinned.st_ino == metadata.st_ino,
      pinned.st_mode & S_IFMT == S_IFLNK,
      pinned.st_nlink == 1
    else { throw SetupOwnershipError.ownershipDrift(url) }
    do {
      guard try KeybindingProviderPrimitives.claimMarkerExists(descriptor: descriptor) else {
        return
      }
      throw KeybindingsApplyError.blocked(
        "symlink uses Macarchy's reserved claim-marker extended attribute"
      )
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      throw SetupOwnershipError.system(
        "inspect adopted keybinding symlink claim marker",
        url,
        String(cString: strerror(failure.code))
      )
    }
  }

  static func validateOwnershipRecord(
    _ record: SetupOwnershipRecord,
    context: SetupOwnershipManager.Context
  ) throws {
    let target = context.homeDirectory.appending(path: ".config/skhd/skhdrc")
    let expectedTarget = Self.managedTarget
    guard
      [.prepared, .applied, .teardownPrepared].contains(record.phase),
      record.kind == .symbolicLink,
      record.targetPath == target.path,
      record.installedDigest == sha256Digest(Data(expectedTarget.utf8)),
      record.linkDestination == expectedTarget,
      record.replacementDigest == nil
    else {
      throw SetupOwnershipError.invalidManifest(
        "keybinding entry ownership record does not match the managed provider link"
      )
    }
    if isLegacyCleanInstallRecord(record) { return }
    guard validClaimNonce(record.claimNonce) else {
      throw SetupOwnershipError.invalidManifest(
        "keybinding entry ownership record has no valid claim nonce"
      )
    }
    switch record.originalKind ?? .absent {
    case .absent:
      guard
        record.backupPath == nil,
        record.originalDigest == nil,
        record.originalLinkDestination == nil,
        record.originalFileMode == nil,
        record.originalMetadataDigest == nil,
        record.originalDevice == nil,
        record.originalInode == nil,
        record.originalSourceDigest == nil,
        record.originalInventory == nil,
        record.retainedOriginalPath == nil
      else {
        throw SetupOwnershipError.invalidManifest(
          "absent keybinding entry ownership contains adoption evidence"
        )
      }
    case .regularFile:
      let backup = context.stateRoot.appending(
        path: "state/setup/backups/keybindings-skhdrc"
      )
      let manager = SetupOwnershipManager()
      guard
        record.backupPath == manager.relativePath(backup, below: context.stateRoot),
        record.originalDigest != nil,
        record.originalLinkDestination == nil,
        record.originalFileMode != nil,
        record.originalMetadataDigest != nil,
        record.originalDevice != nil,
        record.originalInode != nil,
        record.originalSourceDigest == record.originalDigest,
        record.originalInventory == [],
        record.retainedOriginalPath == nil
      else {
        throw SetupOwnershipError.invalidManifest(
          "regular-file keybinding adoption evidence is incomplete"
        )
      }
    case .symbolicLink, .directorySymbolicLink:
      let retainedPath =
        record.originalKind == .directorySymbolicLink
        ? context.homeDirectory.appending(
          path: ".config/.skhd.macarchy-keybindings-\(record.claimNonce ?? "invalid")"
        ).path
        : context.homeDirectory.appending(
          path: ".config/skhd/.skhdrc.macarchy-keybindings-\(record.claimNonce ?? "invalid")"
        ).path
      guard
        record.backupPath == nil,
        let destination = record.originalLinkDestination,
        record.originalDigest == sha256Digest(Data(destination.utf8)),
        record.originalFileMode == nil,
        record.originalMetadataDigest == nil,
        record.originalDevice != nil,
        record.originalInode != nil,
        record.originalSourceDigest != nil,
        record.originalInventory
          == (record.originalKind == .directorySymbolicLink ? ["skhdrc"] : []),
        record.retainedOriginalPath == nil || record.retainedOriginalPath == retainedPath
      else {
        throw SetupOwnershipError.invalidManifest(
          "symbolic-link keybinding adoption evidence is incomplete"
        )
      }
    }
  }

  static func isLegacyCleanInstallRecord(_ record: SetupOwnershipRecord) -> Bool {
    record.phase == .applied
      && record.kind == .symbolicLink
      && record.backupPath == nil
      && record.originalDigest == nil
      && record.installedDigest == sha256Digest(Data(managedTarget.utf8))
      && record.linkDestination == managedTarget
      && record.replacementDigest == nil
      && record.originalKind == nil
      && record.originalLinkDestination == nil
      && record.originalFileMode == nil
      && record.originalMetadataDigest == nil
      && record.originalDevice == nil
      && record.originalInode == nil
      && record.originalSourceDigest == nil
      && record.originalInventory == nil
      && record.retainedOriginalPath == nil
      && record.claimNonce == nil
  }

  private static func validClaimNonce(_ value: String?) -> Bool {
    guard let value, let parsed = UUID(uuidString: value) else { return false }
    return parsed.uuidString.lowercased() == value
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

  private static let absentEvidence = KeybindingAdoptionEvidence(
    kind: .absent,
    linkDestination: nil,
    contentDigest: nil,
    inventory: []
  )

  private func result(
    _ status: KeybindingProviderStatus,
    entry: URL,
    expectedTarget: String,
    ownership: String,
    source: URL? = nil,
    originalTarget: String? = nil,
    message: String,
    sourceConfiguration: String? = nil,
    retainedOriginalRequirement: String? = nil,
    retainedOriginalStatus: String? = nil,
    adoptionEvidence: KeybindingAdoptionEvidence? = nil
  ) -> KeybindingProviderInspection {
    KeybindingProviderInspection(
      status: status,
      entryPoint: entry.path,
      ownership: ownership,
      source: source?.path,
      originalTarget: originalTarget,
      expectedTarget: expectedTarget,
      message: message,
      adoptionEvidenceDigest: adoptionEvidence?.digest,
      retainedOriginalRequirement: retainedOriginalRequirement,
      retainedOriginalStatus: retainedOriginalStatus,
      sourceConfiguration: sourceConfiguration,
      adoptionEvidence: adoptionEvidence
    )
  }
}

private enum EntryOwnershipClaim {
  case claimed(SetupOwnershipRecord)
  case prepared
  case unclaimed
  case invalid(String)
}
