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
        : EnvironmentHerdrRuntimeTarget.required(
          from: proposedOwnership,
          to: previousOwnership
        ),
      herdrRuntimeVerified: nil,
      herdrLegacyMigration: herdrLegacyMigration,
      piReplacementName: piReplacementName,
      spicetifyReplacementName: spicetifyReplacementName,
      spicetifyRuntimeTarget: EnvironmentSpicetifyRuntimeTarget.required(
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
