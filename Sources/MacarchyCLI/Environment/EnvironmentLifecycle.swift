import Darwin
import Dispatch
import Foundation
import ThemeCore

enum EnvironmentEntryID: String, Codable, CaseIterable, Sendable {
  case kitty
  case zsh
  case starship
  case atuinConfiguration = "atuin_configuration"
  case atuinTheme = "atuin_theme"
}

enum EnvironmentEntryKind: String, Codable, Sendable {
  case absent
  case regularFile = "regular_file"
  case symbolicLink = "symbolic_link"
}

struct EnvironmentEntryEvidence: Codable, Equatable, Sendable {
  let kind: EnvironmentEntryKind
  let device: UInt64?
  let inode: UInt64?
  let mode: UInt32?
  let size: Int64?
  let linkDestination: String?
  let contentDigest: String?
  let metadataDigest: String?
  let inventory: [String]

  enum CodingKeys: String, CodingKey {
    case kind, device, inode, mode, size, inventory
    case linkDestination = "link_destination"
    case contentDigest = "content_digest"
    case metadataDigest = "metadata_digest"
  }
}

struct EnvironmentOwnershipRecord: Codable, Equatable, Sendable {
  let id: EnvironmentEntryID
  let publicPath: String
  let managedKind: String
  let managedTarget: String
  let original: EnvironmentEntryEvidence
  let retainedPath: String?

  enum CodingKeys: String, CodingKey {
    case id, original
    case publicPath = "public_path"
    case managedKind = "managed_kind"
    case managedTarget = "managed_target"
    case retainedPath = "retained_path"
  }
}

struct EnvironmentOwnership: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let generationID: String
  let records: [EnvironmentOwnershipRecord]
  let createdDirectories: [String]
  let originalThemeBridges: [EnvironmentThemeBridgeState.Entry]

  init(
    generationID: String,
    records: [EnvironmentOwnershipRecord],
    createdDirectories: [String],
    originalThemeBridges: [EnvironmentThemeBridgeState.Entry]
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.records = records.sorted { $0.id.rawValue < $1.id.rawValue }
    self.createdDirectories = createdDirectories.sorted()
    self.originalThemeBridges = originalThemeBridges.sorted { $0.path < $1.path }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case records
    case createdDirectories = "created_directories"
    case originalThemeBridges = "original_theme_bridges"
  }

  var hasValidShape: Bool {
    guard schemaVersion == Self.currentSchemaVersion,
      EnvironmentGenerationStore.isGenerationID(generationID),
      Set(records.map(\.id)).count == records.count,
      Set(createdDirectories).count == createdDirectories.count,
      Set(originalThemeBridges.map(\.path)).count == originalThemeBridges.count
    else { return false }

    return records.allSatisfy { record in
      let evidence = record.original
      let hasIdentity =
        evidence.device != nil && evidence.inode != nil && evidence.mode != nil
        && evidence.size != nil && evidence.metadataDigest != nil
      switch evidence.kind {
      case .absent:
        return record.retainedPath == nil
          && evidence.device == nil && evidence.inode == nil && evidence.mode == nil
          && evidence.size == nil && evidence.linkDestination == nil
          && evidence.contentDigest == nil && evidence.metadataDigest == nil
          && evidence.inventory.isEmpty
      case .regularFile:
        return record.id != .kitty && record.retainedPath != nil && hasIdentity
          && evidence.linkDestination == nil && evidence.contentDigest != nil
          && evidence.inventory.isEmpty
      case .symbolicLink:
        return record.retainedPath != nil && hasIdentity
          && evidence.linkDestination != nil && evidence.contentDigest == nil
          && (record.id == .kitty || evidence.inventory.isEmpty)
      }
    }
  }
}

enum EnvironmentTransactionOperation: String, Codable, Sendable {
  case apply
  case teardown
}

enum EnvironmentTransactionDirection: String, Codable, Sendable {
  case forward
  case rollback
}

struct EnvironmentTransaction: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let operation: EnvironmentTransactionOperation
  let direction: EnvironmentTransactionDirection
  let previousOwnership: EnvironmentOwnership?
  let proposedOwnership: EnvironmentOwnership?
  let previousCurrentDestination: String?
  let previousThemeGenerationID: String?
  let rollbackThemeBridges: [EnvironmentThemeBridgeState.Entry]

  init(
    operation: EnvironmentTransactionOperation,
    direction: EnvironmentTransactionDirection = .forward,
    previousOwnership: EnvironmentOwnership?,
    proposedOwnership: EnvironmentOwnership?,
    previousCurrentDestination: String?,
    previousThemeGenerationID: String? = nil,
    rollbackThemeBridges: [EnvironmentThemeBridgeState.Entry] = []
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.operation = operation
    self.direction = direction
    self.previousOwnership = previousOwnership
    self.proposedOwnership = proposedOwnership
    self.previousCurrentDestination = previousCurrentDestination
    self.previousThemeGenerationID = previousThemeGenerationID
    self.rollbackThemeBridges = rollbackThemeBridges
  }

  var rollingBack: Self {
    Self(
      operation: operation,
      direction: .rollback,
      previousOwnership: previousOwnership,
      proposedOwnership: proposedOwnership,
      previousCurrentDestination: previousCurrentDestination,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: rollbackThemeBridges
    )
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, direction
    case previousOwnership = "previous_ownership"
    case proposedOwnership = "proposed_ownership"
    case previousCurrentDestination = "previous_current_destination"
    case previousThemeGenerationID = "previous_theme_generation_id"
    case rollbackThemeBridges = "rollback_theme_bridges"
  }
}

enum EnvironmentLifecycleError: Error, CustomStringConvertible, Sendable {
  case adoptionRequired(String)
  case blocked(String)
  case drift(String)
  case system(String, URL, Int32)

  var description: String {
    switch self {
    case .adoptionRequired(let digest):
      "environment adoption requires the reviewed evidence digest \(digest)"
    case .blocked(let reason):
      "environment lifecycle is blocked: \(reason)"
    case .drift(let reason):
      "environment ownership drifted: \(reason)"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

struct EnvironmentLifecycleLock: Sendable {
  private static let processSemaphore = DispatchSemaphore(value: 1)

  let stateRoot: URL

  func acquire() throws -> Int32 {
    Self.processSemaphore.wait()
    do {
      let runDirectory = stateRoot.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
      let lockURL = runDirectory.appending(path: "environment.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw EnvironmentLifecycleError.system("open environment lifecycle lock", lockURL, errno)
      }
      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        let code = errno
        Darwin.close(descriptor)
        throw EnvironmentLifecycleError.system("acquire environment lifecycle lock", lockURL, code)
      }
      return descriptor
    } catch {
      Self.processSemaphore.signal()
      throw error
    }
  }

  func release(_ descriptor: Int32) {
    Darwin.close(descriptor)
    Self.processSemaphore.signal()
  }
}

struct EnvironmentThemeBridgeState: Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let path: String
    let data: Data?
    let mode: UInt16?

    var hasValidShape: Bool {
      switch (data, mode) {
      case (nil, nil):
        true
      case (.some, .some(let mode)):
        mode & ~0o7777 == 0
      default:
        false
      }
    }
  }

  let entries: [Entry]

  static func capture(profile: EnvironmentProfile, stateRoot: URL) throws -> Self {
    var ids = Set<EnvironmentEntryID>()
    if profile.terminal == .kitty { ids.insert(.kitty) }
    if profile.prompt == .starship { ids.insert(.starship) }
    return try capture(ids: ids, stateRoot: stateRoot)
  }

  static func capture(ids: Set<EnvironmentEntryID>, stateRoot: URL) throws -> Self {
    let urls = paths(ids: ids, stateRoot: stateRoot).map { URL(filePath: $0) }
    return try Self(
      entries: urls.map { url in
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
          if errno == ENOENT { return Entry(path: url.path, data: nil, mode: nil) }
          throw EnvironmentLifecycleError.system("inspect theme bridge", url, errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
          throw EnvironmentLifecycleError.blocked("theme bridge is not a regular file: \(url.path)")
        }
        return Entry(
          path: url.path,
          data: try BoundedRegularFile.read(at: url).data,
          mode: UInt16(metadata.st_mode & 0o7777)
        )
      }
    )
  }

  static func paths(ids: Set<EnvironmentEntryID>, stateRoot: URL) -> [String] {
    (ids.contains(.kitty)
      ? [stateRoot.appending(path: "state/adapters/kitty.conf").path] : [])
      + (ids.contains(.starship)
        ? [stateRoot.appending(path: StarshipAdapter.bridgePath).path] : [])
  }

  static func pathsAreValid(_ entries: [Entry], stateRoot: URL) -> Bool {
    let paths = entries.map(\.path)
    return entries.allSatisfy(\.hasValidShape)
      && Set(paths).count == paths.count
      && Set(paths).isSubset(of: Set(Self.paths(ids: [.kitty, .starship], stateRoot: stateRoot)))
  }

  func restore() throws {
    for entry in entries {
      let url = URL(filePath: entry.path)
      if let data = entry.data {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        if let mode = entry.mode, chmod(url.path, mode_t(mode)) != 0 {
          throw EnvironmentLifecycleError.system("restore theme bridge mode", url, errno)
        }
      } else if unlink(url.path) != 0, errno != ENOENT {
        throw EnvironmentLifecycleError.system("remove new theme bridge", url, errno)
      }
    }
  }
}

struct EnvironmentEntryInspection: Encodable, Equatable, Sendable {
  let id: String
  let path: String
  let status: String
  let ownership: String
  let message: String
  let evidence: EnvironmentEntryEvidence?

  enum CodingKeys: String, CodingKey {
    case id, path, status, ownership, message, evidence
  }
}

struct EnvironmentProviderInspection: Sendable {
  let entries: [EnvironmentEntryInspection]
  let ownership: EnvironmentOwnership?
  let adoptionEvidenceDigest: String?
  let blockedMessage: String?
  let desiredEntries: [EnvironmentManagedEntry]
  let externalEvidence: [EnvironmentEntryID: EnvironmentEntryEvidence]
  let createdDirectories: [String]

  var isBlocked: Bool { blockedMessage != nil || entries.contains { $0.status == "drifted" } }
}

struct EnvironmentManagedEntry: Equatable, Sendable {
  enum ManagedKind: String, Sendable {
    case kittyDirectory = "kitty_directory"
    case symbolicLink = "symbolic_link"
  }

  let id: EnvironmentEntryID
  let url: URL
  let kind: ManagedKind
  let target: String
}

struct EnvironmentStateStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "environment", directoryHint: .isDirectory)
  }
  private var ownershipURL: URL { directory.appending(path: "ownership.json") }
  private var transactionURL: URL { directory.appending(path: "transaction.json") }

  func readOwnership() throws -> EnvironmentOwnership? {
    try read(EnvironmentOwnership.self, at: ownershipURL) { value in
      value.hasValidShape
    }
  }

  func writeOwnership(_ ownership: EnvironmentOwnership?) throws {
    if let ownership {
      try write(ownership, to: ownershipURL)
    } else {
      try remove(ownershipURL)
    }
  }

  func readTransaction() throws -> EnvironmentTransaction? {
    try read(EnvironmentTransaction.self, at: transactionURL) { value in
      value.schemaVersion == EnvironmentTransaction.currentSchemaVersion
        && (value.operation != .apply || value.proposedOwnership != nil)
        && (value.previousOwnership?.hasValidShape ?? true)
        && (value.proposedOwnership?.hasValidShape ?? true)
        && Self.currentDestinationIsValid(value.previousCurrentDestination)
        && EnvironmentThemeBridgeState.pathsAreValid(
          value.rollbackThemeBridges,
          stateRoot: stateRoot
        )
    }
  }

  func writeTransaction(_ transaction: EnvironmentTransaction) throws {
    try write(transaction, to: transactionURL)
  }

  func removeTransaction() throws { try remove(transactionURL) }

  var transactionExists: Bool {
    var metadata = stat()
    return lstat(transactionURL.path, &metadata) == 0
  }

  private func read<T: Decodable>(
    _ type: T.Type,
    at url: URL,
    validate: (T) -> Bool
  ) throws -> T? {
    let stateDescriptor: Int32
    let directoryDescriptor: Int32
    do {
      (stateDescriptor, directoryDescriptor) = try openDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: directoryDescriptor,
        name: url.lastPathComponent,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw EnvironmentLifecycleError.blocked("\(url.path) is not a regular file")
    }
    let value = try JSONDecoder().decode(
      type,
      from: PinnedFilesystem.readRegularFile(
        parentDescriptor: directoryDescriptor,
        name: url.lastPathComponent,
        url: url,
        maximumSize: 131_072
      ).data
    )
    guard validate(value) else {
      throw EnvironmentLifecycleError.blocked("\(url.path) is invalid")
    }
    return value
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let (stateDescriptor, directoryDescriptor) = try openDirectory(create: true)
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: directoryDescriptor,
      name: url.lastPathComponent,
      url: url,
      data: encoder.encode(value),
      mode: 0o600
    )
  }

  private func remove(_ url: URL) throws {
    let stateDescriptor: Int32
    let directoryDescriptor: Int32
    do {
      (stateDescriptor, directoryDescriptor) = try openDirectory(create: false)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer {
      Darwin.close(directoryDescriptor)
      Darwin.close(stateDescriptor)
    }
    let removed = url.lastPathComponent.withCString {
      Darwin.unlinkat(directoryDescriptor, $0, 0)
    }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove state", url, errno)
    }
    if removed == 0, fsync(directoryDescriptor) != 0 {
      throw EnvironmentLifecycleError.system("sync removed state", url, errno)
    }
  }

  private func openDirectory(create: Bool) throws -> (Int32, Int32) {
    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    do {
      let directoryDescriptor =
        try create
        ? PinnedFilesystem.openOrCreateChildDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: directory,
          mode: 0o700
        )
        : PinnedFilesystem.openDirectory(
          parentDescriptor: stateDescriptor,
          name: "environment",
          url: directory
        )
      return (stateDescriptor, directoryDescriptor)
    } catch {
      Darwin.close(stateDescriptor)
      throw error
    }
  }

  private static func currentDestinationIsValid(_ destination: String?) -> Bool {
    guard let destination else { return true }
    let prefix = "generations/"
    guard destination.hasPrefix(prefix), !destination.dropFirst(prefix.count).contains("/") else {
      return false
    }
    return EnvironmentGenerationStore.isGenerationID(String(destination.dropFirst(prefix.count)))
  }
}

struct EnvironmentProviderInspector: Sendable {
  private static let maximumExternalFileSize = 4 * 1_048_576
  private static let maximumKittyEntries = 128

  func inspect(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL
  ) -> EnvironmentProviderInspection {
    do {
      let store = EnvironmentStateStore(stateRoot: stateRoot)
      let ownership = try store.readOwnership()
      let currentDestination = try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination()
      if let ownership {
        guard currentDestination == "generations/\(ownership.generationID)" else {
          throw EnvironmentLifecycleError.drift(
            "environment ownership and the selected generation disagree"
          )
        }
      } else if currentDestination != nil {
        throw EnvironmentLifecycleError.drift(
          "an environment generation is selected without ownership"
        )
      }
      let entries = desiredEntries(
        profile: composition.profile,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      )
      let setupContext = SetupOwnershipManager.Context(homeDirectory: homeDirectory)
      var legacyIDs = Set<String>()
      if entries.contains(where: { $0.id == .kitty }) { legacyIDs.insert("kitty.include") }
      if entries.contains(where: { $0.id == .atuinConfiguration }) {
        legacyIDs.formUnion(["atuin.selector", "atuin.theme-link"])
      }
      if entries.contains(where: { $0.id == .starship }) {
        legacyIDs.insert("starship.configuration-link")
      }
      let conflicts = try SetupOwnershipManager().readRecords(context: setupContext)
        .map(\.id).filter { legacyIDs.contains($0) }
      guard conflicts.isEmpty else {
        throw EnvironmentLifecycleError.blocked(
          "legacy setup ownership must be torn down before environment adoption: \(conflicts.sorted().joined(separator: ", "))"
        )
      }
      let owned = Dictionary(uniqueKeysWithValues: (ownership?.records ?? []).map { ($0.id, $0) })
      let allowed = Dictionary(
        uniqueKeysWithValues: allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
          .map { ($0.id, $0) }
      )
      for record in ownership?.records ?? [] {
        guard let entry = allowed[record.id],
          record.publicPath == entry.url.path,
          record.managedKind == entry.kind.rawValue,
          record.managedTarget == entry.target
        else {
          throw EnvironmentLifecycleError.blocked(
            "ownership for \(record.id.rawValue) contains an unexpected provider path or target"
          )
        }
      }
      var inspections = [EnvironmentEntryInspection]()
      var evidence = [EnvironmentEntryID: EnvironmentEntryEvidence]()
      var createdDirectories = Set<String>()

      for entry in entries {
        let hasExternalAncestor = try hasSymlinkAncestor(
          entry.url,
          stoppingAt: homeDirectory
        )
        if entry.id == .atuinTheme, hasExternalAncestor, owned[entry.id] == nil {
          let captured = try capture(entry.url, kittyDirectory: false)
          guard captured.kind == .symbolicLink,
            captured.linkDestination == entry.target
          else {
            throw EnvironmentLifecycleError.blocked(
              "the Atuin theme path is below an externally owned directory and is not the exact canonical link"
            )
          }
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: "external",
              ownership: "external_exact",
              message: "The exact canonical Atuin theme link remains externally owned.",
              evidence: captured
            )
          )
          continue
        }
        guard !hasExternalAncestor else {
          throw EnvironmentLifecycleError.blocked(
            "provider entry is below a symlink-owned parent: \(entry.url.path)"
          )
        }

        if let record = owned[entry.id] {
          guard record.publicPath == entry.url.path,
            record.managedKind == entry.kind.rawValue,
            record.managedTarget == entry.target
          else {
            throw EnvironmentLifecycleError.drift("ownership for \(entry.id.rawValue) is invalid")
          }
          let exact = try managedEntryIsExact(entry)
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: exact ? "managed" : "drifted",
              ownership: "macarchy",
              message: exact
                ? "The provider entry is managed." : "The managed provider entry drifted.",
              evidence: nil
            )
          )
          continue
        }

        let captured = try capture(entry.url, kittyDirectory: entry.kind == .kittyDirectory)
        evidence[entry.id] = captured
        for directory in try missingParentDirectories(of: entry.url, homeDirectory: homeDirectory) {
          createdDirectories.insert(directory.path)
        }
        let absent = captured.kind == .absent
        inspections.append(
          EnvironmentEntryInspection(
            id: entry.id.rawValue,
            path: entry.url.path,
            status: absent ? "install_required" : "adoption_required",
            ownership: "external",
            message: absent
              ? "The provider entry will be installed."
              : "The provider entry must be adopted with reviewed evidence.",
            evidence: captured
          )
        )
      }

      for record in ownership?.records ?? [] where !entries.contains(where: { $0.id == record.id })
      {
        let entry = managedEntry(from: record)
        let exact = try managedEntryIsExact(entry)
        inspections.append(
          EnvironmentEntryInspection(
            id: record.id.rawValue,
            path: record.publicPath,
            status: exact ? "restoration_required" : "drifted",
            ownership: "macarchy",
            message: exact
              ? "The disabled provider entry will be restored."
              : "The disabled provider entry drifted before restoration.",
            evidence: nil
          )
        )
      }

      let adoptionRequired = inspections.contains { $0.status == "adoption_required" }
      return EnvironmentProviderInspection(
        entries: inspections.sorted { $0.id < $1.id },
        ownership: ownership,
        adoptionEvidenceDigest: adoptionRequired
          ? try adoptionDigest(
            composition: composition,
            entries: inspections,
            selected: entries
          ) : nil,
        blockedMessage: nil,
        desiredEntries: entries,
        externalEvidence: evidence,
        createdDirectories: createdDirectories.sorted()
      )
    } catch {
      return EnvironmentProviderInspection(
        entries: [],
        ownership: nil,
        adoptionEvidenceDigest: nil,
        blockedMessage: String(describing: error),
        desiredEntries: [],
        externalEvidence: [:],
        createdDirectories: []
      )
    }
  }

  func desiredEntries(
    profile: EnvironmentProfile,
    homeDirectory: URL,
    stateRoot: URL
  ) -> [EnvironmentManagedEntry] {
    let enabled: Set<EnvironmentEntryID> = Set(
      (profile.terminal == .kitty ? [.kitty] : [])
        + (profile.shell == .zsh ? [.zsh] : [])
        + (profile.prompt == .starship ? [.starship] : [])
        + (profile.history == .atuin ? [.atuinConfiguration, .atuinTheme] : [])
    )
    return allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
      .filter { enabled.contains($0.id) }
  }

  func allManagedEntries(homeDirectory: URL, stateRoot: URL) -> [EnvironmentManagedEntry] {
    let home = homeDirectory.standardizedFileURL
    let state = stateRoot.standardizedFileURL
    return [
      EnvironmentManagedEntry(
        id: .kitty,
        url: home.appending(path: ".config/kitty", directoryHint: .isDirectory),
        kind: .kittyDirectory,
        target: state.appending(path: "environment/current/kitty/kitty.conf").path
      ),
      EnvironmentManagedEntry(
        id: .zsh,
        url: home.appending(path: ".zshrc"),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/zsh/.zshrc").path
      ),
      EnvironmentManagedEntry(
        id: .starship,
        url: home.appending(path: ".config/starship.toml"),
        kind: .symbolicLink,
        target: state.appending(path: StarshipAdapter.bridgePath).path
      ),
      EnvironmentManagedEntry(
        id: .atuinConfiguration,
        url: home.appending(path: ".config/atuin/config.toml"),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/atuin/config.toml").path
      ),
      EnvironmentManagedEntry(
        id: .atuinTheme,
        url: home.appending(path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(AtuinAdapter.outputPath)").path
      ),
    ]
  }

  func capture(_ url: URL, kittyDirectory: Bool) throws -> EnvironmentEntryEvidence {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT {
        return EnvironmentEntryEvidence(
          kind: .absent,
          device: nil,
          inode: nil,
          mode: nil,
          size: nil,
          linkDestination: nil,
          contentDigest: nil,
          metadataDigest: nil,
          inventory: []
        )
      }
      throw EnvironmentLifecycleError.system("inspect provider entry", url, errno)
    }
    let common = (
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      mode: UInt32(metadata.st_mode),
      size: Int64(metadata.st_size)
    )
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
      return EnvironmentEntryEvidence(
        kind: .symbolicLink,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: destination,
        contentDigest: nil,
        metadataDigest: try metadataDigest(at: url, symbolicLink: true),
        inventory: kittyDirectory ? try kittyInventory(link: url, destination: destination) : []
      )
    case S_IFREG where !kittyDirectory:
      guard metadata.st_nlink == 1 else {
        throw EnvironmentLifecycleError.blocked("\(url.path) is hard-linked")
      }
      let data = try BoundedRegularFile.read(
        at: url,
        maximumSize: Self.maximumExternalFileSize
      ).data
      return EnvironmentEntryEvidence(
        kind: .regularFile,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: nil,
        contentDigest: sha256Digest(data),
        metadataDigest: try metadataDigest(at: url, symbolicLink: false),
        inventory: []
      )
    default:
      throw EnvironmentLifecycleError.blocked(
        "\(url.path) has an unsupported provider entry type"
      )
    }
  }

  func managedEntryIsExact(_ entry: EnvironmentManagedEntry) throws -> Bool {
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: entry.url.deletingLastPathComponent())
    } catch let error as PinnedFilesystemError where error.code == ENOENT || error.code == ENOTDIR {
      return false
    }
    defer { Darwin.close(parent) }
    return try managedEntryIsExact(entry, parentDescriptor: parent)
  }

  func managedEntryIsExact(
    _ entry: EnvironmentManagedEntry,
    parentDescriptor: Int32
  ) throws -> Bool {
    var metadata = stat()
    let inspected = entry.url.lastPathComponent.withCString {
      Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard inspected == 0 else {
      if errno == ENOENT { return false }
      throw EnvironmentLifecycleError.system("inspect managed provider entry", entry.url, errno)
    }
    switch entry.kind {
    case .symbolicLink:
      guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
      return try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      ) == entry.target
    case .kittyDirectory:
      guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let children = try PinnedFilesystem.directoryEntries(
        descriptor: directory,
        url: entry.url,
        limit: 2
      )
      guard !children.truncated, children.entries == ["kitty.conf"] else { return false }
      let configuration = entry.url.appending(path: "kitty.conf")
      return try PinnedFilesystem.symlinkDestination(
        parentDescriptor: directory,
        name: "kitty.conf",
        url: configuration
      ) == entry.target
    }
  }

  func capturePinned(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    kittyDirectory: Bool
  ) throws -> EnvironmentEntryEvidence {
    let metadata: stat
    do {
      metadata = try PinnedFilesystem.metadata(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return EnvironmentEntryEvidence(
        kind: .absent,
        device: nil,
        inode: nil,
        mode: nil,
        size: nil,
        linkDestination: nil,
        contentDigest: nil,
        metadataDigest: nil,
        inventory: []
      )
    }
    let common = (
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      mode: UInt32(metadata.st_mode),
      size: Int64(metadata.st_size)
    )
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      let destination = try PinnedFilesystem.symlinkDestination(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
      return EnvironmentEntryEvidence(
        kind: .symbolicLink,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: destination,
        contentDigest: nil,
        metadataDigest: try metadataDigest(
          parentDescriptor: parentDescriptor,
          name: name,
          url: url,
          symbolicLink: true
        ),
        inventory: kittyDirectory ? try kittyInventory(link: url, destination: destination) : []
      )
    case S_IFREG where !kittyDirectory:
      guard metadata.st_nlink == 1 else {
        throw EnvironmentLifecycleError.blocked("\(url.path) is hard-linked")
      }
      let data = try PinnedFilesystem.readRegularFile(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url,
        maximumSize: Self.maximumExternalFileSize
      ).data
      return EnvironmentEntryEvidence(
        kind: .regularFile,
        device: common.device,
        inode: common.inode,
        mode: common.mode,
        size: common.size,
        linkDestination: nil,
        contentDigest: sha256Digest(data),
        metadataDigest: try metadataDigest(
          parentDescriptor: parentDescriptor,
          name: name,
          url: url,
          symbolicLink: false
        ),
        inventory: []
      )
    default:
      throw EnvironmentLifecycleError.blocked(
        "\(url.path) has an unsupported provider entry type"
      )
    }
  }

  func managedEntry(from record: EnvironmentOwnershipRecord) -> EnvironmentManagedEntry {
    EnvironmentManagedEntry(
      id: record.id,
      url: URL(filePath: record.publicPath),
      kind: record.managedKind == EnvironmentManagedEntry.ManagedKind.kittyDirectory.rawValue
        ? .kittyDirectory : .symbolicLink,
      target: record.managedTarget
    )
  }

  private func adoptionDigest(
    composition: EnvironmentComposition,
    entries: [EnvironmentEntryInspection],
    selected: [EnvironmentManagedEntry]
  ) throws -> String {
    struct Payload: Encodable {
      let schemaVersion: Int
      let inputDigest: String
      let renderedDigest: String
      let providers: [String]
      let entries: [Entry]

      struct Entry: Encodable {
        let id: String
        let path: String
        let target: String
        let evidence: EnvironmentEntryEvidence?
      }
    }
    let targets = Dictionary(uniqueKeysWithValues: selected.map { ($0.id.rawValue, $0.target) })
    let payload = Payload(
      schemaVersion: 1,
      inputDigest: composition.inputDigest,
      renderedDigest: composition.renderedDigest,
      providers: [
        composition.profile.terminal.rawValue,
        composition.profile.shell.rawValue,
        composition.profile.prompt.rawValue,
        composition.profile.history.rawValue,
      ],
      entries: entries.filter { targets[$0.id] != nil }.map {
        Payload.Entry(
          id: $0.id,
          path: $0.path,
          target: targets[$0.id, default: ""],
          evidence: $0.evidence
        )
      }.sorted { $0.id < $1.id }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256Digest(try encoder.encode(payload))
  }

  private func kittyInventory(link: URL, destination: String) throws -> [String] {
    let root =
      destination.hasPrefix("/")
      ? URL(filePath: destination)
      : link.deletingLastPathComponent().appending(path: destination)
    var rootMetadata = stat()
    guard stat(root.path, &rootMetadata) == 0,
      rootMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw EnvironmentLifecycleError.blocked("Kitty directory link target is not a directory")
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      throw EnvironmentLifecycleError.blocked("cannot inventory Kitty directory link target")
    }
    var result = [String]()
    var bytes = 0
    let rootComponents = root.resolvingSymlinksInPath().pathComponents
    for case let item as URL in enumerator {
      guard result.count < Self.maximumKittyEntries else {
        throw EnvironmentLifecycleError.blocked("Kitty directory inventory exceeds 128 entries")
      }
      var metadata = stat()
      guard lstat(item.path, &metadata) == 0 else {
        throw EnvironmentLifecycleError.system("inventory Kitty entry", item, errno)
      }
      let relative = item.resolvingSymlinksInPath().pathComponents.dropFirst(
        rootComponents.count
      ).joined(separator: "/")
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        result.append("directory:\(relative)")
      case S_IFLNK:
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
        result.append("symlink:\(relative):\(target)")
      case S_IFREG:
        let data = try BoundedRegularFile.read(
          at: item,
          maximumSize: Self.maximumExternalFileSize
        ).data
        bytes += data.count
        guard bytes <= Self.maximumExternalFileSize else {
          throw EnvironmentLifecycleError.blocked("Kitty directory inventory exceeds 4 MiB")
        }
        result.append("file:\(relative):\(sha256Digest(data))")
      default:
        throw EnvironmentLifecycleError.blocked("Kitty directory contains an unsupported entry")
      }
    }
    return result.sorted()
  }

  func hasSymlinkAncestor(_ url: URL, stoppingAt root: URL) throws -> Bool {
    var parent = url.deletingLastPathComponent()
    while parent.path != root.path, parent.path.hasPrefix(root.path + "/") {
      var metadata = stat()
      if lstat(parent.path, &metadata) == 0 {
        if metadata.st_mode & S_IFMT == S_IFLNK { return true }
      } else if errno != ENOENT {
        throw EnvironmentLifecycleError.system("inspect provider ancestor", parent, errno)
      }
      parent.deleteLastPathComponent()
    }
    return false
  }

  private func metadataDigest(at url: URL, symbolicLink: Bool) throws -> String {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | (symbolicLink ? O_SYMLINK : O_NOFOLLOW))
    }
    guard descriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open provider metadata", url, errno)
    }
    defer { Darwin.close(descriptor) }
    return try SetupOwnershipManager().regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "environment provider entry"
    ).restorableMetadataDigest(excludingExtendedAttribute: "com.apple.provenance")
  }

  private func metadataDigest(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    symbolicLink: Bool
  ) throws -> String {
    let descriptor = name.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | (symbolicLink ? O_SYMLINK : O_NOFOLLOW)
      )
    }
    guard descriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open provider metadata", url, errno)
    }
    defer { Darwin.close(descriptor) }
    return try SetupOwnershipManager().regularFileSnapshot(
      descriptor: descriptor,
      url: url,
      label: "environment provider entry"
    ).restorableMetadataDigest(excludingExtendedAttribute: "com.apple.provenance")
  }

  private func missingParentDirectories(of url: URL, homeDirectory: URL) throws -> [URL] {
    let home = homeDirectory.standardizedFileURL
    let parent = url.deletingLastPathComponent().standardizedFileURL
    guard parent.path == home.path || parent.path.hasPrefix(home.path + "/") else {
      throw EnvironmentLifecycleError.blocked("provider entry is outside the selected home")
    }
    var current = home
    var missing = [URL]()
    if parent.path != home.path {
      for component in parent.path.dropFirst(home.path.count + 1).split(separator: "/") {
        current.append(path: String(component), directoryHint: .isDirectory)
        var metadata = stat()
        if lstat(current.path, &metadata) == 0 {
          guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw EnvironmentLifecycleError.blocked(
              "provider ancestor is not a real directory: \(current.path)"
            )
          }
        } else if errno == ENOENT {
          missing.append(current)
        } else {
          throw EnvironmentLifecycleError.system("inspect provider directory", current, errno)
        }
      }
    }
    return missing
  }
}

struct EnvironmentTransactionCoordinator: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  private let inspector = EnvironmentProviderInspector()

  func recoverLocked() throws -> Bool {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else { return false }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    switch transaction.direction {
    case .forward:
      switch transaction.operation {
      case .apply:
        guard let proposed = transaction.proposedOwnership else {
          throw EnvironmentLifecycleError.blocked("apply recovery has no proposed ownership")
        }
        _ = try EnvironmentGenerationStore(stateRoot: stateRoot).manifest(
          generationID: proposed.generationID
        )
        try transition(from: transaction.previousOwnership, to: proposed)
        try restoreReleasedThemeBridges(from: transaction.previousOwnership, to: proposed)
        try EnvironmentGenerationStore(stateRoot: stateRoot).select(proposed.generationID)
        try store.writeOwnership(proposed)
      case .teardown:
        try transition(from: transaction.previousOwnership, to: nil)
        try EnvironmentThemeBridgeState(
          entries: transaction.previousOwnership?.originalThemeBridges ?? []
        ).restore()
        try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
        try store.writeOwnership(nil)
      }
    case .rollback:
      try transition(from: transaction.proposedOwnership, to: transaction.previousOwnership)
      try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
        transaction.previousCurrentDestination
      )
      try restoreRollbackThemeBridges(transaction)
      try store.writeOwnership(transaction.previousOwnership)
    }
    try store.removeTransaction()
    return true
  }

  func applyLocked(
    composition: EnvironmentComposition,
    inspection: EnvironmentProviderInspection,
    adoptionDigest: String?,
    previousThemeGenerationID: String? = nil,
    themeBridges: EnvironmentThemeBridgeState
  ) throws -> (changed: Bool, generationID: String) {
    if try recoverLocked() {
      throw EnvironmentLifecycleError.blocked(
        "interrupted environment state was recovered; review plan and apply again"
      )
    }
    guard !inspection.isBlocked else {
      throw EnvironmentLifecycleError.blocked(
        inspection.blockedMessage ?? "provider ownership drifted"
      )
    }
    if let expected = inspection.adoptionEvidenceDigest, adoptionDigest != expected {
      throw EnvironmentLifecycleError.adoptionRequired(expected)
    }
    if inspection.adoptionEvidenceDigest == nil, adoptionDigest != nil {
      throw EnvironmentLifecycleError.blocked("no environment adoption is currently required")
    }

    let generationStore = EnvironmentGenerationStore(stateRoot: stateRoot)
    let previousCurrent = try generationStore.currentDestination()
    let staged = try generationStore.stage(composition)
    let previous = inspection.ownership
    let previousByID = Dictionary(
      uniqueKeysWithValues: (previous?.records ?? []).map { ($0.id, $0) })
    var records = [EnvironmentOwnershipRecord]()
    for entry in inspection.desiredEntries {
      if let existing = previousByID[entry.id] {
        records.append(existing)
        continue
      }
      guard let evidence = inspection.externalEvidence[entry.id] else {
        // Exact externally owned seams below symlink-owned parents remain outside ownership.
        continue
      }
      records.append(
        EnvironmentOwnershipRecord(
          id: entry.id,
          publicPath: entry.url.path,
          managedKind: entry.kind.rawValue,
          managedTarget: entry.target,
          original: evidence,
          retainedPath: evidence.kind == .absent
            ? nil
            : retainedURL(for: entry).path
        )
      )
    }
    let desiredBridgePaths = Set(
      EnvironmentThemeBridgeState.paths(
        ids: Set(inspection.desiredEntries.map(\.id)),
        stateRoot: stateRoot
      )
    )
    let previousBridges = Dictionary(
      uniqueKeysWithValues: (previous?.originalThemeBridges ?? []).map { ($0.path, $0) }
    )
    let capturedBridges = Dictionary(
      uniqueKeysWithValues: themeBridges.entries.map { ($0.path, $0) }
    )
    let originalThemeBridges = try desiredBridgePaths.sorted().map { path in
      guard let entry = previousBridges[path] ?? capturedBridges[path] else {
        throw EnvironmentLifecycleError.blocked(
          "the original theme bridge was not captured: \(path)"
        )
      }
      return entry
    }
    let proposed = EnvironmentOwnership(
      generationID: staged.manifest.generationID,
      records: records,
      createdDirectories: Array(
        Set(
          (previous?.createdDirectories ?? []).filter { directory in
            inspection.desiredEntries.contains {
              $0.url.path.hasPrefix(directory + "/")
            }
          }
        ).union(inspection.createdDirectories)
      ),
      originalThemeBridges: originalThemeBridges
    )
    let generationChanged = previous?.generationID != proposed.generationID
    let ownershipChanged = previous?.records != proposed.records
    let changed = generationChanged || ownershipChanged

    // Re-capture every external entry after staging and before publishing the claim.
    for (id, expected) in inspection.externalEvidence {
      guard let entry = inspection.desiredEntries.first(where: { $0.id == id }),
        try inspector.capture(entry.url, kittyDirectory: entry.kind == .kittyDirectory) == expected
      else {
        throw EnvironmentLifecycleError.blocked(
          "provider entry changed after planning; run environment plan again"
        )
      }
    }
    let transaction = EnvironmentTransaction(
      operation: .apply,
      previousOwnership: previous,
      proposedOwnership: proposed,
      previousCurrentDestination: previousCurrent,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: themeBridges.entries
    )
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      if changed {
        try generationStore.select(proposed.generationID)
        try transition(from: previous, to: proposed)
        try restoreReleasedThemeBridges(from: previous, to: proposed)
        try store.writeOwnership(proposed)
      }
      return (changed, proposed.generationID)
    } catch {
      let applyError = error
      do {
        try store.writeTransaction(transaction.rollingBack)
      } catch {
        throw EnvironmentLifecycleError.blocked(
          "apply failed and rollback direction could not be persisted: \(error)"
        )
      }
      do {
        try transition(from: proposed, to: previous)
        try generationStore.restoreCurrent(previousCurrent)
        try EnvironmentThemeBridgeState(entries: themeBridges.entries).restore()
        try store.writeOwnership(previous)
        try store.removeTransaction()
      } catch {
        throw EnvironmentLifecycleError.blocked(
          "apply failed and rollback requires recovery: \(error)"
        )
      }
      throw applyError
    }
  }

  func finishApplyLocked() throws {
    try EnvironmentStateStore(stateRoot: stateRoot).removeTransaction()
  }

  func rollbackApplyLocked() throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction(), transaction.operation == .apply else {
      throw EnvironmentLifecycleError.blocked("no environment apply transaction can be rolled back")
    }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    let rollback = transaction.rollingBack
    try store.writeTransaction(rollback)
    try transition(from: rollback.proposedOwnership, to: rollback.previousOwnership)
    try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
      rollback.previousCurrentDestination
    )
    try restoreRollbackThemeBridges(rollback)
    try store.writeOwnership(rollback.previousOwnership)
    try store.removeTransaction()
  }

  func teardownLocked(dryRun: Bool) throws -> (changed: Bool, message: String) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    if dryRun {
      guard try store.readTransaction() == nil else {
        throw EnvironmentLifecycleError.blocked(
          "an interrupted environment transaction must be recovered before teardown preview"
        )
      }
      guard let ownership = try store.readOwnership() else {
        guard try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() == nil
        else {
          throw EnvironmentLifecycleError.drift(
            "an environment generation is selected without ownership"
          )
        }
        return (false, "No managed environment ownership exists.")
      }
      try validate(ownership)
      try preflight(ownership)
      return (false, "Managed provider entries are ready for exact restoration.")
    }
    let recovered = try recoverLocked()
    guard let ownership = try store.readOwnership() else {
      guard try EnvironmentGenerationStore(stateRoot: stateRoot).currentDestination() == nil else {
        throw EnvironmentLifecycleError.drift(
          "an environment generation is selected without ownership"
        )
      }
      return (
        recovered,
        recovered
          ? "The interrupted environment teardown was recovered."
          : "No managed environment ownership exists."
      )
    }
    try validate(ownership)
    try preflight(ownership)
    let transaction = EnvironmentTransaction(
      operation: .teardown,
      previousOwnership: ownership,
      proposedOwnership: nil,
      previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination(),
      rollbackThemeBridges: try EnvironmentThemeBridgeState.capture(
        ids: Set(ownership.records.map(\.id)),
        stateRoot: stateRoot
      ).entries
    )
    try store.writeTransaction(transaction)
    try transition(from: ownership, to: nil)
    try EnvironmentThemeBridgeState(entries: ownership.originalThemeBridges).restore()
    try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
    try store.writeOwnership(nil)
    try store.removeTransaction()
    return (true, "The exact adopted provider entries were restored.")
  }

  private func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?
  ) throws {
    let oldByID = Dictionary(uniqueKeysWithValues: (old?.records ?? []).map { ($0.id, $0) })
    let newByID = Dictionary(uniqueKeysWithValues: (new?.records ?? []).map { ($0.id, $0) })

    for record in old?.records.reversed() ?? [] where newByID[record.id] == nil {
      do {
        try restore(record)
      } catch {
        throw EnvironmentLifecycleError.blocked(
          "restore \(record.id.rawValue) failed: \(error)"
        )
      }
    }
    for record in new?.records ?? [] {
      if oldByID[record.id] == nil {
        try install(record)
      } else {
        let entry = inspector.managedEntry(from: record)
        if try !inspector.managedEntryIsExact(entry) {
          // A rollback can encounter the restored original at the public path.
          if try evidence(
            at: entry.url,
            matches: record.original,
            kittyDirectory: record.id == .kitty
          ) {
            try retainOriginal(record)
            try publishManaged(entry)
          } else {
            throw EnvironmentLifecycleError.drift(entry.url.path)
          }
        }
      }
    }
    let obsoleteDirectories = Set(old?.createdDirectories ?? [])
      .subtracting(new?.createdDirectories ?? [])
    try removeCreatedDirectories(Array(obsoleteDirectories))
  }

  private func restoreReleasedThemeBridges(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?
  ) throws {
    let retainedPaths = Set(new?.originalThemeBridges.map(\.path) ?? [])
    try EnvironmentThemeBridgeState(
      entries: old?.originalThemeBridges.filter { !retainedPaths.contains($0.path) } ?? []
    ).restore()
  }

  private func restoreRollbackThemeBridges(_ transaction: EnvironmentTransaction) throws {
    if let previousThemeGenerationID = transaction.previousThemeGenerationID {
      let active = try ReconciliationStatusStore(root: stateRoot).activeManifest()
      guard active.generationID == previousThemeGenerationID else { return }
    }
    try EnvironmentThemeBridgeState(entries: transaction.rollbackThemeBridges).restore()
  }

  private func validate(_ ownership: EnvironmentOwnership?) throws {
    guard let ownership else { return }
    guard ownership.hasValidShape else {
      throw EnvironmentLifecycleError.blocked("environment ownership has an invalid structure")
    }
    let allowed = Dictionary(
      uniqueKeysWithValues: inspector.allManagedEntries(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).map { ($0.id, $0) }
    )
    for record in ownership.records {
      guard let entry = allowed[record.id],
        record.publicPath == entry.url.path,
        record.managedKind == entry.kind.rawValue,
        record.managedTarget == entry.target
      else {
        throw EnvironmentLifecycleError.blocked(
          "ownership for \(record.id.rawValue) contains an unexpected provider path or target"
        )
      }
      if let retained = record.retainedPath {
        let retainedURL = URL(filePath: retained).standardizedFileURL
        let expectedPrefix = ".macarchy-environment-\(record.id.rawValue)-"
        guard retainedURL.deletingLastPathComponent() == entry.url.deletingLastPathComponent(),
          retainedURL.lastPathComponent.hasPrefix(expectedPrefix),
          retainedURL.lastPathComponent.hasSuffix(".retained")
        else {
          throw EnvironmentLifecycleError.blocked(
            "ownership for \(record.id.rawValue) contains an unexpected retained path"
          )
        }
      }
    }
    let allowedDirectories = Set(
      allowed.values.map { $0.url.deletingLastPathComponent().path }
        + allowed.values.flatMap { entry -> [String] in
          var paths = [String]()
          var parent = entry.url.deletingLastPathComponent()
          while parent.path != homeDirectory.path, parent.path.hasPrefix(homeDirectory.path + "/") {
            paths.append(parent.path)
            parent.deleteLastPathComponent()
          }
          return paths
        }
    )
    guard Set(ownership.createdDirectories).isSubset(of: allowedDirectories) else {
      throw EnvironmentLifecycleError.blocked("ownership contains an unexpected created directory")
    }
    guard
      EnvironmentThemeBridgeState.pathsAreValid(
        ownership.originalThemeBridges,
        stateRoot: stateRoot
      )
    else {
      throw EnvironmentLifecycleError.blocked("ownership contains an unexpected theme bridge")
    }
  }

  private func preflight(_ ownership: EnvironmentOwnership) throws {
    for record in ownership.records {
      let entry = inspector.managedEntry(from: record)
      guard try inspector.managedEntryIsExact(entry) else {
        throw EnvironmentLifecycleError.drift(entry.url.path)
      }
      if let retained = record.retainedPath {
        guard
          try evidence(
            at: URL(filePath: retained),
            matches: record.original,
            kittyDirectory: record.id == .kitty
          )
        else {
          throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
        }
      }
    }
  }

  private func install(_ record: EnvironmentOwnershipRecord) throws {
    let entry = inspector.managedEntry(from: record)
    if try inspector.managedEntryIsExact(entry) { return }
    if let retained = record.retainedPath {
      let retainedURL = URL(filePath: retained)
      if try itemExists(retainedURL) {
        guard
          try evidence(
            at: retainedURL,
            matches: record.original,
            kittyDirectory: record.id == .kitty
          ),
          !(try itemExists(entry.url))
        else { throw EnvironmentLifecycleError.drift(entry.url.path) }
      } else {
        guard
          try evidence(
            at: entry.url,
            matches: record.original,
            kittyDirectory: record.id == .kitty
          )
        else {
          throw EnvironmentLifecycleError.drift(entry.url.path)
        }
        try retainOriginal(record)
      }
    } else if try itemExists(entry.url) {
      throw EnvironmentLifecycleError.drift(entry.url.path)
    }
    try publishManaged(entry)
  }

  private func restore(_ record: EnvironmentOwnershipRecord) throws {
    let entry = inspector.managedEntry(from: record)
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: entry.url.deletingLastPathComponent())
    } catch let error as PinnedFilesystemError
      where error.code == ENOENT && record.original.kind == .absent
    {
      return
    }
    defer { Darwin.close(parent) }
    let managedExact = try inspector.managedEntryIsExact(entry, parentDescriptor: parent)
    let emptyKittyResidue =
      try entry.kind == .kittyDirectory
      && kittyDirectoryIsEmpty(entry, parentDescriptor: parent)
    if !managedExact, !emptyKittyResidue {
      let publicEvidence = try inspector.capturePinned(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url,
        kittyDirectory: record.id == .kitty
      )
      if publicEvidence == record.original {
        return
      }
      guard publicEvidence.kind == .absent, let retainedPath = record.retainedPath else {
        throw EnvironmentLifecycleError.drift(entry.url.path)
      }
      let retainedURL = URL(filePath: retainedPath)
      let retainedEvidence = try inspector.capturePinned(
        parentDescriptor: parent,
        name: retainedURL.lastPathComponent,
        url: retainedURL,
        kittyDirectory: record.id == .kitty
      )
      guard retainedEvidence == record.original else {
        throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
      }
    }
    if entry.kind == .kittyDirectory, managedExact {
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let removedConfiguration = "kitty.conf".withCString {
        Darwin.unlinkat(directory, $0, 0)
      }
      guard removedConfiguration == 0, fsync(directory) == 0 else {
        throw EnvironmentLifecycleError.system(
          "remove managed Kitty configuration bridge",
          entry.url.appending(path: "kitty.conf"),
          errno
        )
      }
    }
    let removed = entry.url.lastPathComponent.withCString {
      Darwin.unlinkat(parent, $0, entry.kind == .kittyDirectory ? AT_REMOVEDIR : 0)
    }
    guard removed == 0 else {
      throw EnvironmentLifecycleError.system("remove managed provider entry", entry.url, errno)
    }
    if let retained = record.retainedPath {
      let retainedURL = URL(filePath: retained)
      let retainedName = retainedURL.lastPathComponent
      let retainedEvidence = try inspector.capturePinned(
        parentDescriptor: parent,
        name: retainedName,
        url: retainedURL,
        kittyDirectory: record.id == .kitty
      )
      guard retainedEvidence == record.original else {
        throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
      }
      let restored = retainedName.withCString { source in
        entry.url.lastPathComponent.withCString { destination in
          Darwin.renameat(parent, source, parent, destination)
        }
      }
      guard restored == 0 else {
        throw EnvironmentLifecycleError.system("restore provider entry", entry.url, errno)
      }
    }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url,
        kittyDirectory: record.id == .kitty
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift("restored \(entry.url.path)")
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync restored provider entry", entry.url, errno)
    }
  }

  private func retainOriginal(_ record: EnvironmentOwnershipRecord) throws {
    guard let retainedPath = record.retainedPath else { return }
    let publicURL = URL(filePath: record.publicPath)
    let retained = URL(filePath: retainedPath)
    let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: publicURL.lastPathComponent,
        url: publicURL,
        kittyDirectory: record.id == .kitty
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let retainedExists: Bool
    do {
      _ = try PinnedFilesystem.metadata(
        parentDescriptor: parent,
        name: retained.lastPathComponent,
        url: retained
      )
      retainedExists = true
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      retainedExists = false
    }
    guard !retainedExists else {
      throw EnvironmentLifecycleError.blocked("retained path already exists: \(retained.path)")
    }
    let retainedResult = publicURL.lastPathComponent.withCString { source in
      retained.lastPathComponent.withCString { destination in
        Darwin.renameat(parent, source, parent, destination)
      }
    }
    guard retainedResult == 0 else {
      throw EnvironmentLifecycleError.system("retain provider entry", publicURL, errno)
    }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: retained.lastPathComponent,
        url: retained,
        kittyDirectory: record.id == .kitty
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync retained provider entry", publicURL, errno)
    }
  }

  private func kittyDirectoryIsEmpty(
    _ entry: EnvironmentManagedEntry,
    parentDescriptor: Int32
  ) throws -> Bool {
    guard entry.kind == .kittyDirectory else { return false }
    do {
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let contents = try PinnedFilesystem.directoryEntries(
        descriptor: directory,
        url: entry.url,
        limit: 1
      )
      return !contents.truncated && contents.entries.isEmpty
    } catch let error as PinnedFilesystemError
      where error.code == ENOENT || error.code == ENOTDIR
    {
      return false
    }
  }

  private func publishManaged(_ entry: EnvironmentManagedEntry) throws {
    try ensureSafeParent(of: entry.url)
    let parent = entry.url.deletingLastPathComponent()
    let parentDescriptor = try PinnedFilesystem.openDirectory(at: parent)
    defer { Darwin.close(parentDescriptor) }
    let temporaryName = ".macarchy-environment-\(UUID().uuidString.lowercased())"
    let temporary = parent.appending(path: temporaryName)
    switch entry.kind {
    case .symbolicLink:
      let created = entry.target.withCString { target in
        temporaryName.withCString { name in
          Darwin.symlinkat(target, parentDescriptor, name)
        }
      }
      guard created == 0 else {
        throw EnvironmentLifecycleError.system("create provider bridge", temporary, errno)
      }
    case .kittyDirectory:
      let directory = try PinnedFilesystem.createDirectory(
        parentDescriptor: parentDescriptor,
        name: temporaryName,
        url: temporary
      )
      defer { Darwin.close(directory) }
      let configuration = temporary.appending(path: "kitty.conf")
      let created = entry.target.withCString { target in
        Darwin.symlinkat(target, directory, "kitty.conf")
      }
      guard created == 0 else {
        throw EnvironmentLifecycleError.system(
          "create Kitty configuration bridge", configuration, errno)
      }
    }
    defer {
      switch entry.kind {
      case .symbolicLink:
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
      case .kittyDirectory:
        if let directory = try? PinnedFilesystem.openDirectory(
          parentDescriptor: parentDescriptor,
          name: temporaryName,
          url: temporary
        ) {
          "kitty.conf".withCString { _ = Darwin.unlinkat(directory, $0, 0) }
          Darwin.close(directory)
        }
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
      }
    }
    let published = temporaryName.withCString { source in
      entry.url.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(
          parentDescriptor,
          source,
          parentDescriptor,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard published == 0 else {
      throw EnvironmentLifecycleError.system("publish provider bridge", entry.url, errno)
    }
    guard try inspector.managedEntryIsExact(entry, parentDescriptor: parentDescriptor),
      fsync(parentDescriptor) == 0
    else {
      throw EnvironmentLifecycleError.drift(entry.url.path)
    }
  }

  private func evidence(
    at url: URL,
    matches expected: EnvironmentEntryEvidence,
    kittyDirectory: Bool
  ) throws -> Bool {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    return try inspector.capturePinned(
      parentDescriptor: parent,
      name: url.lastPathComponent,
      url: url,
      kittyDirectory: kittyDirectory
    ) == expected
  }

  private func ensureSafeParent(of url: URL) throws {
    let home = homeDirectory.standardizedFileURL
    let parent = url.deletingLastPathComponent().standardizedFileURL
    guard parent.path == home.path || parent.path.hasPrefix(home.path + "/") else {
      throw EnvironmentLifecycleError.blocked("provider entry is outside the selected home")
    }
    var descriptor = try PinnedFilesystem.openDirectory(at: home)
    defer { Darwin.close(descriptor) }
    var current = home
    if parent.path != home.path {
      let relative = parent.path.dropFirst(home.path.count + 1).split(separator: "/")
      for component in relative {
        current.append(path: String(component), directoryHint: .isDirectory)
        let next: Int32
        do {
          next = try PinnedFilesystem.openDirectory(
            parentDescriptor: descriptor,
            name: String(component),
            url: current
          )
        } catch let error as PinnedFilesystemError where error.code == ENOENT {
          next = try PinnedFilesystem.createDirectory(
            parentDescriptor: descriptor,
            name: String(component),
            url: current
          )
        }
        Darwin.close(descriptor)
        descriptor = next
      }
    }
  }

  private func retainedURL(for entry: EnvironmentManagedEntry) -> URL {
    entry.url.deletingLastPathComponent().appending(
      path: ".macarchy-environment-\(entry.id.rawValue)-\(UUID().uuidString.lowercased()).retained"
    )
  }

  private func itemExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    if errno == ENOENT { return false }
    throw EnvironmentLifecycleError.system("inspect path", url, errno)
  }

  private func removeCreatedDirectories(_ paths: [String]) throws {
    for path in paths.sorted(by: { $0.count > $1.count }) {
      let url = URL(filePath: path)
      let home = homeDirectory.standardizedFileURL
      guard url.path.hasPrefix(home.path + "/") else {
        throw EnvironmentLifecycleError.blocked(
          "created provider directory is outside the selected home")
      }
      let parent: Int32
      do {
        parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        continue
      }
      defer { Darwin.close(parent) }
      let removed = url.lastPathComponent.withCString {
        Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
      }
      guard removed == 0 || errno == ENOENT || errno == ENOTEMPTY else {
        throw EnvironmentLifecycleError.system("remove created provider directory", url, errno)
      }
      if removed == 0, fsync(parent) != 0 {
        throw EnvironmentLifecycleError.system("sync removed provider directory", url, errno)
      }
    }
  }
}
