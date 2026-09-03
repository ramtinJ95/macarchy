import Darwin
import Dispatch
import Foundation
import TOMLDecoder
import ThemeCore

enum EnvironmentEntryID: String, Codable, CaseIterable, Sendable {
  case kitty
  case zsh
  case starship
  case atuinConfiguration = "atuin_configuration"
  case atuinTheme = "atuin_theme"
  case batConfiguration = "bat_configuration"
  case batTheme = "bat_theme"
  case btopConfiguration = "btop_configuration"
  case btopTheme = "btop_theme"
  case ezaTheme = "eza_theme"
  case tuicrConfiguration = "tuicr_configuration"
  case tuicrTheme = "tuicr_theme"
  case tuicrSyntax = "tuicr_syntax"
  case yaziConfiguration = "yazi_configuration"
  case yaziThemeSelection = "yazi_theme_selection"
  case yaziFlavor = "yazi_flavor"
  case yaziSyntax = "yazi_syntax"
  case neovim

  var directoryLinkKind: EnvironmentDirectoryLinkKind? {
    switch self {
    case .kitty: .kitty
    case .neovim: .neovim
    default: nil
    }
  }
}

enum EnvironmentDirectoryLinkKind: String, Sendable {
  case kitty = "Kitty"
  case neovim = "Neovim"

  var maximumEntries: Int {
    switch self {
    case .kitty: 128
    case .neovim: 512
    }
  }

  var maximumBytes: Int {
    switch self {
    case .kitty: 4 * 1_048_576
    case .neovim: 8 * 1_048_576
    }
  }
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
  let btop: EnvironmentBtopOwnership?
  let tuicr: EnvironmentTuicrOwnership?
  let tuicrEnabled: Bool
  let enabledThemeAdapterIDs: [String]?

  init(
    generationID: String,
    records: [EnvironmentOwnershipRecord],
    createdDirectories: [String],
    originalThemeBridges: [EnvironmentThemeBridgeState.Entry],
    btop: EnvironmentBtopOwnership? = nil,
    tuicr: EnvironmentTuicrOwnership? = nil,
    tuicrEnabled: Bool = false,
    enabledThemeAdapterIDs: [String]? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.records = records.sorted { $0.id.rawValue < $1.id.rawValue }
    self.createdDirectories = createdDirectories.sorted()
    self.originalThemeBridges = originalThemeBridges.sorted { $0.path < $1.path }
    self.btop = btop
    self.tuicr = tuicr
    self.tuicrEnabled = tuicrEnabled
    self.enabledThemeAdapterIDs = enabledThemeAdapterIDs?.sorted()
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case records
    case createdDirectories = "created_directories"
    case originalThemeBridges = "original_theme_bridges"
    case btop
    case tuicr
    case tuicrEnabled = "tuicr_enabled"
    case enabledThemeAdapterIDs = "enabled_theme_adapter_ids"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    generationID = try container.decode(String.self, forKey: .generationID)
    records = try container.decode([EnvironmentOwnershipRecord].self, forKey: .records)
    createdDirectories = try container.decode([String].self, forKey: .createdDirectories)
    originalThemeBridges = try container.decode(
      [EnvironmentThemeBridgeState.Entry].self,
      forKey: .originalThemeBridges
    )
    btop = try container.decodeIfPresent(EnvironmentBtopOwnership.self, forKey: .btop)
    tuicr = try container.decodeIfPresent(EnvironmentTuicrOwnership.self, forKey: .tuicr)
    tuicrEnabled = try container.decodeIfPresent(Bool.self, forKey: .tuicrEnabled) ?? false
    enabledThemeAdapterIDs = try container.decodeIfPresent(
      [String].self,
      forKey: .enabledThemeAdapterIDs
    )
  }

  var hasValidShape: Bool {
    let knownThemeAdapterIDs = Set(ThemeActivationCoordinator.adapterRequirements.keys)
    let hasValidThemeAdapterInventory =
      enabledThemeAdapterIDs.map { adapterIDs in
        adapterIDs == adapterIDs.sorted()
          && Set(adapterIDs).count == adapterIDs.count
          && Set(adapterIDs).isSubset(of: knownThemeAdapterIDs)
          && adapterIDs.contains(TuicrAdapter.id) == tuicrEnabled
      } ?? true
    guard schemaVersion == Self.currentSchemaVersion,
      EnvironmentGenerationStore.isGenerationID(generationID),
      Set(records.map(\.id)).count == records.count,
      Set(createdDirectories).count == createdDirectories.count,
      Set(originalThemeBridges.map(\.path)).count == originalThemeBridges.count,
      btop?.hasValidShape ?? true,
      tuicr?.hasValidShape ?? true,
      hasValidThemeAdapterInventory
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
        return record.id != .kitty && record.id != .neovim
          && record.retainedPath != nil && hasIdentity
          && evidence.linkDestination == nil && evidence.contentDigest != nil
          && evidence.inventory.isEmpty
      case .symbolicLink:
        return record.retainedPath != nil && hasIdentity
          && evidence.linkDestination != nil && evidence.contentDigest == nil
          && ([.kitty, .neovim].contains(record.id) || evidence.inventory.isEmpty)
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
  let btopReplacementName: String?
  let tuicrReplacementName: String?

  init(
    operation: EnvironmentTransactionOperation,
    direction: EnvironmentTransactionDirection = .forward,
    previousOwnership: EnvironmentOwnership?,
    proposedOwnership: EnvironmentOwnership?,
    previousCurrentDestination: String?,
    previousThemeGenerationID: String? = nil,
    rollbackThemeBridges: [EnvironmentThemeBridgeState.Entry] = [],
    btopReplacementName: String? = nil,
    tuicrReplacementName: String? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.operation = operation
    self.direction = direction
    self.previousOwnership = previousOwnership
    self.proposedOwnership = proposedOwnership
    self.previousCurrentDestination = previousCurrentDestination
    self.previousThemeGenerationID = previousThemeGenerationID
    self.rollbackThemeBridges = rollbackThemeBridges
    self.btopReplacementName = btopReplacementName
    self.tuicrReplacementName = tuicrReplacementName
  }

  var rollingBack: Self {
    Self(
      operation: operation,
      direction: .rollback,
      previousOwnership: previousOwnership,
      proposedOwnership: proposedOwnership,
      previousCurrentDestination: previousCurrentDestination,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: rollbackThemeBridges,
      btopReplacementName: btopReplacementName,
      tuicrReplacementName: tuicrReplacementName
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
    case btopReplacementName = "btop_replacement_name"
    case tuicrReplacementName = "tuicr_replacement_name"
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
  let proposedBtopOwnership: EnvironmentBtopOwnership?
  let btopExternalEvidence: EnvironmentEntryEvidence?
  let proposedTuicrOwnership: EnvironmentTuicrOwnership?
  let tuicrExternalEvidence: EnvironmentEntryEvidence?

  var isBlocked: Bool {
    blockedMessage != nil
      || entries.contains { $0.status == "drifted" || $0.status == "unsupported" }
  }
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
        && Self.btopReplacementIsValid(value)
        && Self.tuicrReplacementIsValid(value)
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

  private static func btopReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.btop != nil
      || transaction.proposedOwnership?.btop != nil
    guard required else { return transaction.btopReplacementName == nil }
    guard let name = transaction.btopReplacementName else { return false }
    return name.hasPrefix(".macarchy-environment-btop-")
      && name.hasSuffix(".replacement")
      && !name.contains("/")
      && name.utf8.count <= 128
  }

  private static func tuicrReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.tuicr != nil
      || transaction.proposedOwnership?.tuicr != nil
    guard required else { return transaction.tuicrReplacementName == nil }
    guard let name = transaction.tuicrReplacementName else { return false }
    return name.hasPrefix(".macarchy-environment-tuicr-")
      && name.hasSuffix(".replacement")
      && !name.contains("/")
      && name.utf8.count <= 128
  }
}

struct EnvironmentProviderInspector: Sendable {
  private static let maximumExternalFileSize = 4 * 1_048_576

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
      if entries.contains(where: { $0.id == .neovim }) {
        legacyIDs.insert("neovim.theme-link")
      }
      if composition.profile.tools.bat {
        legacyIDs.formUnion(["bat.selector", "bat.theme-link"])
      }
      if composition.profile.tools.eza {
        legacyIDs.formUnion(["eza.environment", "eza.theme-link"])
      }
      if composition.profile.tools.btop {
        legacyIDs.formUnion(["btop.selector", "btop.theme-link"])
      }
      if composition.profile.tools.yazi {
        legacyIDs.formUnion(["yazi.selector", "yazi.flavor-link", "yazi.syntax-link"])
      }
      let setupRecords = try SetupOwnershipManager().readRecords(context: setupContext)
      let legacyTuicrIDs = Set([
        SetupOwnershipManager.tuicrSelectorID,
        SetupOwnershipManager.tuicrThemeLinkID,
        SetupOwnershipManager.tuicrSyntaxLinkID,
      ])
      let presentLegacyTuicrIDs = Set(setupRecords.map(\.id)).intersection(legacyTuicrIDs)
      guard presentLegacyTuicrIDs.isEmpty || presentLegacyTuicrIDs == legacyTuicrIDs else {
        throw EnvironmentLifecycleError.blocked(
          "legacy setup-owned tuicr integration is incomplete: \(presentLegacyTuicrIDs.sorted().joined(separator: ", "))"
        )
      }
      let legacyTuicrOwned = presentLegacyTuicrIDs == legacyTuicrIDs
      let externallyAuthoritativeTuicr =
        ownership?.tuicrEnabled == true
        && ownership?.tuicr == nil
        && ownership?.records.contains(where: {
          $0.id == .tuicrTheme || $0.id == .tuicrSyntax
        }) != true
        && !legacyTuicrOwned
      let conflicts =
        setupRecords
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
        let captured =
          owned[entry.id] == nil
          ? try capture(
            entry.url,
            directoryLink: entry.id.directoryLinkKind
          ) : nil
        if let captured,
          entry.id != .atuinTheme || hasExternalAncestor,
          try externalEntryIsExact(entry, evidence: captured, composition: composition)
        {
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: "external",
              ownership: "external_exact",
              message: "The exact provider seam remains externally owned.",
              evidence: captured
            )
          )
          continue
        }
        if hasExternalAncestor {
          if Self.isDailyToolEntry(entry.id) {
            inspections.append(
              EnvironmentEntryInspection(
                id: entry.id.rawValue,
                path: entry.url.path,
                status: "unsupported",
                ownership: "external",
                message: "The provider entry is below a symlink-owned parent.",
                evidence: captured
              )
            )
            continue
          }
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

        guard let captured else {
          throw EnvironmentLifecycleError.blocked(
            "provider inspection lost external evidence for \(entry.id.rawValue)"
          )
        }
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

      if composition.profile.tools.eza, composition.profile.shell == .disabled {
        inspections.append(
          try inspectExternalEzaEnvironment(
            homeDirectory: homeDirectory,
            configurationDirectory: homeDirectory.appending(path: ".config/eza")
          )
        )
      }

      let btop = try inspectBtop(
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.btop,
        ownershipGenerationID: ownership?.generationID
      )
      if let entry = btop.entry { inspections.append(entry) }
      if btop.proposedOwnership != nil {
        for directory in try missingParentDirectories(
          of: homeDirectory.appending(path: ".config/btop/btop.conf"),
          homeDirectory: homeDirectory
        ) {
          createdDirectories.insert(directory.path)
        }
      }

      let tuicr = try inspectTuicr(
        composition: composition,
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        ownership: ownership?.tuicr,
        legacyOwned: legacyTuicrOwned,
        externallyAuthoritative: externallyAuthoritativeTuicr
      )
      if let entry = tuicr.entry { inspections.append(entry) }
      if legacyTuicrOwned {
        for entry in allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
        where entry.id == .tuicrTheme || entry.id == .tuicrSyntax {
          guard try managedEntryIsExact(entry) else {
            throw EnvironmentLifecycleError.drift(
              "legacy setup-owned \(entry.id.rawValue)"
            )
          }
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: "external",
              ownership: "legacy_setup",
              message: "The working legacy setup-owned tuicr link is preserved.",
              evidence: nil
            )
          )
        }
      }
      if externallyAuthoritativeTuicr, !composition.profile.presets.tuicr {
        for entry in allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
        where entry.id == .tuicrTheme || entry.id == .tuicrSyntax {
          let captured = try capture(entry.url, directoryLink: nil)
          guard try externalEntryIsExact(entry, evidence: captured, composition: composition) else {
            throw EnvironmentLifecycleError.drift(
              "externally owned \(entry.id.rawValue)"
            )
          }
          inspections.append(
            EnvironmentEntryInspection(
              id: entry.id.rawValue,
              path: entry.url.path,
              status: "external",
              ownership: "external_exact",
              message: "The exact tuicr tuple remains externally owned until disablement.",
              evidence: captured
            )
          )
        }
      }
      if tuicr.proposedOwnership != nil {
        for directory in try missingParentDirectories(
          of: homeDirectory.appending(path: ".config/tuicr/config.toml"),
          homeDirectory: homeDirectory
        ) { createdDirectories.insert(directory.path) }
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
            selected: entries,
            btop: btop.proposedOwnership,
            tuicr: tuicr.proposedOwnership
          ) : nil,
        blockedMessage: nil,
        desiredEntries: entries,
        externalEvidence: evidence,
        createdDirectories: createdDirectories.sorted(),
        proposedBtopOwnership: btop.proposedOwnership,
        btopExternalEvidence: btop.externalEvidence,
        proposedTuicrOwnership: tuicr.proposedOwnership,
        tuicrExternalEvidence: tuicr.externalEvidence
      )
    } catch {
      return EnvironmentProviderInspection(
        entries: [],
        ownership: nil,
        adoptionEvidenceDigest: nil,
        blockedMessage: String(describing: error),
        desiredEntries: [],
        externalEvidence: [:],
        createdDirectories: [],
        proposedBtopOwnership: nil,
        btopExternalEvidence: nil,
        proposedTuicrOwnership: nil,
        tuicrExternalEvidence: nil
      )
    }
  }

  func desiredEntries(
    profile: EnvironmentProfile,
    homeDirectory: URL,
    stateRoot: URL
  ) -> [EnvironmentManagedEntry] {
    var enabled = Set<EnvironmentEntryID>()
    if profile.terminal == .kitty { enabled.insert(.kitty) }
    if profile.shell == .zsh { enabled.insert(.zsh) }
    if profile.prompt == .starship { enabled.insert(.starship) }
    if profile.history == .atuin {
      enabled.formUnion([.atuinConfiguration, .atuinTheme])
    }
    if profile.editor == .neovim { enabled.insert(.neovim) }
    if profile.tools.bat { enabled.formUnion([.batConfiguration, .batTheme]) }
    if profile.tools.eza { enabled.insert(.ezaTheme) }
    if profile.tools.btop { enabled.insert(.btopTheme) }
    if profile.tools.yazi {
      enabled.formUnion([.yaziConfiguration, .yaziThemeSelection, .yaziFlavor, .yaziSyntax])
    }
    if profile.presets.tuicr { enabled.formUnion([.tuicrTheme, .tuicrSyntax]) }
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
        id: .neovim,
        url: home.appending(path: ".config/nvim", directoryHint: .isDirectory),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/neovim").path
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
      EnvironmentManagedEntry(
        id: .batConfiguration,
        url: home.appending(path: ".config/bat/config"),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/bat/config").path
      ),
      EnvironmentManagedEntry(
        id: .batTheme,
        url: home.appending(path: ".config/bat/themes/\(BatAdapter.themeFileName)"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(TextMateThemeArtifact.outputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .ezaTheme,
        url: home.appending(path: ".config/eza/\(EzaAdapter.themeFileName)"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(EzaAdapter.outputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .btopTheme,
        url: home.appending(path: ".config/btop/themes/\(BtopAdapter.themeFileName)"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(BtopAdapter.outputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .tuicrTheme,
        url: home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).toml"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(TuicrAdapter.outputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .tuicrSyntax,
        url: home.appending(path: ".config/tuicr/themes/\(TuicrAdapter.themeName).tmTheme"),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(TextMateThemeArtifact.outputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .yaziConfiguration,
        url: home.appending(path: ".config/yazi/yazi.toml"),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/yazi/yazi.toml").path
      ),
      EnvironmentManagedEntry(
        id: .yaziThemeSelection,
        url: home.appending(path: ".config/yazi/theme.toml"),
        kind: .symbolicLink,
        target: state.appending(path: "environment/current/yazi/theme.toml").path
      ),
      EnvironmentManagedEntry(
        id: .yaziFlavor,
        url: home.appending(
          path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/flavor.toml"
        ),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(YaziAdapter.flavorOutputPath)").path
      ),
      EnvironmentManagedEntry(
        id: .yaziSyntax,
        url: home.appending(
          path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/tmtheme.xml"
        ),
        kind: .symbolicLink,
        target: state.appending(path: "current/\(TextMateThemeArtifact.yaziOutputPath)").path
      ),
    ]
  }

  func capture(
    _ url: URL,
    directoryLink: EnvironmentDirectoryLinkKind?
  ) throws -> EnvironmentEntryEvidence {
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
        inventory: try directoryLink.map {
          try nativeDirectoryInventory(link: url, destination: destination, kind: $0)
        } ?? []
      )
    case S_IFREG where directoryLink == nil:
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
    directoryLink: EnvironmentDirectoryLinkKind?
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
        inventory: try directoryLink.map {
          try nativeDirectoryInventory(link: url, destination: destination, kind: $0)
        } ?? []
      )
    case S_IFREG where directoryLink == nil:
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
    selected: [EnvironmentManagedEntry],
    btop: EnvironmentBtopOwnership?,
    tuicr: EnvironmentTuicrOwnership?
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
    var targets = Dictionary(uniqueKeysWithValues: selected.map { ($0.id.rawValue, $0.target) })
    if let btop {
      targets[EnvironmentEntryID.btopConfiguration.rawValue] = "provider-writable:\(btop.path)"
    }
    if let tuicr {
      targets[EnvironmentEntryID.tuicrConfiguration.rawValue] = "key-owned:\(tuicr.path)"
    }
    let payload = Payload(
      schemaVersion: 1,
      inputDigest: composition.inputDigest,
      renderedDigest: composition.renderedDigest,
      providers: [
        composition.profile.terminal.rawValue,
        composition.profile.shell.rawValue,
        composition.profile.prompt.rawValue,
        composition.profile.history.rawValue,
        composition.profile.editor.rawValue,
        composition.profile.tools.bat ? "bat" : "bat-disabled",
        composition.profile.tools.eza ? "eza" : "eza-disabled",
        composition.profile.tools.btop ? "btop" : "btop-disabled",
        composition.profile.tools.yazi ? "yazi" : "yazi-disabled",
        composition.profile.presets.tuicr ? "tuicr" : "tuicr-disabled",
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

  private func externalEntryIsExact(
    _ entry: EnvironmentManagedEntry,
    evidence: EnvironmentEntryEvidence,
    composition: EnvironmentComposition
  ) throws -> Bool {
    switch entry.id {
    case .atuinTheme, .batTheme, .btopTheme, .ezaTheme, .tuicrTheme, .tuicrSyntax,
      .yaziFlavor, .yaziSyntax:
      return evidence.kind == .symbolicLink && evidence.linkDestination == entry.target
    case .batConfiguration:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      let directives = text.split(whereSeparator: \Character.isNewline).filter {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("--theme=") || line.hasPrefix("--theme ")
      }
      return directives.map { $0.trimmingCharacters(in: .whitespaces) }
        == [BatAdapter.themeDirective]
    case .yaziConfiguration:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      try validateTOML(text, source: entry.url)
      return CanonicalTOMLSelector(
        configuration: text,
        table: "mgr",
        key: "show_hidden"
      ).selectsExactly(String(composition.profile.yazi.showHidden ?? true))
    case .yaziThemeSelection:
      guard evidence.kind == .regularFile else { return false }
      let text = try configurationText(at: entry.url, evidence: evidence)
      try validateTOML(text, source: entry.url)
      return CanonicalTOMLSelector(
        configuration: text,
        table: YaziAdapter.selectionTable,
        key: YaziAdapter.selectionKey
      ).selectsExactly("\"\(YaziAdapter.flavorName)\"")
    default:
      return false
    }
  }

  private static func isDailyToolEntry(_ id: EnvironmentEntryID) -> Bool {
    switch id {
    case .batConfiguration, .batTheme, .btopConfiguration, .btopTheme, .ezaTheme,
      .tuicrConfiguration, .tuicrTheme, .tuicrSyntax,
      .yaziConfiguration, .yaziThemeSelection, .yaziFlavor, .yaziSyntax:
      true
    case .kitty, .zsh, .starship, .atuinConfiguration, .atuinTheme, .neovim:
      false
    }
  }

  private func configurationText(
    at url: URL,
    evidence: EnvironmentEntryEvidence
  ) throws -> String {
    let data = try BoundedRegularFile.read(at: url).data
    guard sha256Digest(data) == evidence.contentDigest,
      let text = String(data: data, encoding: .utf8)
    else {
      throw EnvironmentLifecycleError.blocked(
        "provider configuration changed during inspection: \(url.path)"
      )
    }
    return text
  }

  private func validateTOML(_ text: String, source: URL) throws {
    do {
      _ = try TOMLTable(source: text)
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "invalid TOML configuration at \(source.path): \(error)"
      )
    }
  }

  private func inspectExternalEzaEnvironment(
    homeDirectory: URL,
    configurationDirectory: URL
  ) throws -> EnvironmentEntryInspection {
    let shell = homeDirectory.appending(path: ".zshrc")
    let evidence = try capture(shell, directoryLink: nil)
    let text: String
    switch evidence.kind {
    case .regularFile:
      text = try configurationText(at: shell, evidence: evidence)
    case .symbolicLink:
      let resolved = shell.resolvingSymlinksInPath()
      let data = try BoundedRegularFile.read(at: resolved).data
      guard let value = String(data: data, encoding: .utf8) else {
        throw EnvironmentLifecycleError.blocked("external zsh configuration is not UTF-8")
      }
      text = value
    case .absent:
      return EnvironmentEntryInspection(
        id: "eza_environment",
        path: shell.path,
        status: "unsupported",
        ownership: "external",
        message: "Eza requires an external EZA_CONFIG_DIR directive when zsh is disabled.",
        evidence: evidence
      )
    }
    let directives = [
      EzaAdapter.environmentDirective(configurationDirectoryURL: configurationDirectory),
      "export EZA_CONFIG_DIR=\"$HOME/.config/eza\"",
    ]
    let exact = directives.contains { directive in
      text.components(separatedBy: .newlines).contains {
        $0.trimmingCharacters(in: .whitespaces) == directive
      }
    }
    return EnvironmentEntryInspection(
      id: "eza_environment",
      path: shell.path,
      status: exact ? "external" : "unsupported",
      ownership: "external_exact",
      message: exact
        ? "The external shell selects the managed Eza configuration directory."
        : "Eza requires an exact external EZA_CONFIG_DIR directive when zsh is disabled.",
      evidence: evidence
    )
  }

  private func inspectBtop(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentBtopOwnership?,
    ownershipGenerationID: String?
  ) throws -> (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: EnvironmentBtopOwnership?,
    externalEvidence: EnvironmentEntryEvidence?
  ) {
    guard composition.profile.tools.btop || ownership != nil else { return (nil, nil, nil) }
    let url = homeDirectory.appending(path: ".config/btop/btop.conf")
    if let ownership {
      guard let ownershipGenerationID else {
        throw EnvironmentLifecycleError.blocked("btop ownership has no generation")
      }
      guard ownership.path == url.path,
        try !hasSymlinkAncestor(url, stoppingAt: homeDirectory)
      else {
        throw EnvironmentLifecycleError.blocked("btop ownership path is invalid")
      }
      let evidence = try capture(url, directoryLink: nil)
      let state = try EnvironmentBtopFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).generationState(ownershipGenerationID)
      let exact: Bool
      if evidence.kind == .regularFile {
        exact = try EnvironmentBtopDocument.matchesManaged(
          configurationText(at: url, evidence: evidence),
          values: state.values,
          source: url
        )
      } else {
        exact = false
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: exact
            ? (composition.profile.tools.btop ? "managed" : "restoration_required") : "drifted",
          ownership: "macarchy",
          message: exact
            ? (composition.profile.tools.btop
              ? "The owned btop keys are managed."
              : "The disabled btop keys will be restored.")
            : "The owned btop keys drifted.",
          evidence: nil
        ),
        composition.profile.tools.btop ? ownership : nil,
        nil
      )
    }

    guard composition.profile.tools.btop else { return (nil, nil, nil) }
    let artifactURL = stateRoot.appending(path: "environment/current/btop/btop.conf")
    guard let artifact = composition.artifacts.first(where: { $0.path == "btop/btop.conf" }) else {
      throw EnvironmentLifecycleError.blocked("missing rendered btop configuration")
    }
    guard let artifactText = artifact.textContents else {
      throw EnvironmentLifecycleError.blocked("rendered btop configuration is not UTF-8")
    }
    let desired = try EnvironmentBtopDocument.desiredValues(
      in: artifactText,
      source: artifactURL
    )
    let evidence = try capture(url, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    if evidence.kind == .regularFile {
      let text = try configurationText(at: url, evidence: evidence)
      if try EnvironmentBtopDocument.matchesManaged(text, values: desired, source: url) {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.btopConfiguration.rawValue,
            path: url.path,
            status: "external",
            ownership: "external_exact",
            message: "The exact btop keys remain externally owned.",
            evidence: evidence
          ), nil, nil
        )
      }
      if externalAncestor {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.btopConfiguration.rawValue,
            path: url.path,
            status: "unsupported",
            ownership: "external",
            message: "Divergent btop keys are below a symlink-owned provider directory.",
            evidence: evidence
          ), nil, nil
        )
      }
      let proposed = EnvironmentBtopOwnership(
        path: url.path,
        originalFileExisted: true,
        originalAssignments: try EnvironmentBtopDocument.originalAssignments(
          in: text,
          source: url
        )
      )
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: "adoption_required",
          ownership: "external",
          message: "The existing btop keys require reviewed adoption.",
          evidence: evidence
        ), proposed, evidence
      )
    }
    if evidence.kind == .absent, !externalAncestor {
      let proposed = EnvironmentBtopOwnership(
        path: url.path,
        originalFileExisted: false,
        originalAssignments: EnvironmentBtopDocument.ownedKeys.map {
          EnvironmentBtopOriginalAssignment(key: $0, line: nil)
        }
      )
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.btopConfiguration.rawValue,
          path: url.path,
          status: "install_required",
          ownership: "external",
          message: "The btop baseline will be installed.",
          evidence: evidence
        ), proposed, evidence
      )
    }
    return (
      EnvironmentEntryInspection(
        id: EnvironmentEntryID.btopConfiguration.rawValue,
        path: url.path,
        status: "unsupported",
        ownership: "external",
        message: "The btop configuration cannot be safely adopted.",
        evidence: evidence
      ), nil, nil
    )
  }

  private func inspectTuicr(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentTuicrOwnership?,
    legacyOwned: Bool,
    externallyAuthoritative: Bool
  ) throws -> (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: EnvironmentTuicrOwnership?,
    externalEvidence: EnvironmentEntryEvidence?
  ) {
    guard
      composition.profile.presets.tuicr || ownership != nil || legacyOwned
        || externallyAuthoritative
    else {
      return (nil, nil, nil)
    }
    let url = homeDirectory.appending(path: ".config/tuicr/config.toml")
    if legacyOwned {
      let evidence = try capture(url, directoryLink: nil)
      guard evidence.kind == .regularFile,
        try EnvironmentTuicrDocument.matchesManaged(
          configurationText(at: url, evidence: evidence),
          source: url
        )
      else {
        throw EnvironmentLifecycleError.drift("legacy setup-owned tuicr selector")
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: "external",
          ownership: "legacy_setup",
          message: "The working legacy setup-owned tuicr integration is preserved.",
          evidence: evidence
        ), nil, nil
      )
    }
    if let ownership {
      guard ownership.path == url.path,
        try !hasSymlinkAncestor(url, stoppingAt: homeDirectory)
      else { throw EnvironmentLifecycleError.blocked("tuicr ownership path is invalid") }
      let evidence = try capture(url, directoryLink: nil)
      let exact: Bool
      if evidence.kind == .regularFile {
        exact = try EnvironmentTuicrDocument.matchesManaged(
          configurationText(at: url, evidence: evidence), source: url)
      } else {
        exact = false
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: exact
            ? (composition.profile.presets.tuicr ? "managed" : "restoration_required")
            : "drifted",
          ownership: "macarchy",
          message: exact
            ? (composition.profile.presets.tuicr
              ? "The tuicr theme key is managed."
              : "The disabled tuicr theme key will be restored.")
            : "The owned tuicr theme key drifted.",
          evidence: nil
        ),
        composition.profile.presets.tuicr ? ownership : nil,
        nil
      )
    }
    if externallyAuthoritative {
      let evidence = try capture(url, directoryLink: nil)
      guard
        try tuicrExternalTupleIsExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot,
          configurationEvidence: evidence
        )
      else {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.tuicrConfiguration.rawValue,
            path: url.path,
            status: "drifted",
            ownership: "external_exact",
            message: "The externally owned tuicr tuple drifted.",
            evidence: evidence
          ), nil, nil
        )
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: "external",
          ownership: "external_exact",
          message: "The exact tuicr tuple remains externally owned until disablement.",
          evidence: evidence
        ), nil, nil
      )
    }
    guard composition.profile.presets.tuicr else { return (nil, nil, nil) }
    let evidence = try capture(url, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    let externalConfiguration = evidence.kind == .symbolicLink || externalAncestor
    if externalConfiguration {
      let text = try externalTuicrConfigurationText(
        at: url,
        evidence: evidence,
        hasExternalAncestor: externalAncestor
      )
      guard try EnvironmentTuicrDocument.matchesManaged(text, source: url) else {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.tuicrConfiguration.rawValue,
            path: url.path,
            status: "unsupported",
            ownership: "external",
            message: "A divergent tuicr selector is behind an externally owned symlink.",
            evidence: evidence
          ), nil, nil
        )
      }
      guard
        try tuicrLinksAreExternalExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        )
      else {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.tuicrConfiguration.rawValue,
            path: url.path,
            status: "unsupported",
            ownership: "external",
            message: "The externally owned tuicr selector requires both exact canonical links.",
            evidence: evidence
          ), nil, nil
        )
      }
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: "external",
          ownership: "external_exact",
          message: "The exact tuicr selector and canonical links remain externally owned.",
          evidence: evidence
        ), nil, evidence
      )
    }
    if evidence.kind == .regularFile {
      let text = try configurationText(at: url, evidence: evidence)
      if try EnvironmentTuicrDocument.matchesManaged(text, source: url) {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.tuicrConfiguration.rawValue,
            path: url.path,
            status: "external",
            ownership: "external_exact",
            message: "The exact tuicr theme key remains externally owned.",
            evidence: evidence
          ), nil, nil
        )
      }
      if externalAncestor {
        return (
          EnvironmentEntryInspection(
            id: EnvironmentEntryID.tuicrConfiguration.rawValue,
            path: url.path,
            status: "unsupported",
            ownership: "external",
            message: "A divergent tuicr selector is below a symlink-owned directory.",
            evidence: evidence
          ), nil, nil
        )
      }
      let proposed = try EnvironmentTuicrDocument.ownership(for: text, source: url)
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: "adoption_required",
          ownership: "external",
          message: "The existing tuicr theme key requires reviewed adoption.",
          evidence: evidence
        ),
        EnvironmentTuicrOwnership(
          path: url.path,
          originalFileExisted: true,
          originalSelector: proposed.originalSelector,
          insertedSeparatorBefore: proposed.insertedSeparatorBefore
        ), evidence
      )
    }
    if evidence.kind == .absent, !externalAncestor {
      return (
        EnvironmentEntryInspection(
          id: EnvironmentEntryID.tuicrConfiguration.rawValue,
          path: url.path,
          status: "install_required",
          ownership: "external",
          message: "The minimal tuicr theme selector will be installed.",
          evidence: evidence
        ),
        EnvironmentTuicrOwnership(
          path: url.path,
          originalFileExisted: false,
          originalSelector: nil,
          insertedSeparatorBefore: false
        ), evidence
      )
    }
    return (
      EnvironmentEntryInspection(
        id: EnvironmentEntryID.tuicrConfiguration.rawValue,
        path: url.path,
        status: "unsupported",
        ownership: "external",
        message: "The tuicr configuration cannot be safely adopted.",
        evidence: evidence
      ), nil, nil
    )
  }

  func tuicrExternalTupleIsExact(
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence? = nil
  ) throws -> Bool {
    let configuration = homeDirectory.appending(path: ".config/tuicr/config.toml")
    let evidence = try configurationEvidence ?? capture(configuration, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(configuration, stoppingAt: homeDirectory)
    guard evidence.kind == .regularFile || evidence.kind == .symbolicLink else { return false }
    let text =
      evidence.kind == .symbolicLink || externalAncestor
      ? try externalTuicrConfigurationText(
        at: configuration,
        evidence: evidence,
        hasExternalAncestor: externalAncestor
      )
      : try configurationText(at: configuration, evidence: evidence)
    return try EnvironmentTuicrDocument.matchesManaged(text, source: configuration)
      && tuicrLinksAreExternalExact(homeDirectory: homeDirectory, stateRoot: stateRoot)
  }

  private func tuicrLinksAreExternalExact(
    homeDirectory: URL,
    stateRoot: URL
  ) throws -> Bool {
    for entry in allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
    where entry.id == .tuicrTheme || entry.id == .tuicrSyntax {
      let evidence = try capture(entry.url, directoryLink: nil)
      guard evidence.kind == .symbolicLink, evidence.linkDestination == entry.target else {
        return false
      }
    }
    return true
  }

  private func externalTuicrConfigurationText(
    at url: URL,
    evidence: EnvironmentEntryEvidence,
    hasExternalAncestor: Bool
  ) throws -> String {
    guard evidence.kind == .symbolicLink || hasExternalAncestor else {
      return try configurationText(at: url, evidence: evidence)
    }
    let firstTarget = try resolvedTuicrTarget(url)
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: firstTarget).data
    } catch {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration symlink target is not a bounded regular file: \(error)"
      )
    }
    let secondTarget = try resolvedTuicrTarget(url)
    guard firstTarget == secondTarget,
      try capture(url, directoryLink: nil) == evidence
    else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration symlink chain changed during inspection"
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration symlink target is not UTF-8: \(firstTarget.path)"
      )
    }
    return text
  }

  private func resolvedTuicrTarget(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let resolved = url.path.withCString { Darwin.realpath($0, &buffer) }
    guard resolved != nil else {
      throw EnvironmentLifecycleError.system(
        "resolve tuicr configuration symlink chain", url, errno)
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let path = String(bytes: bytes, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked(
        "tuicr configuration symlink chain is not valid UTF-8"
      )
    }
    return URL(filePath: path).standardizedFileURL
  }

  private func nativeDirectoryInventory(
    link: URL,
    destination: String,
    kind: EnvironmentDirectoryLinkKind
  ) throws -> [String] {
    let root =
      destination.hasPrefix("/")
      ? URL(filePath: destination)
      : link.deletingLastPathComponent().appending(path: destination)
    var rootMetadata = stat()
    guard stat(root.path, &rootMetadata) == 0,
      rootMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      throw EnvironmentLifecycleError.blocked(
        "\(kind.rawValue) directory link target is not a directory"
      )
    }
    let inventoryRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard
      let enumerator = FileManager.default.enumerator(
        at: inventoryRoot,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      throw EnvironmentLifecycleError.blocked(
        "cannot inventory \(kind.rawValue) directory link target"
      )
    }
    var result = [String]()
    var bytes = 0
    let rootPath = inventoryRoot.path + "/"
    for case let item as URL in enumerator {
      guard result.count < kind.maximumEntries else {
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory inventory exceeds \(kind.maximumEntries) entries"
        )
      }
      var metadata = stat()
      guard lstat(item.path, &metadata) == 0 else {
        throw EnvironmentLifecycleError.system("inventory \(kind.rawValue) entry", item, errno)
      }
      let itemPath = item.standardizedFileURL.path
      guard itemPath.hasPrefix(rootPath) else {
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory inventory escaped its root"
        )
      }
      let relative = String(itemPath.dropFirst(rootPath.count))
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
        guard bytes <= kind.maximumBytes else {
          throw EnvironmentLifecycleError.blocked(
            "\(kind.rawValue) directory inventory exceeds \(kind.maximumBytes / 1_048_576) MiB"
          )
        }
        result.append("file:\(relative):\(sha256Digest(data))")
      default:
        throw EnvironmentLifecycleError.blocked(
          "\(kind.rawValue) directory contains an unsupported entry"
        )
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

enum EnvironmentTransactionCheckpoint: Equatable, Sendable {
  case authorityPublished
}

struct EnvironmentTransactionCoordinator: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  var faultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in }
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
        try transition(
          from: transaction.previousOwnership,
          to: proposed,
          btopReplacementName: transaction.btopReplacementName,
          tuicrReplacementName: transaction.tuicrReplacementName
        )
        try restoreReleasedThemeBridges(from: transaction.previousOwnership, to: proposed)
        try EnvironmentGenerationStore(stateRoot: stateRoot).select(proposed.generationID)
        try store.writeOwnership(proposed)
      case .teardown:
        try transition(
          from: transaction.previousOwnership,
          to: nil,
          btopReplacementName: transaction.btopReplacementName,
          tuicrReplacementName: transaction.tuicrReplacementName
        )
        try EnvironmentThemeBridgeState(
          entries: transaction.previousOwnership?.originalThemeBridges ?? []
        ).restore()
        try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
        try store.writeOwnership(nil)
      }
    case .rollback:
      try transition(
        from: transaction.proposedOwnership,
        to: transaction.previousOwnership,
        btopReplacementName: transaction.btopReplacementName,
        tuicrReplacementName: transaction.tuicrReplacementName
      )
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
      originalThemeBridges: originalThemeBridges,
      btop: inspection.proposedBtopOwnership,
      tuicr: inspection.proposedTuicrOwnership,
      tuicrEnabled: composition.profile.presets.tuicr,
      enabledThemeAdapterIDs: composition.profile.selectedThemeAdapterIDs
    )
    let generationChanged = previous?.generationID != proposed.generationID
    let ownershipChanged =
      previous?.records != proposed.records || previous?.btop != proposed.btop
      || previous?.tuicr != proposed.tuicr
      || previous?.tuicrEnabled != proposed.tuicrEnabled
      || previous?.enabledThemeAdapterIDs != proposed.enabledThemeAdapterIDs
    let changed = generationChanged || ownershipChanged

    // Re-capture every external entry after staging and before publishing the claim.
    for (id, expected) in inspection.externalEvidence {
      guard let entry = inspection.desiredEntries.first(where: { $0.id == id }),
        try inspector.capture(
          entry.url,
          directoryLink: entry.id.directoryLinkKind
        ) == expected
      else {
        throw EnvironmentLifecycleError.blocked(
          "provider entry changed after planning; run environment plan again"
        )
      }
    }
    if let expected = inspection.btopExternalEvidence {
      let url = homeDirectory.appending(path: ".config/btop/btop.conf")
      guard try inspector.capture(url, directoryLink: nil) == expected else {
        throw EnvironmentLifecycleError.blocked(
          "btop configuration changed after planning; run environment plan again"
        )
      }
    }
    if let expected = inspection.tuicrExternalEvidence {
      let url = homeDirectory.appending(path: ".config/tuicr/config.toml")
      guard try inspector.capture(url, directoryLink: nil) == expected else {
        throw EnvironmentLifecycleError.blocked(
          "tuicr configuration changed after planning; run environment plan again"
        )
      }
    }
    let btopReplacementName =
      previous?.btop != nil || proposed.btop != nil
      ? ".macarchy-environment-btop-\(UUID().uuidString.lowercased()).replacement" : nil
    let tuicrReplacementName =
      previous?.tuicr != nil || proposed.tuicr != nil
      ? ".macarchy-environment-tuicr-\(UUID().uuidString.lowercased()).replacement" : nil
    let transaction = EnvironmentTransaction(
      operation: .apply,
      previousOwnership: previous,
      proposedOwnership: proposed,
      previousCurrentDestination: previousCurrent,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: themeBridges.entries,
      btopReplacementName: btopReplacementName,
      tuicrReplacementName: tuicrReplacementName
    )
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    try store.writeTransaction(transaction)
    do {
      if changed {
        try generationStore.select(proposed.generationID)
        try transition(
          from: previous,
          to: proposed,
          btopReplacementName: btopReplacementName,
          tuicrReplacementName: tuicrReplacementName
        )
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
        try transition(
          from: proposed,
          to: previous,
          btopReplacementName: btopReplacementName,
          tuicrReplacementName: tuicrReplacementName
        )
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

  func finishApplyLocked(composition: EnvironmentComposition) throws {
    let inspection = inspector.inspect(
      composition: composition,
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    guard !inspection.isBlocked,
      inspection.entries.allSatisfy({ ["managed", "external"].contains($0.status) })
    else {
      throw EnvironmentLifecycleError.drift(
        inspection.blockedMessage ?? "provider verification failed before transaction completion"
      )
    }
    try faultInjector(.authorityPublished)
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
    try transition(
      from: rollback.proposedOwnership,
      to: rollback.previousOwnership,
      btopReplacementName: rollback.btopReplacementName,
      tuicrReplacementName: rollback.tuicrReplacementName
    )
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
      ).entries,
      btopReplacementName: ownership.btop.map { _ in
        ".macarchy-environment-btop-\(UUID().uuidString.lowercased()).replacement"
      },
      tuicrReplacementName: ownership.tuicr.map { _ in
        ".macarchy-environment-tuicr-\(UUID().uuidString.lowercased()).replacement"
      }
    )
    try store.writeTransaction(transaction)
    try transition(
      from: ownership,
      to: nil,
      btopReplacementName: transaction.btopReplacementName,
      tuicrReplacementName: transaction.tuicrReplacementName
    )
    try EnvironmentThemeBridgeState(entries: ownership.originalThemeBridges).restore()
    try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
    try store.writeOwnership(nil)
    try store.removeTransaction()
    return (true, "The exact adopted provider entries were restored.")
  }

  private func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    btopReplacementName: String?,
    tuicrReplacementName: String?
  ) throws {
    let oldByID = Dictionary(uniqueKeysWithValues: (old?.records ?? []).map { ($0.id, $0) })
    let newByID = Dictionary(uniqueKeysWithValues: (new?.records ?? []).map { ($0.id, $0) })
    let tuicrTransaction = EnvironmentTuicrFileTransaction(homeDirectory: homeDirectory)
    let transitionedTuicrBeforeLinks = old?.tuicr != nil
    if transitionedTuicrBeforeLinks {
      guard let tuicrReplacementName else {
        throw EnvironmentLifecycleError.blocked("tuicr transaction has no replacement identity")
      }
      try tuicrTransaction.transition(
        from: old,
        to: new,
        replacementName: tuicrReplacementName
      )
    }

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
            directoryLink: record.id.directoryLinkKind
          ) {
            try retainOriginal(record)
            try publishManaged(entry)
          } else {
            throw EnvironmentLifecycleError.drift(entry.url.path)
          }
        }
      }
    }
    if old?.btop != nil || new?.btop != nil {
      guard let btopReplacementName else {
        throw EnvironmentLifecycleError.blocked("btop transaction has no replacement identity")
      }
      try EnvironmentBtopFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).transition(from: old, to: new, replacementName: btopReplacementName)
    }
    if !transitionedTuicrBeforeLinks, new?.tuicr != nil {
      guard let tuicrReplacementName else {
        throw EnvironmentLifecycleError.blocked("tuicr transaction has no replacement identity")
      }
      try tuicrTransaction.transition(
        from: old,
        to: new,
        replacementName: tuicrReplacementName
      )
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
    if let btop = ownership.btop {
      let expected = homeDirectory.appending(path: ".config/btop/btop.conf").path
      guard btop.path == expected else {
        throw EnvironmentLifecycleError.blocked("ownership contains an unexpected btop path")
      }
    }
    if let tuicr = ownership.tuicr {
      let expected = homeDirectory.appending(path: ".config/tuicr/config.toml").path
      guard tuicr.path == expected else {
        throw EnvironmentLifecycleError.blocked("ownership contains an unexpected tuicr path")
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
            directoryLink: record.id.directoryLinkKind
          )
        else {
          throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
        }
      }
    }
    if let btop = ownership.btop {
      let url = URL(filePath: btop.path)
      let evidence = try inspector.capture(url, directoryLink: nil)
      let state = try EnvironmentBtopFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      ).generationState(ownership.generationID)
      guard evidence.kind == .regularFile,
        try EnvironmentBtopDocument.matchesManaged(
          String(data: BoundedRegularFile.read(at: url).data, encoding: .utf8) ?? "",
          values: state.values,
          source: url
        )
      else {
        throw EnvironmentLifecycleError.drift(url.path)
      }
    }
    if let tuicr = ownership.tuicr {
      try EnvironmentTuicrFileTransaction(homeDirectory: homeDirectory).preflight(tuicr)
    } else if ownership.tuicrEnabled,
      !ownership.records.contains(where: {
        $0.id == .tuicrTheme || $0.id == .tuicrSyntax
      })
    {
      guard
        try inspector.tuicrExternalTupleIsExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        )
      else {
        throw EnvironmentLifecycleError.drift("externally owned tuicr tuple")
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
            directoryLink: record.id.directoryLinkKind
          ),
          !(try itemExists(entry.url))
        else { throw EnvironmentLifecycleError.drift(entry.url.path) }
      } else {
        guard
          try evidence(
            at: entry.url,
            matches: record.original,
            directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
        directoryLink: record.id.directoryLinkKind
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
    directoryLink: EnvironmentDirectoryLinkKind?
  ) throws -> Bool {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    return try inspector.capturePinned(
      parentDescriptor: parent,
      name: url.lastPathComponent,
      url: url,
      directoryLink: directoryLink
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
