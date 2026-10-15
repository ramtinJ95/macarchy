import Foundation
import ThemeCore

enum EnvironmentEntryID: String, Codable, CaseIterable, Sendable {
  case kitty
  case bordersDirectory = "borders_directory"
  case bordersConfiguration = "borders_configuration"
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
    case .bordersDirectory: .borders
    default: nil
    }
  }
}

enum EnvironmentDirectoryLinkKind: String, Sendable {
  case kitty = "Kitty"
  case neovim = "Neovim"
  case borders = "Borders"

  var maximumEntries: Int {
    switch self {
    case .kitty: 128
    case .neovim: 512
    case .borders: 128
    }
  }

  var maximumBytes: Int {
    switch self {
    case .kitty: 4 * 1_048_576
    case .neovim: 8 * 1_048_576
    case .borders: 4 * 1_048_576
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

  static let absent = Self(
    kind: .absent, device: nil, inode: nil, mode: nil, size: nil,
    linkDestination: nil, contentDigest: nil, metadataDigest: nil, inventory: [])

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
  static let currentSchemaVersion = 2

  let schemaVersion: Int
  let generationID: String
  let records: [EnvironmentOwnershipRecord]
  let createdDirectories: [String]
  let originalThemeBridges: [EnvironmentThemeBridgeState.Entry]
  let btop: EnvironmentBtopOwnership?
  let borders: EnvironmentBordersOwnership?
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
  /// Theme authority only: these standard configuration entries remain user-owned.
  let standardNativeEntries: [EnvironmentEntryID]?

  init(
    generationID: String,
    records: [EnvironmentOwnershipRecord],
    createdDirectories: [String],
    originalThemeBridges: [EnvironmentThemeBridgeState.Entry],
    btop: EnvironmentBtopOwnership? = nil,
    borders: EnvironmentBordersOwnership? = nil,
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
    enabledThemeAdapterIDs: [String]? = nil,
    standardNativeEntries: [EnvironmentEntryID] = []
  ) {
    schemaVersion = standardNativeEntries.isEmpty ? 1 : Self.currentSchemaVersion
    self.generationID = generationID
    self.records = records.sorted { $0.id.rawValue < $1.id.rawValue }
    self.createdDirectories = createdDirectories.sorted()
    self.originalThemeBridges = originalThemeBridges.sorted { $0.path < $1.path }
    self.btop = btop
    self.borders = borders
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
    self.standardNativeEntries =
      standardNativeEntries.isEmpty
      ? nil : standardNativeEntries.sorted { $0.rawValue < $1.rawValue }
  }

  /// Carries every preset field over from `base` and rebuilds through the primary
  /// initializer, so record order and the schema version stay derived.
  init(
    copying base: Self?,
    generationID: String,
    records: [EnvironmentOwnershipRecord],
    herdr: EnvironmentHerdrOwnership?,
    enabledThemeAdapterIDs: [String]?,
    standardNativeEntries: [EnvironmentEntryID]
  ) {
    self.init(
      generationID: generationID, records: records,
      createdDirectories: base?.createdDirectories ?? [],
      originalThemeBridges: base?.originalThemeBridges ?? [],
      btop: base?.btop, borders: base?.borders, codex: base?.codex, herdr: herdr, pi: base?.pi,
      spicetify: base?.spicetify, tuicr: base?.tuicr,
      codexEnabled: base?.codexEnabled ?? false, herdrEnabled: base?.herdrEnabled ?? false,
      piEnabled: base?.piEnabled ?? false, slackEnabled: base?.slackEnabled ?? false,
      spicetifyEnabled: base?.spicetifyEnabled ?? false,
      tuicrEnabled: base?.tuicrEnabled ?? false,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs,
      standardNativeEntries: standardNativeEntries)
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case records
    case createdDirectories = "created_directories"
    case originalThemeBridges = "original_theme_bridges"
    case btop
    case borders
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
    case standardNativeEntries = "standard_native_entries"
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
    borders = try container.decodeIfPresent(EnvironmentBordersOwnership.self, forKey: .borders)
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
    standardNativeEntries = try container.decodeIfPresent(
      [EnvironmentEntryID].self, forKey: .standardNativeEntries)
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
          && adapterIDs.contains(BordersAdapter.id) == (borders != nil)
      } ?? true
    let standard = standardNativeEntries ?? []
    guard (schemaVersion == 1 && standard.isEmpty) || schemaVersion == Self.currentSchemaVersion,
      Set(standard).isSubset(of: [.atuinConfiguration, .starship, .zsh, .kitty, .neovim]),
      standard == standard.sorted(by: { $0.rawValue < $1.rawValue }),
      Set(standard).count == standard.count,
      Set(standard).isDisjoint(with: records.map(\.id)),
      EnvironmentGenerationStore.isGenerationID(generationID),
      Set(records.map(\.id)).count == records.count,
      Set(createdDirectories).count == createdDirectories.count,
      Set(originalThemeBridges.map(\.path)).count == originalThemeBridges.count,
      btop?.hasValidShape ?? true,
      borders?.hasValidShape ?? true,
      records.filter { [.bordersDirectory, .bordersConfiguration].contains($0.id) }.count
        == (borders == nil ? 0 : 1),
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
        return record.id.directoryLinkKind == nil
          && record.retainedPath != nil && hasIdentity
          && evidence.linkDestination == nil && evidence.contentDigest != nil
          && evidence.inventory.isEmpty
      case .symbolicLink:
        return record.retainedPath != nil && hasIdentity
          && evidence.linkDestination != nil && evidence.contentDigest == nil
          && (record.id.directoryLinkKind != nil || evidence.inventory.isEmpty)
      }
    }
  }

  func releasingStandardEntry(_ id: EnvironmentEntryID) -> Self {
    Self(
      copying: self, generationID: generationID, records: records.filter { $0.id != id },
      herdr: herdr, enabledThemeAdapterIDs: enabledThemeAdapterIDs,
      standardNativeEntries: (standardNativeEntries ?? []) + [id])
  }

  func replacingHerdr(_ herdr: EnvironmentHerdrOwnership?) -> Self {
    Self(
      copying: self, generationID: generationID, records: records, herdr: herdr,
      enabledThemeAdapterIDs: enabledThemeAdapterIDs,
      standardNativeEntries: standardNativeEntries ?? [])
  }
}
