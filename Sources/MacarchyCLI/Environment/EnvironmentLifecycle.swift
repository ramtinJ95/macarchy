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
  case batConfiguration = "bat_configuration"
  case batTheme = "bat_theme"
  case btopConfiguration = "btop_configuration"
  case btopTheme = "btop_theme"
  case ezaTheme = "eza_theme"
  case codexConfiguration = "codex_configuration"
  case codexTheme = "codex_theme"
  case piConfiguration = "pi_configuration"
  case piTheme = "pi_theme"
  case spicetifyColor = "spicetify_color"
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
  let codex: EnvironmentCodexOwnership?
  let herdr: EnvironmentHerdrOwnership?
  let pi: EnvironmentPiOwnership?
  let spicetify: EnvironmentSpicetifyOwnership?
  let tuicr: EnvironmentTuicrOwnership?
  let codexEnabled: Bool
  let herdrEnabled: Bool
  let piEnabled: Bool
  let slackEnabled: Bool
  let spicetifyEnabled: Bool
  let tuicrEnabled: Bool
  let enabledThemeAdapterIDs: [String]?

  init(
    generationID: String,
    records: [EnvironmentOwnershipRecord],
    createdDirectories: [String],
    originalThemeBridges: [EnvironmentThemeBridgeState.Entry],
    btop: EnvironmentBtopOwnership? = nil,
    codex: EnvironmentCodexOwnership? = nil,
    herdr: EnvironmentHerdrOwnership? = nil,
    pi: EnvironmentPiOwnership? = nil,
    spicetify: EnvironmentSpicetifyOwnership? = nil,
    tuicr: EnvironmentTuicrOwnership? = nil,
    codexEnabled: Bool = false,
    herdrEnabled: Bool = false,
    piEnabled: Bool = false,
    slackEnabled: Bool = false,
    spicetifyEnabled: Bool = false,
    tuicrEnabled: Bool = false,
    enabledThemeAdapterIDs: [String]? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generationID = generationID
    self.records = records.sorted { $0.id.rawValue < $1.id.rawValue }
    self.createdDirectories = createdDirectories.sorted()
    self.originalThemeBridges = originalThemeBridges.sorted { $0.path < $1.path }
    self.btop = btop
    self.codex = codex
    self.herdr = herdr
    self.pi = pi
    self.spicetify = spicetify
    self.tuicr = tuicr
    self.codexEnabled = codexEnabled
    self.herdrEnabled = herdrEnabled
    self.piEnabled = piEnabled
    self.slackEnabled = slackEnabled
    self.spicetifyEnabled = spicetifyEnabled
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
    case codex
    case herdr
    case pi
    case spicetify
    case tuicr
    case codexEnabled = "codex_enabled"
    case herdrEnabled = "herdr_enabled"
    case piEnabled = "pi_enabled"
    case slackEnabled = "slack_enabled"
    case spicetifyEnabled = "spicetify_enabled"
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
    codex = try container.decodeIfPresent(EnvironmentCodexOwnership.self, forKey: .codex)
    herdr = try container.decodeIfPresent(EnvironmentHerdrOwnership.self, forKey: .herdr)
    pi = try container.decodeIfPresent(EnvironmentPiOwnership.self, forKey: .pi)
    spicetify = try container.decodeIfPresent(
      EnvironmentSpicetifyOwnership.self, forKey: .spicetify)
    tuicr = try container.decodeIfPresent(EnvironmentTuicrOwnership.self, forKey: .tuicr)
    codexEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? false
    herdrEnabled = try container.decodeIfPresent(Bool.self, forKey: .herdrEnabled) ?? false
    piEnabled = try container.decodeIfPresent(Bool.self, forKey: .piEnabled) ?? false
    slackEnabled = try container.decodeIfPresent(Bool.self, forKey: .slackEnabled) ?? false
    spicetifyEnabled = try container.decodeIfPresent(Bool.self, forKey: .spicetifyEnabled) ?? false
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
          && adapterIDs.contains(CodexAdapter.id) == codexEnabled
          && adapterIDs.contains(HerdrAdapter.id) == herdrEnabled
          && adapterIDs.contains(PiAdapter.id) == piEnabled
          && adapterIDs.contains(SpicetifyAdapter.id) == spicetifyEnabled
          && adapterIDs.contains(TuicrAdapter.id) == tuicrEnabled
      } ?? true
    guard schemaVersion == Self.currentSchemaVersion,
      EnvironmentGenerationStore.isGenerationID(generationID),
      Set(records.map(\.id)).count == records.count,
      Set(createdDirectories).count == createdDirectories.count,
      Set(originalThemeBridges.map(\.path)).count == originalThemeBridges.count,
      btop?.hasValidShape ?? true,
      codex?.hasValidShape ?? true,
      herdr?.hasValidShape ?? true,
      pi?.hasValidShape ?? true,
      spicetify?.hasValidShape ?? true,
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

  func replacingHerdr(_ herdr: EnvironmentHerdrOwnership?) -> Self {
    Self(
      generationID: generationID,
      records: records,
      createdDirectories: createdDirectories,
      originalThemeBridges: originalThemeBridges,
      btop: btop,
      codex: codex,
      herdr: herdr,
      pi: pi,
      spicetify: spicetify,
      tuicr: tuicr,
      codexEnabled: codexEnabled,
      herdrEnabled: herdrEnabled,
      piEnabled: piEnabled,
      slackEnabled: slackEnabled,
      spicetifyEnabled: spicetifyEnabled,
      tuicrEnabled: tuicrEnabled,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs
    )
  }
}

enum EnvironmentTransactionOperation: String, Codable, Sendable {
  case apply
  case herdrTheme = "herdr_theme"
  case teardown
}

enum EnvironmentTransactionDirection: String, Codable, Sendable {
  case forward
  case rollback
}

enum EnvironmentHerdrRuntimeTarget: String, Codable, Equatable, Sendable {
  case managed
  case original
}

enum EnvironmentSpicetifyRuntimeTarget: String, Codable, Equatable, Sendable {
  case managed
  case original
}

private func requiredSpicetifyRuntimeTarget(
  from old: EnvironmentOwnership?,
  to new: EnvironmentOwnership?
) -> EnvironmentSpicetifyRuntimeTarget? {
  let wasEnabled = old?.spicetifyEnabled == true
  let willBeEnabled = new?.spicetifyEnabled == true
  if wasEnabled != willBeEnabled { return willBeEnabled ? .managed : .original }
  if wasEnabled,
    old?.generationID != new?.generationID || old?.spicetify != new?.spicetify
  {
    return .managed
  }
  return nil
}

private func requiredHerdrRuntimeTarget(
  from old: EnvironmentOwnership?,
  to new: EnvironmentOwnership?
) -> EnvironmentHerdrRuntimeTarget? {
  let wasEnabled = old?.herdrEnabled == true
  let willBeEnabled = new?.herdrEnabled == true
  if wasEnabled != willBeEnabled { return willBeEnabled ? .managed : .original }
  if wasEnabled, old?.herdr?.managedTheme != new?.herdr?.managedTheme { return .managed }
  return nil
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
  let codexReplacementName: String?
  let herdrReplacementName: String?
  let herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget?
  let herdrRuntimeVerified: Bool?
  let herdrLegacyMigration: Bool?
  let piReplacementName: String?
  let spicetifyReplacementName: String?
  let spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget?
  let spicetifyRuntimeVerified: Bool?
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
    codexReplacementName: String? = nil,
    herdrReplacementName: String? = nil,
    herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget? = nil,
    herdrRuntimeVerified: Bool? = nil,
    herdrLegacyMigration: Bool? = nil,
    piReplacementName: String? = nil,
    spicetifyReplacementName: String? = nil,
    spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget? = nil,
    spicetifyRuntimeVerified: Bool? = nil,
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
    self.codexReplacementName = codexReplacementName
    self.herdrReplacementName = herdrReplacementName
    self.herdrRuntimeTarget = herdrRuntimeTarget
    self.herdrRuntimeVerified = herdrRuntimeVerified
    self.herdrLegacyMigration = herdrLegacyMigration
    self.piReplacementName = piReplacementName
    self.spicetifyReplacementName = spicetifyReplacementName
    self.spicetifyRuntimeTarget = spicetifyRuntimeTarget
    self.spicetifyRuntimeVerified = spicetifyRuntimeVerified
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
      codexReplacementName: codexReplacementName,
      herdrReplacementName: herdrReplacementName,
      herdrRuntimeTarget: herdrLegacyMigration == true
        ? .managed
        : requiredHerdrRuntimeTarget(
          from: proposedOwnership,
          to: previousOwnership
        ),
      herdrRuntimeVerified: nil,
      herdrLegacyMigration: herdrLegacyMigration,
      piReplacementName: piReplacementName,
      spicetifyReplacementName: spicetifyReplacementName,
      spicetifyRuntimeTarget: requiredSpicetifyRuntimeTarget(
        from: proposedOwnership,
        to: previousOwnership
      ),
      spicetifyRuntimeVerified: nil,
      tuicrReplacementName: tuicrReplacementName
    )
  }

  var withHerdrRuntimeVerified: Self {
    Self(
      operation: operation,
      direction: direction,
      previousOwnership: previousOwnership,
      proposedOwnership: proposedOwnership,
      previousCurrentDestination: previousCurrentDestination,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: rollbackThemeBridges,
      btopReplacementName: btopReplacementName,
      codexReplacementName: codexReplacementName,
      herdrReplacementName: herdrReplacementName,
      herdrRuntimeTarget: herdrRuntimeTarget,
      herdrRuntimeVerified: true,
      herdrLegacyMigration: herdrLegacyMigration,
      piReplacementName: piReplacementName,
      spicetifyReplacementName: spicetifyReplacementName,
      spicetifyRuntimeTarget: spicetifyRuntimeTarget,
      spicetifyRuntimeVerified: spicetifyRuntimeVerified,
      tuicrReplacementName: tuicrReplacementName
    )
  }

  var withSpicetifyRuntimeVerified: Self {
    Self(
      operation: operation,
      direction: direction,
      previousOwnership: previousOwnership,
      proposedOwnership: proposedOwnership,
      previousCurrentDestination: previousCurrentDestination,
      previousThemeGenerationID: previousThemeGenerationID,
      rollbackThemeBridges: rollbackThemeBridges,
      btopReplacementName: btopReplacementName,
      codexReplacementName: codexReplacementName,
      herdrReplacementName: herdrReplacementName,
      herdrRuntimeTarget: herdrRuntimeTarget,
      herdrRuntimeVerified: herdrRuntimeVerified,
      herdrLegacyMigration: herdrLegacyMigration,
      piReplacementName: piReplacementName,
      spicetifyReplacementName: spicetifyReplacementName,
      spicetifyRuntimeTarget: spicetifyRuntimeTarget,
      spicetifyRuntimeVerified: true,
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
    case codexReplacementName = "codex_replacement_name"
    case herdrReplacementName = "herdr_replacement_name"
    case herdrRuntimeTarget = "herdr_runtime_target"
    case herdrRuntimeVerified = "herdr_runtime_verified"
    case herdrLegacyMigration = "herdr_legacy_migration"
    case piReplacementName = "pi_replacement_name"
    case spicetifyReplacementName = "spicetify_replacement_name"
    case spicetifyRuntimeTarget = "spicetify_runtime_target"
    case spicetifyRuntimeVerified = "spicetify_runtime_verified"
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
        && (![.apply, .herdrTheme].contains(value.operation)
          || value.proposedOwnership != nil)
        && (value.previousOwnership?.hasValidShape ?? true)
        && (value.proposedOwnership?.hasValidShape ?? true)
        && Self.currentDestinationIsValid(value.previousCurrentDestination)
        && EnvironmentThemeBridgeState.pathsAreValid(
          value.rollbackThemeBridges,
          stateRoot: stateRoot
        )
        && Self.btopReplacementIsValid(value)
        && Self.codexReplacementIsValid(value)
        && Self.herdrReplacementIsValid(value)
        && Self.herdrRuntimeIsValid(value)
        && Self.piReplacementIsValid(value)
        && Self.spicetifyReplacementIsValid(value)
        && Self.spicetifyRuntimeIsValid(value)
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
    return replacementIsValid(
      transaction.btopReplacementName,
      required: required,
      prefix: ".macarchy-environment-btop-"
    )
  }

  private static func codexReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.codex != nil
      || transaction.proposedOwnership?.codex != nil
    return replacementIsValid(
      transaction.codexReplacementName,
      required: required,
      prefix: ".macarchy-environment-codex-"
    )
  }

  private static func tuicrReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.tuicr != nil
      || transaction.proposedOwnership?.tuicr != nil
    return replacementIsValid(
      transaction.tuicrReplacementName,
      required: required,
      prefix: ".macarchy-environment-tuicr-"
    )
  }

  private static func herdrReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.herdr != nil
      || transaction.proposedOwnership?.herdr != nil
    return replacementIsValid(
      transaction.herdrReplacementName,
      required: required,
      prefix: ".macarchy-environment-herdr-"
    )
  }

  private static func herdrRuntimeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let expected =
      transaction.direction == .rollback && transaction.herdrLegacyMigration == true
      ? .managed
      : transaction.direction == .forward
        ? requiredHerdrRuntimeTarget(
          from: transaction.previousOwnership,
          to: transaction.proposedOwnership
        )
        : requiredHerdrRuntimeTarget(
          from: transaction.proposedOwnership,
          to: transaction.previousOwnership
        )
    return transaction.herdrRuntimeTarget == expected
      && (transaction.herdrRuntimeVerified == nil || transaction.herdrRuntimeVerified == true)
      && herdrLegacyMigrationIsValid(transaction)
  }

  private static func herdrLegacyMigrationIsValid(
    _ transaction: EnvironmentTransaction
  ) -> Bool {
    guard transaction.herdrLegacyMigration != false else { return false }
    guard transaction.herdrLegacyMigration == true else { return true }
    return transaction.operation == .apply
      && transaction.previousOwnership?.herdr == nil
      && transaction.proposedOwnership?.herdrEnabled == true
      && transaction.proposedOwnership?.herdr?.migratedLegacy == true
  }

  private static func piReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.pi != nil
      || transaction.proposedOwnership?.pi != nil
    return replacementIsValid(
      transaction.piReplacementName,
      required: required,
      prefix: ".macarchy-environment-pi-"
    )
  }

  private static func spicetifyReplacementIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let required =
      transaction.previousOwnership?.spicetify != nil
      || transaction.proposedOwnership?.spicetify != nil
    return replacementIsValid(
      transaction.spicetifyReplacementName,
      required: required,
      prefix: ".macarchy-environment-spicetify-"
    )
  }

  private static func spicetifyRuntimeIsValid(_ transaction: EnvironmentTransaction) -> Bool {
    let expected =
      transaction.direction == .forward
      ? requiredSpicetifyRuntimeTarget(
        from: transaction.previousOwnership,
        to: transaction.proposedOwnership
      )
      : requiredSpicetifyRuntimeTarget(
        from: transaction.proposedOwnership,
        to: transaction.previousOwnership
      )
    return transaction.spicetifyRuntimeTarget == expected
      && (transaction.spicetifyRuntimeVerified == nil
        || transaction.spicetifyRuntimeVerified == true)
  }

  private static func replacementIsValid(
    _ name: String?,
    required: Bool,
    prefix: String
  ) -> Bool {
    guard required else { return name == nil }
    guard let name else { return false }
    return name.hasPrefix(prefix)
      && name.hasSuffix(".replacement")
      && !name.contains("/")
      && name.utf8.count <= 128
  }
}

enum EnvironmentTransactionCheckpoint: Equatable, Sendable {
  case authorityPublished
}

struct EnvironmentTransactionCoordinator: Sendable {
  let homeDirectory: URL
  let stateRoot: URL
  var faultInjector: @Sendable (EnvironmentTransactionCheckpoint) throws -> Void
  private let inspector: EnvironmentProviderInspector

  init(
    homeDirectory: URL,
    stateRoot: URL,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void = { _ in },
    inspector: EnvironmentProviderInspector = EnvironmentProviderInspector()
  ) {
    self.homeDirectory = homeDirectory
    self.stateRoot = stateRoot
    self.faultInjector = faultInjector
    self.inspector = inspector
  }

  func recoverLocked() throws -> Bool {
    let result = try prepareRecoveryLocked()
    guard result.runtimeTarget == nil, result.spicetifyRuntimeTarget == nil else {
      throw EnvironmentLifecycleError.blocked(
        "interrupted provider runtime restoration must finish before recovery can finish"
      )
    }
    return result.recovered
  }

  func prepareRecoveryLocked() throws -> (
    recovered: Bool,
    runtimeTarget: EnvironmentHerdrRuntimeTarget?,
    spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget?
  ) {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else { return (false, nil, nil) }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    switch transaction.direction {
    case .forward:
      switch transaction.operation {
      case .apply, .herdrTheme:
        guard let proposed = transaction.proposedOwnership else {
          throw EnvironmentLifecycleError.blocked("apply recovery has no proposed ownership")
        }
        if transaction.operation == .apply {
          _ = try EnvironmentGenerationStore(stateRoot: stateRoot).manifest(
            generationID: proposed.generationID
          )
        }
        try transition(
          from: transaction.previousOwnership,
          to: proposed,
          btopReplacementName: transaction.btopReplacementName,
          codexReplacementName: transaction.codexReplacementName,
          herdrReplacementName: transaction.herdrReplacementName,
          piReplacementName: transaction.piReplacementName,
          spicetifyReplacementName: transaction.spicetifyReplacementName,
          tuicrReplacementName: transaction.tuicrReplacementName
        )
        if transaction.operation == .apply {
          try restoreReleasedThemeBridges(from: transaction.previousOwnership, to: proposed)
          try EnvironmentGenerationStore(stateRoot: stateRoot).select(proposed.generationID)
        }
        try store.writeOwnership(proposed)
      case .teardown:
        try transition(
          from: transaction.previousOwnership,
          to: nil,
          btopReplacementName: transaction.btopReplacementName,
          codexReplacementName: transaction.codexReplacementName,
          herdrReplacementName: transaction.herdrReplacementName,
          piReplacementName: transaction.piReplacementName,
          spicetifyReplacementName: transaction.spicetifyReplacementName,
          tuicrReplacementName: transaction.tuicrReplacementName
        )
      }
    case .rollback:
      let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
      try transition(
        from: transaction.proposedOwnership,
        to: transaction.previousOwnership,
        btopReplacementName: transaction.btopReplacementName,
        codexReplacementName: transaction.codexReplacementName,
        herdrReplacementName: transaction.herdrReplacementName,
        piReplacementName: transaction.piReplacementName,
        spicetifyReplacementName: transaction.spicetifyReplacementName,
        tuicrReplacementName: transaction.tuicrReplacementName,
        preserveLegacyHerdrOnRemoval: preserveLegacyHerdr
      )
      try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
        transaction.previousCurrentDestination
      )
      try restoreRollbackThemeBridges(transaction)
      try store.writeOwnership(transaction.previousOwnership)
    }

    if let target = transaction.herdrRuntimeTarget,
      transaction.herdrRuntimeVerified != true
    {
      return (true, target, pendingSpicetifyRuntimeTarget(transaction))
    }
    if let target = pendingSpicetifyRuntimeTarget(transaction) {
      return (true, nil, target)
    }

    switch (transaction.direction, transaction.operation) {
    case (.forward, .apply), (.forward, .herdrTheme):
      if let proposed = transaction.proposedOwnership,
        proposed.herdr?.migratedLegacy == true, !proposed.herdrEnabled
      {
        try discardHerdrLegacyEvidence()
      }
    case (.forward, .teardown):
      try EnvironmentThemeBridgeState(
        entries: transaction.previousOwnership?.originalThemeBridges ?? []
      ).restore()
      try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(nil)
      try store.writeOwnership(nil)
      if transaction.previousOwnership?.herdr?.migratedLegacy == true {
        try discardHerdrLegacyEvidence()
      }
    case (.rollback, _):
      break
    }
    try store.removeTransaction()
    return (true, nil, nil)
  }

  private func pendingSpicetifyRuntimeTarget(
    _ transaction: EnvironmentTransaction
  ) -> EnvironmentSpicetifyRuntimeTarget? {
    transaction.spicetifyRuntimeVerified == true ? nil : transaction.spicetifyRuntimeTarget
  }

  func pendingHerdrRuntimeTargetLocked() throws -> EnvironmentHerdrRuntimeTarget? {
    guard let transaction = try EnvironmentStateStore(stateRoot: stateRoot).readTransaction(),
      transaction.herdrRuntimeVerified != true
    else { return nil }
    return transaction.herdrRuntimeTarget
  }

  func markHerdrRuntimeVerifiedLocked(_ target: EnvironmentHerdrRuntimeTarget) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction(),
      transaction.herdrRuntimeTarget == target,
      transaction.herdrRuntimeVerified != true
    else {
      throw EnvironmentLifecycleError.blocked(
        "no matching Herdr runtime restoration is pending"
      )
    }
    try store.writeTransaction(transaction.withHerdrRuntimeVerified)
  }

  func pendingSpicetifyRuntimeTargetLocked() throws -> EnvironmentSpicetifyRuntimeTarget? {
    guard let transaction = try EnvironmentStateStore(stateRoot: stateRoot).readTransaction()
    else { return nil }
    return pendingSpicetifyRuntimeTarget(transaction)
  }

  func markSpicetifyRuntimeVerifiedLocked(
    _ target: EnvironmentSpicetifyRuntimeTarget
  ) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction(),
      transaction.spicetifyRuntimeTarget == target,
      transaction.spicetifyRuntimeVerified != true
    else {
      throw EnvironmentLifecycleError.blocked(
        "no matching Spicetify runtime restoration is pending"
      )
    }
    try store.writeTransaction(transaction.withSpicetifyRuntimeVerified)
  }

  func preflightManagedHerdr(
    _ desired: GeneratedHerdrTheme,
    requireActiveMatch: Bool
  ) throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard try store.readTransaction() == nil else {
      throw EnvironmentLifecycleError.blocked(
        "an interrupted environment transaction must be recovered first"
      )
    }
    guard let ownership = try store.readOwnership(), ownership.herdrEnabled,
      let herdr = ownership.herdr
    else {
      throw EnvironmentLifecycleError.blocked("aggregate Herdr ownership is not active")
    }
    _ = try desired.validated()
    try EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    ).preflight(herdr)
    if requireActiveMatch, herdr.managedTheme != desired {
      throw EnvironmentLifecycleError.drift(
        "Herdr ownership does not match the active theme generation"
      )
    }
  }

  func applyLocked(
    composition: EnvironmentComposition,
    inspection: EnvironmentProviderInspection,
    adoptionDigest: String?,
    previousThemeGenerationID: String? = nil,
    themeBridges: EnvironmentThemeBridgeState,
    enabledThemeAdapterIDs: [String]? = nil
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

    // Revalidate every external seam before staging or publishing any state.
    for (id, expected) in inspection.externalEvidence {
      guard let entry = inspection.desiredEntries.first(where: { $0.id == id }),
        try inspector.capture(entry.url, directoryLink: entry.id.directoryLinkKind) == expected
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
    if let expected = inspection.codexExternalEvidence {
      let url = homeDirectory.appending(path: ".codex/config.toml")
      let tupleIsExact =
        try inspection.proposedCodexOwnership != nil
        || inspector.codexExternalTupleIsExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot,
          configurationEvidence: expected
        )
      guard try inspector.capture(url, directoryLink: nil) == expected, tupleIsExact
      else {
        throw EnvironmentLifecycleError.blocked(
          "Codex external tuple changed after planning; run environment plan again"
        )
      }
    }
    if let expected = inspection.herdrExternalEvidence {
      let url = homeDirectory.appending(path: ".config/herdr/config.toml")
      guard try inspector.capture(url, directoryLink: nil) == expected else {
        throw EnvironmentLifecycleError.blocked(
          "Herdr configuration changed after planning; run environment plan again"
        )
      }
    }
    if let expected = inspection.piExternalEvidence {
      let url = homeDirectory.appending(path: ".pi/agent/settings.json")
      guard try inspector.capture(url, directoryLink: nil) == expected else {
        throw EnvironmentLifecycleError.blocked(
          "Pi settings changed after planning; run environment plan again"
        )
      }
    }
    if let expected = inspection.spicetifyExternalEvidence {
      let url = homeDirectory.appending(path: ".config/spicetify/config-xpui.ini")
      let tupleIsExact =
        try inspection.proposedSpicetifyOwnership != nil
        || inspector.spicetifyExternalTupleIsExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot,
          configurationEvidence: expected
        )
      guard try inspector.capture(url, directoryLink: nil) == expected, tupleIsExact else {
        throw EnvironmentLifecycleError.blocked(
          "Spicetify external tuple changed after planning; run environment plan again"
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
      codex: inspection.proposedCodexOwnership,
      herdr: inspection.proposedHerdrOwnership,
      pi: inspection.proposedPiOwnership,
      spicetify: inspection.proposedSpicetifyOwnership,
      tuicr: inspection.proposedTuicrOwnership,
      codexEnabled: composition.profile.presets.codex,
      herdrEnabled: composition.profile.presets.herdr,
      piEnabled: composition.profile.presets.pi,
      slackEnabled: composition.profile.presets.slack,
      spicetifyEnabled: composition.profile.presets.spicetify,
      tuicrEnabled: composition.profile.presets.tuicr,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs
        ?? composition.profile.selectedThemeAdapterIDs
    )
    let generationChanged = previous?.generationID != proposed.generationID
    let ownershipChanged =
      previous?.records != proposed.records || previous?.btop != proposed.btop
      || previous?.codex != proposed.codex
      || previous?.herdr != proposed.herdr
      || previous?.pi != proposed.pi
      || previous?.spicetify != proposed.spicetify
      || previous?.tuicr != proposed.tuicr
      || previous?.codexEnabled != proposed.codexEnabled
      || previous?.herdrEnabled != proposed.herdrEnabled
      || previous?.piEnabled != proposed.piEnabled
      || previous?.slackEnabled != proposed.slackEnabled
      || previous?.spicetifyEnabled != proposed.spicetifyEnabled
      || previous?.tuicrEnabled != proposed.tuicrEnabled
      || previous?.enabledThemeAdapterIDs != proposed.enabledThemeAdapterIDs
    let changed = generationChanged || ownershipChanged

    let btopReplacementName =
      previous?.btop != nil || proposed.btop != nil
      ? ".macarchy-environment-btop-\(UUID().uuidString.lowercased()).replacement" : nil
    let codexReplacementName =
      previous?.codex != nil || proposed.codex != nil
      ? ".macarchy-environment-codex-\(UUID().uuidString.lowercased()).replacement" : nil
    let herdrReplacementName =
      previous?.herdr != nil || proposed.herdr != nil
      ? ".macarchy-environment-herdr-\(UUID().uuidString.lowercased()).replacement" : nil
    let piReplacementName =
      previous?.pi != nil || proposed.pi != nil
      ? ".macarchy-environment-pi-\(UUID().uuidString.lowercased()).replacement" : nil
    let spicetifyReplacementName =
      previous?.spicetify != nil || proposed.spicetify != nil
      ? ".macarchy-environment-spicetify-\(UUID().uuidString.lowercased()).replacement" : nil
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
      codexReplacementName: codexReplacementName,
      herdrReplacementName: herdrReplacementName,
      herdrRuntimeTarget: requiredHerdrRuntimeTarget(from: previous, to: proposed),
      herdrLegacyMigration:
        previous?.herdr == nil && proposed.herdr?.migratedLegacy == true ? true : nil,
      piReplacementName: piReplacementName,
      spicetifyReplacementName: spicetifyReplacementName,
      spicetifyRuntimeTarget: requiredSpicetifyRuntimeTarget(from: previous, to: proposed),
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
          codexReplacementName: codexReplacementName,
          herdrReplacementName: herdrReplacementName,
          piReplacementName: piReplacementName,
          spicetifyReplacementName: spicetifyReplacementName,
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
        let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
        try transition(
          from: proposed,
          to: previous,
          btopReplacementName: btopReplacementName,
          codexReplacementName: codexReplacementName,
          herdrReplacementName: herdrReplacementName,
          piReplacementName: piReplacementName,
          spicetifyReplacementName: spicetifyReplacementName,
          tuicrReplacementName: tuicrReplacementName,
          preserveLegacyHerdrOnRemoval: preserveLegacyHerdr
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
    if try pendingHerdrRuntimeTargetLocked() != nil {
      throw EnvironmentLifecycleError.blocked(
        "Herdr runtime activation is not verified"
      )
    }
    if try pendingSpicetifyRuntimeTargetLocked() != nil {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify runtime refresh is not verified"
      )
    }
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
    if let ownership = try EnvironmentStateStore(stateRoot: stateRoot).readOwnership(),
      ownership.herdr?.migratedLegacy == true, !ownership.herdrEnabled
    {
      try discardHerdrLegacyEvidence()
    }
    try faultInjector(.authorityPublished)
    try EnvironmentStateStore(stateRoot: stateRoot).removeTransaction()
  }

  func rollbackApplyLocked() throws {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard let transaction = try store.readTransaction() else {
      throw EnvironmentLifecycleError.blocked("no environment transaction can be rolled back")
    }
    try validate(transaction.previousOwnership)
    try validate(transaction.proposedOwnership)
    let preserveLegacyHerdr = try shouldPreserveLegacyHerdr(transaction)
    let rollback = transaction.rollingBack
    try store.writeTransaction(rollback)
    try transition(
      from: rollback.proposedOwnership,
      to: rollback.previousOwnership,
      btopReplacementName: rollback.btopReplacementName,
      codexReplacementName: rollback.codexReplacementName,
      herdrReplacementName: rollback.herdrReplacementName,
      piReplacementName: rollback.piReplacementName,
      spicetifyReplacementName: rollback.spicetifyReplacementName,
      tuicrReplacementName: rollback.tuicrReplacementName,
      preserveLegacyHerdrOnRemoval: preserveLegacyHerdr
    )
    try EnvironmentGenerationStore(stateRoot: stateRoot).restoreCurrent(
      rollback.previousCurrentDestination
    )
    try restoreRollbackThemeBridges(rollback)
    try store.writeOwnership(rollback.previousOwnership)
    if rollback.herdrRuntimeTarget == nil, rollback.spicetifyRuntimeTarget == nil {
      try store.removeTransaction()
    }
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
      codexReplacementName: ownership.codex.map { _ in
        ".macarchy-environment-codex-\(UUID().uuidString.lowercased()).replacement"
      },
      herdrReplacementName: ownership.herdr.map { _ in
        ".macarchy-environment-herdr-\(UUID().uuidString.lowercased()).replacement"
      },
      herdrRuntimeTarget: requiredHerdrRuntimeTarget(from: ownership, to: nil),
      piReplacementName: ownership.pi.map { _ in
        ".macarchy-environment-pi-\(UUID().uuidString.lowercased()).replacement"
      },
      spicetifyReplacementName: ownership.spicetify.map { _ in
        ".macarchy-environment-spicetify-\(UUID().uuidString.lowercased()).replacement"
      },
      spicetifyRuntimeTarget: requiredSpicetifyRuntimeTarget(from: ownership, to: nil),
      tuicrReplacementName: ownership.tuicr.map { _ in
        ".macarchy-environment-tuicr-\(UUID().uuidString.lowercased()).replacement"
      }
    )
    try store.writeTransaction(transaction)
    try transition(
      from: ownership,
      to: nil,
      btopReplacementName: transaction.btopReplacementName,
      codexReplacementName: transaction.codexReplacementName,
      herdrReplacementName: transaction.herdrReplacementName,
      piReplacementName: transaction.piReplacementName,
      spicetifyReplacementName: transaction.spicetifyReplacementName,
      tuicrReplacementName: transaction.tuicrReplacementName
    )
    if transaction.herdrRuntimeTarget == nil, transaction.spicetifyRuntimeTarget == nil {
      _ = try prepareRecoveryLocked()
    }
    return (true, "The exact adopted provider entries were restored.")
  }

  func beginHerdrThemeTransitionLocked(_ desired: GeneratedHerdrTheme) throws -> Bool {
    let store = EnvironmentStateStore(stateRoot: stateRoot)
    guard try store.readTransaction() == nil else {
      throw EnvironmentLifecycleError.blocked(
        "an interrupted environment transaction must be recovered first"
      )
    }
    guard let previous = try store.readOwnership(), previous.herdrEnabled,
      let herdr = previous.herdr
    else {
      throw EnvironmentLifecycleError.blocked("aggregate Herdr ownership is not active")
    }
    try EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    ).preflight(herdr)
    let desired = try desired.validated()
    guard herdr.managedTheme != desired else { return false }
    let proposed = previous.replacingHerdr(herdr.replacingManagedTheme(desired))
    let transaction = EnvironmentTransaction(
      operation: .herdrTheme,
      previousOwnership: previous,
      proposedOwnership: proposed,
      previousCurrentDestination: try EnvironmentGenerationStore(stateRoot: stateRoot)
        .currentDestination(),
      herdrReplacementName:
        ".macarchy-environment-herdr-\(UUID().uuidString.lowercased()).replacement",
      herdrRuntimeTarget: .managed
    )
    try store.writeTransaction(transaction)
    do {
      try transition(
        from: previous,
        to: proposed,
        btopReplacementName: nil,
        codexReplacementName: nil,
        herdrReplacementName: transaction.herdrReplacementName,
        piReplacementName: nil,
        spicetifyReplacementName: nil,
        tuicrReplacementName: nil
      )
      try store.writeOwnership(proposed)
      return true
    } catch {
      let transitionError = error
      do {
        try store.writeTransaction(transaction.rollingBack)
        try transition(
          from: proposed,
          to: previous,
          btopReplacementName: nil,
          codexReplacementName: nil,
          herdrReplacementName: transaction.herdrReplacementName,
          piReplacementName: nil,
          spicetifyReplacementName: nil,
          tuicrReplacementName: nil
        )
        try store.writeOwnership(previous)
        try store.removeTransaction()
      } catch {
        throw EnvironmentLifecycleError.blocked(
          "Herdr theme transition failed and rollback requires recovery: \(error)"
        )
      }
      throw transitionError
    }
  }

  private func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    btopReplacementName: String?,
    codexReplacementName: String?,
    herdrReplacementName: String?,
    piReplacementName: String?,
    spicetifyReplacementName: String?,
    tuicrReplacementName: String?,
    preserveLegacyHerdrOnRemoval: Bool = false
  ) throws {
    let oldByID = Dictionary(uniqueKeysWithValues: (old?.records ?? []).map { ($0.id, $0) })
    let newByID = Dictionary(uniqueKeysWithValues: (new?.records ?? []).map { ($0.id, $0) })
    let codexTransaction = EnvironmentCodexFileTransaction(homeDirectory: homeDirectory)
    let herdrTransaction = EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    let piTransaction = EnvironmentPiFileTransaction(homeDirectory: homeDirectory)
    let spicetifyTransaction = EnvironmentSpicetifyFileTransaction(homeDirectory: homeDirectory)
    let tuicrTransaction = EnvironmentTuicrFileTransaction(homeDirectory: homeDirectory)
    let transitionedPiBeforeLinks = old?.pi != nil
    let transitionedSpicetifyBeforeLinks = old?.spicetify != nil
    let transitionedCodexBeforeLinks = old?.codex != nil
    let transitionedHerdrBeforeLinks = old?.herdr != nil
    if transitionedCodexBeforeLinks {
      guard let codexReplacementName else {
        throw EnvironmentLifecycleError.blocked("Codex transaction has no replacement identity")
      }
      try codexTransaction.transition(from: old, to: new, replacementName: codexReplacementName)
    }
    if transitionedHerdrBeforeLinks {
      guard let herdrReplacementName else {
        throw EnvironmentLifecycleError.blocked("Herdr transaction has no replacement identity")
      }
      try herdrTransaction.transition(
        from: old,
        to: new,
        replacementName: herdrReplacementName,
        preserveLegacyManagedOnRemoval: preserveLegacyHerdrOnRemoval
      )
    }
    if transitionedPiBeforeLinks {
      guard let piReplacementName else {
        throw EnvironmentLifecycleError.blocked("Pi transaction has no replacement identity")
      }
      try piTransaction.transition(from: old, to: new, replacementName: piReplacementName)
    }
    if transitionedSpicetifyBeforeLinks {
      guard let spicetifyReplacementName else {
        throw EnvironmentLifecycleError.blocked("Spicetify transaction has no replacement identity")
      }
      try spicetifyTransaction.transition(
        from: old, to: new, replacementName: spicetifyReplacementName)
    }
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
    if !transitionedCodexBeforeLinks, new?.codex != nil {
      guard let codexReplacementName else {
        throw EnvironmentLifecycleError.blocked("Codex transaction has no replacement identity")
      }
      try codexTransaction.transition(from: old, to: new, replacementName: codexReplacementName)
    }
    if !transitionedHerdrBeforeLinks, new?.herdr != nil {
      guard let herdrReplacementName else {
        throw EnvironmentLifecycleError.blocked("Herdr transaction has no replacement identity")
      }
      try herdrTransaction.transition(
        from: old,
        to: new,
        replacementName: herdrReplacementName
      )
    }
    if !transitionedPiBeforeLinks, new?.pi != nil {
      guard let piReplacementName else {
        throw EnvironmentLifecycleError.blocked("Pi transaction has no replacement identity")
      }
      try piTransaction.transition(from: old, to: new, replacementName: piReplacementName)
    }
    if !transitionedSpicetifyBeforeLinks, new?.spicetify != nil {
      guard let spicetifyReplacementName else {
        throw EnvironmentLifecycleError.blocked("Spicetify transaction has no replacement identity")
      }
      try spicetifyTransaction.transition(
        from: old, to: new, replacementName: spicetifyReplacementName)
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

  private func shouldPreserveLegacyHerdr(_ transaction: EnvironmentTransaction) throws -> Bool {
    guard transaction.herdrLegacyMigration == true,
      transaction.operation == .apply,
      transaction.previousOwnership?.herdr == nil,
      transaction.proposedOwnership?.herdrEnabled == true,
      transaction.proposedOwnership?.herdr?.migratedLegacy == true
    else { return false }
    return try HerdrAdapter(
      root: stateRoot,
      configurationURL: homeDirectory.appending(path: ".config/herdr/config.toml"),
      executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
      controlIsAvailable: { true }
    ).authenticatedLegacyOwnershipMatchesCurrentGeneration()
  }

  private func discardHerdrLegacyEvidence() throws {
    try HerdrAdapter(
      root: stateRoot,
      configurationURL: homeDirectory.appending(path: ".config/herdr/config.toml"),
      executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
      controlIsAvailable: { true }
    ).discardLegacyOwnershipEvidence()
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
    if let codex = ownership.codex {
      let expected = homeDirectory.appending(path: ".codex/config.toml").path
      guard codex.path == expected else {
        throw EnvironmentLifecycleError.blocked("ownership contains an unexpected Codex path")
      }
    }
    if let herdr = ownership.herdr {
      let expected = homeDirectory.appending(path: ".config/herdr/config.toml").path
      guard herdr.path == expected else {
        throw EnvironmentLifecycleError.blocked("ownership contains an unexpected Herdr path")
      }
    }
    if let pi = ownership.pi {
      let expected = homeDirectory.appending(path: ".pi/agent/settings.json").path
      guard pi.path == expected else {
        throw EnvironmentLifecycleError.blocked("ownership contains an unexpected Pi path")
      }
    }
    if let spicetify = ownership.spicetify {
      let expected = homeDirectory.appending(path: ".config/spicetify/config-xpui.ini").path
      guard spicetify.path == expected else {
        throw EnvironmentLifecycleError.blocked(
          "ownership contains an unexpected Spicetify path")
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
        + [
          homeDirectory.appending(path: ".config").path,
          homeDirectory.appending(path: ".config/herdr").path,
        ]
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
    if let codex = ownership.codex {
      try EnvironmentCodexFileTransaction(homeDirectory: homeDirectory).preflight(codex)
    } else if ownership.codexEnabled,
      !ownership.records.contains(where: { $0.id == .codexTheme })
    {
      guard
        try inspector.codexExternalTupleIsExact(
          homeDirectory: homeDirectory, stateRoot: stateRoot)
      else { throw EnvironmentLifecycleError.drift("externally owned Codex tuple") }
    }
    if let herdr = ownership.herdr {
      let transaction = EnvironmentHerdrFileTransaction(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot
      )
      if ownership.herdrEnabled {
        try transaction.preflight(herdr)
      } else {
        try transaction.preflightOriginal(herdr)
      }
    }
    if let pi = ownership.pi {
      try EnvironmentPiFileTransaction(homeDirectory: homeDirectory).preflight(pi)
    } else if ownership.piEnabled,
      !ownership.records.contains(where: { $0.id == .piTheme })
    {
      guard
        try inspector.piExternalTupleIsExact(
          homeDirectory: homeDirectory,
          stateRoot: stateRoot
        )
      else { throw EnvironmentLifecycleError.drift("externally owned Pi tuple") }
    }
    if let spicetify = ownership.spicetify {
      try EnvironmentSpicetifyFileTransaction(homeDirectory: homeDirectory).preflight(spicetify)
    } else if ownership.spicetifyEnabled,
      !ownership.records.contains(where: { $0.id == .spicetifyColor })
    {
      guard
        try inspector.spicetifyExternalTupleIsExact(
          homeDirectory: homeDirectory, stateRoot: stateRoot)
      else { throw EnvironmentLifecycleError.drift("externally owned Spicetify tuple") }
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
