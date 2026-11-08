import Foundation
import ThemeCore

// Closed per-tool and per-preset declarations. ADR-0099/0089/0104 rule out a generic provider
// framework, so these are plain tables: each fact the lifecycle, journal, inspection, plan and
// status otherwise restated per tool or preset is declared once here, and each tool or preset's
// genuinely unique behavior stays in its own code. Where output order is part of a contract,
// the caller keeps that order explicitly.

/// A daily tool the environment configures, in profile-key order.
enum EnvironmentDailyTool: String, CaseIterable, Sendable {
  case bat
  case eza
  case btop
  case yazi

  func isEnabled(in tools: DailyToolsProfile) -> Bool {
    switch self {
    case .bat: tools.bat
    case .eza: tools.eza
    case .btop: tools.btop
    case .yazi: tools.yazi
    }
  }

  var adapterID: String {
    switch self {
    case .bat: RuntimeAdapterKind.bat.adapterID
    case .eza: RuntimeAdapterKind.eza.adapterID
    case .btop: RuntimeAdapterKind.btop.adapterID
    case .yazi: RuntimeAdapterKind.yazi.adapterID
    }
  }

  /// The provider entries the tool links while enabled.
  var entryIDs: [EnvironmentEntryID] {
    switch self {
    case .bat: [.batConfiguration, .batTheme]
    case .eza: [.ezaTheme]
    case .btop: [.btopTheme]
    case .yazi: [.yaziConfiguration, .yaziThemeSelection, .yaziFlavor, .yaziSyntax]
    }
  }

  /// Setup-owned records that must be torn down before the environment adopts the tool.
  var legacySetupIDs: [String] {
    switch self {
    case .bat: ["bat.selector", "bat.theme-link"]
    case .eza: ["eza.environment", "eza.theme-link"]
    case .btop: ["btop.selector", "btop.theme-link"]
    case .yazi: ["yazi.selector", "yazi.flavor-link", "yazi.syntax-link"]
    }
  }

  var planAction: EnvironmentPlanAction {
    switch self {
    case .bat:
      EnvironmentPlanAction(
        id: "configure_bat", message: "Configure bat behavior and its canonical theme seam.")
    case .eza:
      EnvironmentPlanAction(
        id: "configure_eza", message: "Configure eza shell behavior and its canonical theme seam.")
    case .btop:
      EnvironmentPlanAction(
        id: "configure_btop",
        message: "Configure btop while preserving its provider-writable state.")
    case .yazi:
      EnvironmentPlanAction(
        id: "configure_yazi",
        message: "Configure Yazi behavior and its generated flavor seams.")
    }
  }
}

/// An application preset, in profile-key order.
enum EnvironmentPreset: String, CaseIterable, Sendable {
  case codex
  case herdr
  case pi
  case slack
  case spicetify
  case tuicr

  func isEnabled(in presets: PresetsProfile) -> Bool {
    switch self {
    case .codex: presets.codex
    case .herdr: presets.herdr
    case .pi: presets.pi
    case .slack: presets.slack
    case .spicetify: presets.spicetify
    case .tuicr: presets.tuicr
    }
  }

  /// Whether the applied ownership recorded the preset as enabled.
  func isEnabled(in ownership: EnvironmentOwnership) -> Bool {
    switch self {
    case .codex: ownership.codexEnabled
    case .herdr: ownership.herdrEnabled
    case .pi: ownership.piEnabled
    case .slack: ownership.slackEnabled
    case .spicetify: ownership.spicetifyEnabled
    case .tuicr: ownership.tuicrEnabled
    }
  }

  /// The theme adapter the preset enables; Slack is a manual-import consumer without one.
  var adapterID: String? {
    switch self {
    case .codex: CodexAdapter.id
    case .herdr: HerdrAdapter.id
    case .pi: PiAdapter.id
    case .slack: nil
    case .spicetify: SpicetifyAdapter.id
    case .tuicr: TuicrAdapter.id
    }
  }

  var planAction: EnvironmentPlanAction {
    switch self {
    case .codex:
      EnvironmentPlanAction(
        id: "configure_codex",
        message: "Configure Codex CLI's [tui].theme selector and canonical TextMate theme link."
      )
    case .herdr:
      EnvironmentPlanAction(
        id: "configure_herdr",
        message: "Configure Herdr's [theme] selector and 19-key [theme.custom] surface."
      )
    case .pi:
      EnvironmentPlanAction(
        id: "configure_pi",
        message: "Configure Pi's root theme member and watched canonical theme link."
      )
    case .slack:
      EnvironmentPlanAction(
        id: "publish_slack_manual_import",
        message:
          "Publish Slack manual-import authority and the exact per-workspace action: \(SlackAdapter.importInstructions)"
      )
    case .spicetify:
      EnvironmentPlanAction(
        id: "configure_spicetify",
        message:
          "Own only ordinary current_theme/color_scheme selectors or accept a complete exact Stow tuple, create only an absent color.ini link, and run an awaited --no-restart refresh."
      )
    case .tuicr:
      EnvironmentPlanAction(
        id: "configure_tuicr",
        message: "Configure tuicr's root theme selector and canonical palette and syntax links."
      )
    }
  }
}

/// A preset whose key-owned selector points at canonical theme links. Such a preset may still be
/// legacy setup-owned, or left as an exact external tuple of selector and links.
enum EnvironmentLinkedPreset: CaseIterable, Sendable {
  case codex
  case pi
  case spicetify
  case tuicr

  var preset: EnvironmentPreset {
    switch self {
    case .codex: .codex
    case .pi: .pi
    case .spicetify: .spicetify
    case .tuicr: .tuicr
    }
  }

  var file: EnvironmentKeyOwnedFile {
    switch self {
    case .codex: .codex
    case .pi: .pi
    case .spicetify: .spicetify
    case .tuicr: .tuicr
    }
  }

  /// The canonical theme links the selector points at.
  var themeLinks: [EnvironmentEntryID] {
    switch self {
    case .codex: [.codexTheme]
    case .pi: [.piTheme]
    case .spicetify: [.spicetifyColor]
    case .tuicr: [.tuicrTheme, .tuicrSyntax]
    }
  }

  /// The preset's name in legacy-integration errors and its legacy setup-owned records.
  var legacyIntegration: (name: String, setupIDs: Set<String>) {
    switch self {
    case .codex:
      (
        name: "Codex",
        setupIDs: Set([
          SetupOwnershipManager.codexSelectorID, SetupOwnershipManager.codexThemeLinkID,
        ])
      )
    case .pi:
      (
        name: "Pi",
        setupIDs: Set([SetupOwnershipManager.piSelectorID, SetupOwnershipManager.piThemeLinkID])
      )
    case .spicetify:
      (
        name: "Spicetify",
        setupIDs: Set([
          SetupOwnershipManager.spicetifySelectorsID, SetupOwnershipManager.spicetifyColorLinkID,
        ])
      )
    case .tuicr:
      (
        name: "tuicr",
        setupIDs: Set([
          SetupOwnershipManager.tuicrSelectorID,
          SetupOwnershipManager.tuicrThemeLinkID,
          SetupOwnershipManager.tuicrSyntaxLinkID,
        ])
      )
    }
  }

  /// Whether the preset's complete legacy setup integration is still installed; throws when it
  /// is only partly present.
  func hasCompleteLegacyIntegration(setupIDs: Set<String>) throws -> Bool {
    try EnvironmentLegacyIntegration.hasCompleteLegacyIntegration(
      named: legacyIntegration.name, requiredIDs: legacyIntegration.setupIDs, setupIDs: setupIDs)
  }
}

/// A configuration file a daily tool or preset edits by key through a journaled replacement,
/// in the order the lifecycle validates, revalidates, transitions and preflights them.
enum EnvironmentKeyOwnedFile: String, CaseIterable, Sendable {
  case btop
  case codex
  case herdr
  case pi
  case spicetify
  case tuicr

  /// The linked preset whose enablement and external tuple also govern the file.
  var linkedPreset: EnvironmentLinkedPreset? {
    switch self {
    case .btop, .herdr: nil
    case .codex: .codex
    case .pi: .pi
    case .spicetify: .spicetify
    case .tuicr: .tuicr
    }
  }

  /// Names the file's owner in lifecycle errors.
  var label: String {
    switch self {
    case .btop: "btop"
    case .codex: "Codex"
    case .herdr: "Herdr"
    case .pi: "Pi"
    case .spicetify: "Spicetify"
    case .tuicr: "tuicr"
    }
  }

  /// The configuration file, relative to the home directory.
  var configurationPath: String {
    switch self {
    case .btop: ConsumerHomePath.btopConfiguration
    case .codex: ConsumerHomePath.codexConfiguration
    case .herdr: ConsumerHomePath.herdrConfiguration
    case .pi: ConsumerHomePath.piSettings
    case .spicetify: ConsumerHomePath.spicetifyConfiguration
    case .tuicr: ConsumerHomePath.tuicrConfiguration
    }
  }

  /// The inspection entry and adoption-digest ID of the configuration file.
  var entryID: String {
    switch self {
    case .btop: EnvironmentEntryID.btopConfiguration.rawValue
    case .codex: EnvironmentEntryID.codexConfiguration.rawValue
    case .herdr: "herdr_configuration"
    case .pi: EnvironmentEntryID.piConfiguration.rawValue
    case .spicetify: "spicetify_configuration"
    case .tuicr: EnvironmentEntryID.tuicrConfiguration.rawValue
    }
  }

  /// How the adoption digest qualifies the owned path: btop's file stays provider-writable.
  var adoptionTargetPrefix: String { self == .btop ? "provider-writable:" : "key-owned:" }

  /// Names what apply revalidates against its planned evidence.
  var revalidationLabel: String {
    switch self {
    case .btop: "btop configuration"
    case .codex: "Codex external tuple"
    case .herdr: "Herdr configuration"
    case .pi: "Pi settings"
    case .spicetify: "Spicetify external tuple"
    case .tuicr: "tuicr configuration"
    }
  }

  /// Codex and Spicetify also revalidate their exact external tuple unless apply adopts the file.
  var revalidatesExternalTuple: Bool { self == .codex || self == .spicetify }

  /// btop moves only after the provider links; a preset's previously owned file moves before them.
  var transitionsBeforeLinks: Bool { self != .btop }

  /// The path `ownership` records for the file, or nil when it does not own it.
  func ownedPath(in ownership: EnvironmentOwnership?) -> String? {
    switch self {
    case .btop: ownership?.btop?.path
    case .codex: ownership?.codex?.path
    case .herdr: ownership?.herdr?.path
    case .pi: ownership?.pi?.path
    case .spicetify: ownership?.spicetify?.path
    case .tuicr: ownership?.tuicr?.path
    }
  }

  func isOwned(by ownership: EnvironmentOwnership?) -> Bool { ownedPath(in: ownership) != nil }
}

/// What the inspection of a linked preset's selector file reports. Each preset keeps its wording.
struct EnvironmentLinkedSelectorWording: Sendable {
  let legacyDrift: String
  let legacyPreserved: String
  /// Names the theme links in a legacy setup-owned link's inspection.
  let legacyLink: String
  let managed: String
  let restored: String
  let drifted: String
  let externalTupleExact: String
}

extension EnvironmentLinkedPreset {
  var inspectionWording: EnvironmentLinkedSelectorWording {
    switch self {
    case .codex:
      EnvironmentLinkedSelectorWording(
        legacyDrift: "legacy setup-owned Codex selector",
        legacyPreserved: "The working legacy setup-owned Codex integration is preserved.",
        legacyLink: "Codex theme link",
        managed: "The Codex [tui].theme key is managed.",
        restored: "The disabled Codex [tui].theme key will be restored.",
        drifted: "The owned Codex [tui].theme key drifted.",
        externalTupleExact: "The exact Codex tuple remains externally owned until disablement.")
    case .pi:
      EnvironmentLinkedSelectorWording(
        legacyDrift: "legacy setup-owned Pi selector",
        legacyPreserved: "The working legacy setup-owned Pi integration is preserved.",
        legacyLink: "Pi link",
        managed: "The Pi theme member is managed.",
        restored: "The disabled Pi theme member will be restored.",
        drifted: "The owned Pi theme member drifted.",
        externalTupleExact: "The exact Pi tuple remains externally owned until disablement.")
    case .spicetify:
      EnvironmentLinkedSelectorWording(
        legacyDrift: "legacy setup-owned Spicetify selectors",
        legacyPreserved: "The working legacy setup-owned Spicetify selector tuple is preserved.",
        legacyLink: "Spicetify color link",
        managed: "The Spicetify current_theme and color_scheme selectors are managed.",
        restored: "The disabled Spicetify selectors will be restored exactly.",
        drifted: "The owned Spicetify selectors drifted.",
        externalTupleExact:
          "The exact Spicetify selector and color-link tuple remains externally owned.")
    case .tuicr:
      EnvironmentLinkedSelectorWording(
        legacyDrift: "legacy setup-owned tuicr selector",
        legacyPreserved: "The working legacy setup-owned tuicr integration is preserved.",
        legacyLink: "tuicr link",
        managed: "The tuicr theme key is managed.",
        restored: "The disabled tuicr theme key will be restored.",
        drifted: "The owned tuicr theme key drifted.",
        externalTupleExact: "The exact tuicr tuple remains externally owned until disablement.")
    }
  }
}

/// How inspection reads, judges and adopts a Codex, Pi or tuicr selector file Macarchy does not
/// own yet. Spicetify adopts only an ordinary file and never installs one, so it keeps its own
/// rule in `inspectSpicetify`.
struct EnvironmentSelectorDocument<Ownership: EnvironmentPresetFileOwnership> {
  /// Text selectors must decode as UTF-8 before their document rules apply.
  let isText: Bool
  let linksRequired: String
  let linkedExact: String
  let selectorExact: String
  let adoption: String
  let installation: String
  let unsupported: String
  let adopting: (Data, URL) throws -> Ownership
  let installing: (URL) -> Ownership
}

extension EnvironmentSelectorDocument where Ownership == EnvironmentCodexOwnership {
  static var codex: Self {
    Self(
      isText: true,
      linksRequired: "The externally owned Codex selector requires the exact theme link.",
      linkedExact: "The exact Codex selector and theme link remain externally owned.",
      selectorExact: "The exact Codex [tui].theme key remains externally owned.",
      adoption: "The existing Codex [tui].theme key requires reviewed adoption.",
      installation: "Minimal Codex [tui].theme configuration will be installed.",
      unsupported: "The Codex configuration cannot be safely adopted.",
      adopting: { data, url in
        try EnvironmentCodexDocument.ownership(
          for: Ownership.filesystem.utf8(data, at: url), source: url)
      },
      installing: { url in
        EnvironmentCodexOwnership(
          path: url.path,
          originalFileExisted: false,
          originalSelector: nil,
          introducedTable: true,
          insertedSeparatorBeforeTable: false,
          insertedSeparatorAfterTable: false
        )
      })
  }
}

extension EnvironmentSelectorDocument where Ownership == EnvironmentPiOwnership {
  static var pi: Self {
    Self(
      isText: false,
      linksRequired: "The externally owned Pi selector requires the exact watched theme link.",
      linkedExact: "The exact Pi selector and watched theme link remain externally owned.",
      selectorExact: "The exact Pi theme member remains externally owned.",
      adoption: "The existing Pi theme member requires reviewed adoption.",
      installation: "Minimal Pi settings containing only the theme member will be installed.",
      unsupported: "Pi settings cannot be safely adopted.",
      adopting: { data, url in try EnvironmentPiDocument.ownership(for: data, source: url) },
      installing: { url in
        EnvironmentPiOwnership(path: url.path, originalFileExisted: false, originalMember: nil)
      })
  }
}

extension EnvironmentSelectorDocument where Ownership == EnvironmentTuicrOwnership {
  static var tuicr: Self {
    Self(
      isText: true,
      linksRequired: "The externally owned tuicr selector requires both exact canonical links.",
      linkedExact: "The exact tuicr selector and canonical links remain externally owned.",
      selectorExact: "The exact tuicr theme key remains externally owned.",
      adoption: "The existing tuicr theme key requires reviewed adoption.",
      installation: "The minimal tuicr theme selector will be installed.",
      unsupported: "The tuicr configuration cannot be safely adopted.",
      adopting: { data, url in
        try EnvironmentTuicrDocument.ownership(
          for: Ownership.filesystem.utf8(data, at: url), source: url)
      },
      installing: { url in
        EnvironmentTuicrOwnership(
          path: url.path,
          originalFileExisted: false,
          originalSelector: nil,
          insertedSeparatorBefore: false
        )
      })
  }
}
