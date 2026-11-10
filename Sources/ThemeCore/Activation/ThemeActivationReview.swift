import Foundation

/// When a consumer shows a new theme after activation.
package enum ThemeRepaintBoundary: String, Codable, Equatable, Sendable {
  /// Repaints running instances in place.
  case live
  /// Running instances reload through the consumer's supported reload.
  case reload
  /// The user reloads the editor window; Macarchy never invokes this action.
  case reloadWindow = "reload_window"
  case nextPrompt = "next_prompt"
  case nextInvocation = "next_invocation"
  case nextLaunch = "next_launch"
  /// Running sessions keep the old theme; new sessions use the new one.
  case freshSession = "fresh_session"
  /// Macarchy restarts the running app, which may interrupt it.
  case appRestart = "app_restart"

  package var description: String {
    switch self {
    case .live: "live"
    case .reload: "reloads"
    case .reloadWindow: "Reload Window (manual)"
    case .nextPrompt: "next prompt"
    case .nextInvocation: "next invocation"
    case .nextLaunch: "next launch"
    case .freshSession: "fresh session"
    case .appRestart: "restarts the app"
    }
  }
}

extension RuntimeAdapterKind {
  /// What activation changes for this consumer, in a few words.
  package var reviewChange: String {
    switch self {
    case .macOSAppearance: "macOS Light or Dark appearance"
    case .macOSIconStyle: "macOS icon & widget style declared by the theme"
    case .macOSAccent: "macOS accent preset nearest the theme accent"
    case .atuin: "Atuin theme"
    case .bat: "bat syntax theme"
    case .btop: "btop theme"
    case .borders: "JankyBorders window border colors"
    case .userScripts: "runs the profile’s scripts with the palette"
    case .leanFocus: "lean focus ring color"
    case .codex: "Codex TUI syntax palette"
    case .eza: "eza colors"
    case .alacritty:
      "Alacritty colors (automatic reload when enabled; first connection may require next launch)"
    case .ghostty: "Ghostty colors (live since 1.2.0; older versions reload manually)"
    case .herdrApp: "Herdr app terminal and panel palette (live)"
    case .zed: "Zed theme member and family (live)"
    case .vscode, .cursor, .vscodium, .windsurf:
      "Macarchy theme extension and default-profile color-theme settings"
    case .herdr: "Herdr theme"
    case .kitty: "Kitty colors"
    case .neovim: "Neovim colorscheme"
    case .pi: "Pi theme"
    case .sketchyBar: "SketchyBar colors"
    case .spicetify: "Spotify (Spicetify) colors"
    case .starship: "Starship prompt palette"
    case .tuicr: "tuicr palette"
    case .wallpaper: "desktop wallpaper on every display"
    case .yazi: "Yazi flavor"
    }
  }

  /// Generated files this consumer reads that another consumer's renderer writes.
  package var sharedArtifacts: [String] {
    if [.cursor, .vscodium, .windsurf].contains(self) { return VSCodeTheme.paths }
    return self == .codex ? [TextMateThemeArtifact.outputPath] : []
  }

  /// When the change shows, as the adapter's reconciliation usually delivers it; an adapter
  /// whose current ownership delivers it later reports its own boundary to the review.
  package var repaint: ThemeRepaintBoundary {
    switch self {
    case .herdrApp, .zed, .macOSAccent, .macOSIconStyle, .alacritty, .ghostty, .macOSAppearance,
      .borders,
      .leanFocus, .neovim,
      .pi,
      .sketchyBar,
      .wallpaper:
      .live
    case .btop, .herdr, .kitty, .yazi: .reload
    case .atuin, .bat, .eza, .userScripts: .nextInvocation
    case .codex, .tuicr: .freshSession
    case .spicetify: .appRestart
    case .starship: .nextPrompt
    case .vscode: .reloadWindow
    case .cursor, .vscodium, .windsurf: .nextLaunch
    }
  }
}

/// What activating a theme would do, consumer by consumer, without writing anything. `digest`
/// identifies the reviewed plan: applying with it succeeds only while the theme input, the enabled
/// consumers and the active generation are still the ones reviewed.
package struct ThemeActivationReview: Encodable, Equatable, Sendable {
  package enum Preflight: Equatable, Sendable {
    case ready
    /// Setup has not published this consumer's link; activation goes ahead and reconciliation
    /// reports the consumer as drifted.
    case notSetUp
    case failed(String)
  }

  package struct Consumer: Encodable, Equatable, Sendable {
    package let id: String
    package let requirement: AdapterRequirement
    package private(set) var change: String
    /// Generated files this consumer reads, relative to the generation.
    package private(set) var artifacts: [String]
    package let repaint: ThemeRepaintBoundary
    package let preflight: Preflight

    /// `repaint` is the boundary the adapter reports for its current ownership, when that
    /// differs from its kind's usual one.
    package init(
      entry: ConsumerCatalogEntry, preflight: Preflight, repaint: ThemeRepaintBoundary? = nil
    ) {
      guard let kind = entry.mode.runtimeKind else {
        preconditionFailure("Only runtime consumers are reviewed")
      }
      id = entry.id.rawValue
      requirement = kind.requirement
      change = kind.reviewChange
      artifacts = (entry.renderer?.artifacts.map(\.path) ?? []) + kind.sharedArtifacts
      self.repaint = repaint ?? kind.repaint
      self.preflight = preflight
    }

    /// This consumer when activation leaves it as it is, and why.
    package func unchanged(because reason: String) -> Self {
      var consumer = self
      consumer.change = reason
      consumer.artifacts = []
      return consumer
    }

    enum CodingKeys: String, CodingKey {
      case id, requirement, change, artifacts, repaint, preflight, message
    }

    package func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(requirement, forKey: .requirement)
      try container.encode(change, forKey: .change)
      try container.encode(artifacts, forKey: .artifacts)
      try container.encode(repaint, forKey: .repaint)
      switch preflight {
      case .ready:
        try container.encode("ready", forKey: .preflight)
      case .notSetUp:
        try container.encode("not_set_up", forKey: .preflight)
      case .failed(let message):
        try container.encode("failed", forKey: .preflight)
        try container.encode(message, forKey: .message)
      }
    }
  }

  package let themeID: String
  package let backgroundID: String?
  package let activeGenerationID: String?
  package let consumers: [Consumer]
  package let disabledConsumerIDs: [String]
  package let digest: String

  /// Consumers whose preflight failed; activation refuses the plan while there are any.
  package var failedConsumerIDs: [String] {
    consumers.compactMap {
      if case .failed = $0.preflight { $0.id } else { nil }
    }
  }

  package var canApply: Bool { failedConsumerIDs.isEmpty }

  /// Throws `.blocked` naming each failed consumer with its preflight message, for callers that
  /// do not show the plan itself.
  package func requireApplicable() throws {
    let failures = consumers.compactMap { consumer -> String? in
      if case .failed(let message) = consumer.preflight {
        "\(consumer.id): \(message)"
      } else {
        nil
      }
    }
    guard failures.isEmpty else { throw ThemeActivationReviewError.blocked(failures) }
  }

  package init(
    themeID: String,
    backgroundID: String?,
    activeGenerationID: String?,
    inputDigest: String,
    enabledAdapterIDs: Set<String>,
    consumers: [Consumer],
    disabledConsumerIDs: [String]
  ) throws {
    self.themeID = themeID
    self.backgroundID = backgroundID
    self.activeGenerationID = activeGenerationID
    self.consumers = consumers
    self.disabledConsumerIDs = disabledConsumerIDs
    digest = sha256Digest(
      try prettyJSONDocument(
        ReviewedInput(
          inputDigest: inputDigest,
          activeGenerationID: activeGenerationID,
          enabledAdapterIDs: enabledAdapterIDs.sorted())))
  }

  enum CodingKeys: String, CodingKey {
    case themeID = "theme_id"
    case backgroundID = "background_id"
    case activeGenerationID = "active_generation_id"
    case consumers
    case disabledConsumerIDs = "disabled_consumers"
    case digest
    case canApply = "can_apply"
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(themeID, forKey: .themeID)
    try container.encodeIfPresent(backgroundID, forKey: .backgroundID)
    try container.encodeIfPresent(activeGenerationID, forKey: .activeGenerationID)
    try container.encode(consumers, forKey: .consumers)
    try container.encode(disabledConsumerIDs, forKey: .disabledConsumerIDs)
    try container.encode(digest, forKey: .digest)
    try container.encode(canApply, forKey: .canApply)
  }

  private struct ReviewedInput: Encodable {
    let inputDigest: String
    let activeGenerationID: String?
    let enabledAdapterIDs: [String]

    enum CodingKeys: String, CodingKey {
      case inputDigest = "input_digest"
      case activeGenerationID = "active_generation_id"
      case enabledAdapterIDs = "enabled_adapter_ids"
    }
  }
}

package enum ThemeActivationReviewError: Error, CustomStringConvertible, Equatable, Sendable {
  /// The theme, its background, the enabled consumers or the active generation changed since
  /// the plan was reviewed.
  case stale
  /// The failed consumers: their IDs where the plan is shown, otherwise each with its message.
  case blocked([String])

  package var description: String {
    switch self {
    case .stale:
      "The reviewed plan no longer matches the theme, its consumers or the active generation; "
        + "review it again with --dry-run"
    case .blocked(let consumerIDs):
      "The reviewed plan cannot be applied: preflight failed for "
        + consumerIDs.joined(separator: ", ")
    }
  }
}
