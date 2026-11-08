import Foundation
import ThemeCore

enum EnvironmentTransactionOperation: String, Codable, Sendable {
  case apply
  case herdrTheme = "herdr_theme"
  case neovimMigration = "neovim_migration"
  case neovimConnection = "neovim_connection"
  case atuinConnection = "atuin_connection"
  case starshipConnection = "starship_connection"
  case zshConnection = "zsh_connection"
  case kittyConnection = "kitty_connection"
  case atuinMigration = "atuin_migration"
  case starshipMigration = "starship_migration"
  case standardMigration = "standard_migration"
  case teardown

  var nativeFileProvider: EnvironmentNativeFileMigration.Provider? {
    switch self {
    case .atuinMigration: .atuin
    case .starshipMigration: .starship
    default: nil
    }
  }

  var isNativeMigration: Bool {
    self == .standardMigration || self == .neovimMigration || nativeFileProvider != nil
  }

  var nativeConnectionProvider: EnvironmentNativeSeed.Provider? {
    switch self {
    case .atuinConnection: .atuin
    case .starshipConnection: .starship
    case .zshConnection: .zsh
    case .kittyConnection: .kitty
    default: nil
    }
  }

  var isScopedConnection: Bool { self == .neovimConnection || nativeConnectionProvider != nil }
}

enum EnvironmentTransactionDirection: String, Codable, Sendable {
  case forward
  case rollback
}

enum EnvironmentHerdrRuntimeTarget: String, Codable, Equatable, Sendable {
  case managed
  case original

  static func required(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?
  ) -> EnvironmentHerdrRuntimeTarget? {
    let wasEnabled = old?.herdrEnabled == true
    let willBeEnabled = new?.herdrEnabled == true
    if wasEnabled != willBeEnabled { return willBeEnabled ? .managed : .original }
    if wasEnabled, old?.herdr?.managedTheme != new?.herdr?.managedTheme { return .managed }
    return nil
  }
}

enum EnvironmentSpicetifyRuntimeTarget: String, Codable, Equatable, Sendable {
  case managed
  case original

  static func required(
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
}

enum EnvironmentBordersRuntimeTarget: String, Codable, Equatable, Sendable {
  case managed
  case lean
  case original

  static func required(from old: EnvironmentOwnership?, to new: EnvironmentOwnership?) -> Self? {
    if new?.borders?.leanService != nil { return .lean }
    if new?.borders != nil { return .managed }
    return old?.borders == nil ? nil : .original
  }
}

struct EnvironmentTransaction: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let operation: EnvironmentTransactionOperation
  var direction: EnvironmentTransactionDirection
  let standardMigration: EnvironmentStandardMigration.Intent?
  let previousOwnership: EnvironmentOwnership?
  let proposedOwnership: EnvironmentOwnership?
  let previousCurrentDestination: String?
  let previousThemeGenerationID: String?
  let rollbackThemeBridges: [EnvironmentThemeBridgeState.Entry]
  let replacementNames: EnvironmentReplacementNames
  var herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget?
  var herdrRuntimeVerified: Bool?
  let herdrLegacyMigration: Bool?
  var spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget?
  var spicetifyRuntimeVerified: Bool?
  var spicetifyRuntimeDeferred: Bool?
  let bordersPreviousRuntime: BordersServiceInspection?
  var bordersRuntimeTarget: EnvironmentBordersRuntimeTarget?
  var bordersRuntimeAttempted: Bool?
  var bordersRuntimeVerified: Bool?

  init(
    operation: EnvironmentTransactionOperation,
    direction: EnvironmentTransactionDirection = .forward,
    standardMigration: EnvironmentStandardMigration.Intent? = nil,
    previousOwnership: EnvironmentOwnership?,
    proposedOwnership: EnvironmentOwnership?,
    previousCurrentDestination: String?,
    previousThemeGenerationID: String? = nil,
    rollbackThemeBridges: [EnvironmentThemeBridgeState.Entry] = [],
    replacementNames: EnvironmentReplacementNames = EnvironmentReplacementNames(),
    herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget? = nil,
    herdrRuntimeVerified: Bool? = nil,
    herdrLegacyMigration: Bool? = nil,
    spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget? = nil,
    spicetifyRuntimeVerified: Bool? = nil,
    spicetifyRuntimeDeferred: Bool? = nil,
    bordersPreviousRuntime: BordersServiceInspection? = nil,
    bordersRuntimeTarget: EnvironmentBordersRuntimeTarget? = nil,
    bordersRuntimeAttempted: Bool? = nil,
    bordersRuntimeVerified: Bool? = nil
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.operation = operation
    self.direction = direction
    self.standardMigration = standardMigration
    self.previousOwnership = previousOwnership
    self.proposedOwnership = proposedOwnership
    self.previousCurrentDestination = previousCurrentDestination
    self.previousThemeGenerationID = previousThemeGenerationID
    self.rollbackThemeBridges = rollbackThemeBridges
    self.replacementNames = replacementNames
    self.herdrRuntimeTarget = herdrRuntimeTarget
    self.herdrRuntimeVerified = herdrRuntimeVerified
    self.herdrLegacyMigration = herdrLegacyMigration
    self.spicetifyRuntimeTarget = spicetifyRuntimeTarget
    self.spicetifyRuntimeVerified = spicetifyRuntimeVerified
    self.spicetifyRuntimeDeferred = spicetifyRuntimeDeferred
    self.bordersPreviousRuntime = bordersPreviousRuntime
    self.bordersRuntimeTarget = bordersRuntimeTarget
    self.bordersRuntimeAttempted = bordersRuntimeAttempted
    self.bordersRuntimeVerified = bordersRuntimeVerified
  }

  var rollingBack: Self {
    // Retrying rollback must preserve completed runtime work and explicit deferral.
    if direction == .rollback { return self }
    var transaction = self
    transaction.direction = .rollback
    transaction.herdrRuntimeTarget =
      herdrLegacyMigration == true
      ? .managed
      : EnvironmentHerdrRuntimeTarget.required(from: proposedOwnership, to: previousOwnership)
    transaction.herdrRuntimeVerified = nil
    transaction.spicetifyRuntimeTarget =
      operation.isScopedConnection
      ? nil
      : EnvironmentSpicetifyRuntimeTarget.required(from: proposedOwnership, to: previousOwnership)
    transaction.spicetifyRuntimeVerified = nil
    transaction.spicetifyRuntimeDeferred = nil
    transaction.bordersRuntimeTarget =
      operation == .herdrTheme || operation.isNativeMigration || operation.isScopedConnection
      ? nil
      : EnvironmentBordersRuntimeTarget.required(from: proposedOwnership, to: previousOwnership)
    transaction.bordersRuntimeVerified = nil
    return transaction
  }

  var withHerdrRuntimeVerified: Self {
    var transaction = self
    transaction.herdrRuntimeVerified = true
    return transaction
  }

  var withSpicetifyRuntimeVerified: Self {
    var transaction = self
    transaction.spicetifyRuntimeVerified = true
    // Verification is only recorded for a runtime that was not deferred.
    transaction.spicetifyRuntimeDeferred = nil
    return transaction
  }

  /// The journal keeps one `<file>_replacement_name` member per key-owned file, so those keys
  /// are built from `EnvironmentKeyOwnedFile` rather than enumerated.
  private struct CodingKeys: CodingKey, Sendable {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static let schemaVersion = CodingKeys(stringValue: "schema_version")
    static let operation = CodingKeys(stringValue: "operation")
    static let direction = CodingKeys(stringValue: "direction")
    static let standardMigration = CodingKeys(stringValue: "standard_migration")
    static let previousOwnership = CodingKeys(stringValue: "previous_ownership")
    static let proposedOwnership = CodingKeys(stringValue: "proposed_ownership")
    static let previousCurrentDestination = CodingKeys(stringValue: "previous_current_destination")
    static let previousThemeGenerationID = CodingKeys(stringValue: "previous_theme_generation_id")
    static let rollbackThemeBridges = CodingKeys(stringValue: "rollback_theme_bridges")
    static let herdrRuntimeTarget = CodingKeys(stringValue: "herdr_runtime_target")
    static let herdrRuntimeVerified = CodingKeys(stringValue: "herdr_runtime_verified")
    static let herdrLegacyMigration = CodingKeys(stringValue: "herdr_legacy_migration")
    static let spicetifyRuntimeTarget = CodingKeys(stringValue: "spicetify_runtime_target")
    static let spicetifyRuntimeVerified = CodingKeys(stringValue: "spicetify_runtime_verified")
    static let spicetifyRuntimeDeferred = CodingKeys(stringValue: "spicetify_runtime_deferred")
    static let bordersPreviousRuntime = CodingKeys(stringValue: "borders_previous_runtime")
    static let bordersRuntimeTarget = CodingKeys(stringValue: "borders_runtime_target")
    static let bordersRuntimeAttempted = CodingKeys(stringValue: "borders_runtime_attempted")
    static let bordersRuntimeVerified = CodingKeys(stringValue: "borders_runtime_verified")

    static func replacementName(_ file: EnvironmentKeyOwnedFile) -> CodingKeys {
      CodingKeys(stringValue: "\(file.rawValue)_replacement_name")
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    operation = try container.decode(EnvironmentTransactionOperation.self, forKey: .operation)
    direction = try container.decode(EnvironmentTransactionDirection.self, forKey: .direction)
    standardMigration = try container.decodeIfPresent(
      EnvironmentStandardMigration.Intent.self, forKey: .standardMigration)
    previousOwnership = try container.decodeIfPresent(
      EnvironmentOwnership.self, forKey: .previousOwnership)
    proposedOwnership = try container.decodeIfPresent(
      EnvironmentOwnership.self, forKey: .proposedOwnership)
    previousCurrentDestination = try container.decodeIfPresent(
      String.self, forKey: .previousCurrentDestination)
    previousThemeGenerationID = try container.decodeIfPresent(
      String.self, forKey: .previousThemeGenerationID)
    rollbackThemeBridges = try container.decode(
      [EnvironmentThemeBridgeState.Entry].self, forKey: .rollbackThemeBridges)
    // Decode in the journal's historical field order: the first malformed field is the
    // reported recovery error.
    var names = [EnvironmentKeyOwnedFile: String]()
    func decodeName(_ file: EnvironmentKeyOwnedFile) throws {
      names[file] = try container.decodeIfPresent(String.self, forKey: .replacementName(file))
    }
    try decodeName(.btop)
    try decodeName(.codex)
    try decodeName(.herdr)
    herdrRuntimeTarget = try container.decodeIfPresent(
      EnvironmentHerdrRuntimeTarget.self, forKey: .herdrRuntimeTarget)
    herdrRuntimeVerified = try container.decodeIfPresent(Bool.self, forKey: .herdrRuntimeVerified)
    herdrLegacyMigration = try container.decodeIfPresent(Bool.self, forKey: .herdrLegacyMigration)
    try decodeName(.pi)
    try decodeName(.spicetify)
    spicetifyRuntimeTarget = try container.decodeIfPresent(
      EnvironmentSpicetifyRuntimeTarget.self, forKey: .spicetifyRuntimeTarget)
    spicetifyRuntimeVerified = try container.decodeIfPresent(
      Bool.self, forKey: .spicetifyRuntimeVerified)
    spicetifyRuntimeDeferred = try container.decodeIfPresent(
      Bool.self, forKey: .spicetifyRuntimeDeferred)
    try decodeName(.tuicr)
    replacementNames = EnvironmentReplacementNames(names)
    bordersPreviousRuntime = try container.decodeIfPresent(
      BordersServiceInspection.self, forKey: .bordersPreviousRuntime)
    bordersRuntimeTarget = try container.decodeIfPresent(
      EnvironmentBordersRuntimeTarget.self, forKey: .bordersRuntimeTarget)
    bordersRuntimeAttempted = try container.decodeIfPresent(
      Bool.self, forKey: .bordersRuntimeAttempted)
    bordersRuntimeVerified = try container.decodeIfPresent(
      Bool.self, forKey: .bordersRuntimeVerified)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(operation, forKey: .operation)
    try container.encode(direction, forKey: .direction)
    try container.encodeIfPresent(standardMigration, forKey: .standardMigration)
    try container.encodeIfPresent(previousOwnership, forKey: .previousOwnership)
    try container.encodeIfPresent(proposedOwnership, forKey: .proposedOwnership)
    try container.encodeIfPresent(previousCurrentDestination, forKey: .previousCurrentDestination)
    try container.encodeIfPresent(previousThemeGenerationID, forKey: .previousThemeGenerationID)
    try container.encode(rollbackThemeBridges, forKey: .rollbackThemeBridges)
    func encodeName(_ file: EnvironmentKeyOwnedFile) throws {
      try container.encodeIfPresent(replacementNames[file], forKey: .replacementName(file))
    }
    try encodeName(.btop)
    try encodeName(.codex)
    try encodeName(.herdr)
    try container.encodeIfPresent(herdrRuntimeTarget, forKey: .herdrRuntimeTarget)
    try container.encodeIfPresent(herdrRuntimeVerified, forKey: .herdrRuntimeVerified)
    try container.encodeIfPresent(herdrLegacyMigration, forKey: .herdrLegacyMigration)
    try encodeName(.pi)
    try encodeName(.spicetify)
    try container.encodeIfPresent(spicetifyRuntimeTarget, forKey: .spicetifyRuntimeTarget)
    try container.encodeIfPresent(spicetifyRuntimeVerified, forKey: .spicetifyRuntimeVerified)
    try container.encodeIfPresent(spicetifyRuntimeDeferred, forKey: .spicetifyRuntimeDeferred)
    try encodeName(.tuicr)
    try container.encodeIfPresent(bordersPreviousRuntime, forKey: .bordersPreviousRuntime)
    try container.encodeIfPresent(bordersRuntimeTarget, forKey: .bordersRuntimeTarget)
    try container.encodeIfPresent(bordersRuntimeAttempted, forKey: .bordersRuntimeAttempted)
    try container.encodeIfPresent(bordersRuntimeVerified, forKey: .bordersRuntimeVerified)
  }
}

/// The replacement file names a transaction reserves for the key-owned configuration files.
struct EnvironmentReplacementNames: Equatable, Sendable {
  private(set) var names: [EnvironmentKeyOwnedFile: String]

  init(_ names: [EnvironmentKeyOwnedFile: String] = [:]) {
    self.names = names
  }

  subscript(file: EnvironmentKeyOwnedFile) -> String? { names[file] }
}

extension EnvironmentReplacementNames {
  /// Reserves a fresh name for each key-owned file that either ownership snapshot owns.
  init(from old: EnvironmentOwnership?, to new: EnvironmentOwnership?) {
    self.init(
      Dictionary(
        uniqueKeysWithValues: EnvironmentKeyOwnedFile.allCases
          .filter { $0.isOwned(by: old) || $0.isOwned(by: new) }
          .map { ($0, Self.reserve($0.rawValue)) }))
  }

  var isEmpty: Bool { names.isEmpty }

  static func reserve(_ preset: String) -> String {
    ".macarchy-environment-\(preset)-\(UUID().uuidString.lowercased()).replacement"
  }

  /// Whether each key-owned file has a well-formed name exactly when either snapshot owns it.
  func areValid(from old: EnvironmentOwnership?, to new: EnvironmentOwnership?) -> Bool {
    EnvironmentKeyOwnedFile.allCases.allSatisfy {
      Self.isValid(
        names[$0], preset: $0.rawValue, required: $0.isOwned(by: old) || $0.isOwned(by: new))
    }
  }

  static func isValid(_ name: String?, preset: String, required: Bool) -> Bool {
    guard required else { return name == nil }
    guard let name else { return false }
    return name.hasPrefix(".macarchy-environment-\(preset)-")
      && name.hasSuffix(".replacement")
      && !name.contains("/")
      && name.utf8.count <= 128
  }
}
