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
  let btopReplacementName: String?
  let codexReplacementName: String?
  let herdrReplacementName: String?
  var herdrRuntimeTarget: EnvironmentHerdrRuntimeTarget?
  var herdrRuntimeVerified: Bool?
  let herdrLegacyMigration: Bool?
  let piReplacementName: String?
  let spicetifyReplacementName: String?
  var spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget?
  var spicetifyRuntimeVerified: Bool?
  var spicetifyRuntimeDeferred: Bool?
  let tuicrReplacementName: String?
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
    spicetifyRuntimeDeferred: Bool? = nil,
    tuicrReplacementName: String? = nil,
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
    self.spicetifyRuntimeDeferred = spicetifyRuntimeDeferred
    self.tuicrReplacementName = tuicrReplacementName
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

  var replacementNames: EnvironmentReplacementNames {
    EnvironmentReplacementNames(
      btop: btopReplacementName,
      codex: codexReplacementName,
      herdr: herdrReplacementName,
      pi: piReplacementName,
      spicetify: spicetifyReplacementName,
      tuicr: tuicrReplacementName
    )
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

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, direction
    case standardMigration = "standard_migration"
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
    case spicetifyRuntimeDeferred = "spicetify_runtime_deferred"
    case tuicrReplacementName = "tuicr_replacement_name"
    case bordersPreviousRuntime = "borders_previous_runtime"
    case bordersRuntimeTarget = "borders_runtime_target"
    case bordersRuntimeAttempted = "borders_runtime_attempted"
    case bordersRuntimeVerified = "borders_runtime_verified"
  }
}

/// The replacement file names a transaction reserves for the presets' key-owned files.
struct EnvironmentReplacementNames: Equatable, Sendable {
  var btop: String? = nil
  var codex: String? = nil
  var herdr: String? = nil
  var pi: String? = nil
  var spicetify: String? = nil
  var tuicr: String? = nil
}

extension EnvironmentReplacementNames {
  /// Reserves a fresh name for each preset file that either ownership snapshot owns.
  init(from old: EnvironmentOwnership?, to new: EnvironmentOwnership?) {
    func reserve(_ preset: String, _ owned: Bool) -> String? {
      owned ? Self.reserve(preset) : nil
    }
    self.init(
      btop: reserve("btop", old?.btop != nil || new?.btop != nil),
      codex: reserve("codex", old?.codex != nil || new?.codex != nil),
      herdr: reserve("herdr", old?.herdr != nil || new?.herdr != nil),
      pi: reserve("pi", old?.pi != nil || new?.pi != nil),
      spicetify: reserve("spicetify", old?.spicetify != nil || new?.spicetify != nil),
      tuicr: reserve("tuicr", old?.tuicr != nil || new?.tuicr != nil)
    )
  }

  var isEmpty: Bool { self == Self() }

  static func reserve(_ preset: String) -> String {
    ".macarchy-environment-\(preset)-\(UUID().uuidString.lowercased()).replacement"
  }

  /// Whether each preset has a well-formed name exactly when either snapshot owns its file.
  func areValid(from old: EnvironmentOwnership?, to new: EnvironmentOwnership?) -> Bool {
    Self.isValid(btop, preset: "btop", required: old?.btop != nil || new?.btop != nil)
      && Self.isValid(codex, preset: "codex", required: old?.codex != nil || new?.codex != nil)
      && Self.isValid(herdr, preset: "herdr", required: old?.herdr != nil || new?.herdr != nil)
      && Self.isValid(pi, preset: "pi", required: old?.pi != nil || new?.pi != nil)
      && Self.isValid(
        spicetify, preset: "spicetify", required: old?.spicetify != nil || new?.spicetify != nil)
      && Self.isValid(tuicr, preset: "tuicr", required: old?.tuicr != nil || new?.tuicr != nil)
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
