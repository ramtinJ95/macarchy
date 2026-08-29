import Foundation
import ThemeCore

struct KeybindingsPlanCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> String
  let loadProfile: @Sendable (URL, Bool) throws -> KeybindingProfile
  let loadCatalog: @Sendable (URL) throws -> SkhdKeybindingCatalog
  let inspectGeneration: @Sendable (URL) -> KeybindingGenerationInspection
  let inspectProvider: @Sendable (URL) -> KeybindingProviderInspection

  static let live = KeybindingsPlanCommandRunner(
    read: readSkhdConfiguration,
    loadProfile: { try KeybindingProfileLoader().load(at: $0, required: $1) },
    loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
    inspectGeneration: { KeybindingGenerationInspector().inspect(stateRoot: $0) },
    inspectProvider: { KeybindingProviderInspector().inspect(homeDirectory: $0) }
  )

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let defaultsURL = resourcesRoot.appending(path: "defaults.skhdrc")
    let defaultMetadataURL = resourcesRoot.appending(path: "metadata.toml")
    let generation = inspectGeneration(stateRoot)
    let provider = inspectProvider(homeDirectory)
    var diagnostics: [KeybindingsPlanDiagnostic] = []

    let defaultsText: String?
    do {
      defaultsText = try read(defaultsURL)
    } catch {
      defaultsText = nil
      diagnostics.append(
        .error(
          code: "packaged_defaults_read_failed",
          source: defaultsURL,
          message: String(describing: error)
        )
      )
    }

    let defaultCatalog: SkhdKeybindingCatalog?
    do {
      let catalog = try loadCatalog(defaultMetadataURL)
      if catalog.isPresent {
        defaultCatalog = catalog
      } else {
        defaultCatalog = nil
        diagnostics.append(
          .error(
            code: "packaged_metadata_missing",
            source: defaultMetadataURL,
            message: "packaged keybinding metadata is absent"
          )
        )
      }
    } catch {
      defaultCatalog = nil
      diagnostics.append(
        .error(
          code: "packaged_metadata_invalid",
          source: defaultMetadataURL,
          message: String(describing: error)
        )
      )
    }

    let profile: KeybindingProfile?
    do {
      profile = try loadProfile(profileURL, profileRequired)
    } catch {
      profile = nil
      diagnostics.append(
        .error(
          code: "profile_invalid",
          source: profileURL,
          message: String(describing: error)
        )
      )
    }

    var overrideText: String?
    var userCatalog: SkhdKeybindingCatalog?
    if let profile {
      if let overrideURL = profile.overrideURL {
        do {
          overrideText = try read(overrideURL)
        } catch {
          diagnostics.append(
            .error(
              code: "override_read_failed",
              source: overrideURL,
              message: String(describing: error)
            )
          )
        }
      }
      if let metadataURL = profile.metadataURL {
        do {
          let catalog = try loadCatalog(metadataURL)
          if catalog.isPresent {
            userCatalog = catalog
          } else {
            diagnostics.append(
              .error(
                code: "user_metadata_missing",
                source: metadataURL,
                message: "profile-selected metadata is absent"
              )
            )
          }
        } catch {
          diagnostics.append(
            .error(
              code: "user_metadata_invalid",
              source: metadataURL,
              message: String(describing: error)
            )
          )
        }
      }
    }

    var composition: KeybindingComposition?
    if diagnostics.allSatisfy({ $0.severity != "error" }),
      let defaultsText,
      let defaultCatalog,
      let profile
    {
      let result = KeybindingComposer().compose(
        defaultsText: defaultsText,
        defaultsSource: defaultsURL,
        defaultCatalog: defaultCatalog,
        defaultMetadataSource: defaultMetadataURL,
        profile: profile,
        overrideText: overrideText,
        userCatalog: userCatalog
      )
      composition = result
      diagnostics.append(contentsOf: result.diagnostics.map(KeybindingsPlanDiagnostic.init))
    }

    if generation.status == .invalid {
      diagnostics.append(
        .error(
          code: "current_generation_invalid",
          source: stateRoot.appending(path: "keybindings/current"),
          message: generation.message ?? "current keybinding generation is invalid"
        )
      )
    }
    if provider.status == .blocked {
      diagnostics.append(
        .error(
          code: "provider_entry_blocked",
          source: URL(filePath: provider.entryPoint),
          message: provider.message
        )
      )
    }

    let rendered = composition?.renderedConfiguration
    let renderedDigest = composition?.renderedDigest
    let proposedInputDigest = rendered.map {
      sha256Digest(
        Data("renderer_version=\(KeybindingComposer.rendererVersion)\n\($0)".utf8)
      )
    }
    let actions = plannedActions(
      generation: generation,
      provider: provider,
      renderedDigest: renderedDigest,
      isBlocked: diagnostics.contains { $0.severity == "error" }
    )
    let outcome: String
    if diagnostics.contains(where: { $0.severity == "error" }) {
      outcome = "blocked"
    } else if actions.isEmpty {
      outcome = "no_change"
    } else {
      outcome = "ready"
    }

    let profileStatus: String
    if profile?.sourceURL != nil {
      profileStatus = "loaded"
    } else if profile == nil {
      profileStatus = "invalid"
    } else {
      profileStatus = "absent_default"
    }
    let report = KeybindingsPlanReport(
      outcome: outcome,
      sources: KeybindingsPlanSources(
        defaults: defaultsURL.path,
        defaultMetadata: defaultMetadataURL.path,
        profile: profileURL.path,
        profileStatus: profileStatus,
        override: profile?.overrideURL?.path,
        userMetadata: profile?.metadataURL?.path
      ),
      summary: KeybindingsPlanSummary(composition),
      bindings: composition?.bindings.map(KeybindingsPlanBinding.init) ?? [],
      disabledDefaults: composition?.disabledDefaults.map(KeybindingsPlanDisabled.init) ?? [],
      renderedSkhdrc: rendered,
      renderedDigest: renderedDigest,
      proposedInputDigest: proposedInputDigest,
      generation: KeybindingsPlanGeneration(generation),
      provider: provider,
      actions: actions,
      diagnostics: diagnostics.sorted(by: KeybindingsPlanDiagnostic.order)
    )
    return (try report.render(json: json), outcome != "blocked")
  }

  private func plannedActions(
    generation: KeybindingGenerationInspection,
    provider: KeybindingProviderInspection,
    renderedDigest: String?,
    isBlocked: Bool
  ) -> [KeybindingsPlanAction] {
    guard !isBlocked, let renderedDigest else { return [] }
    var actions: [KeybindingsPlanAction] = []
    if generation.status == .missing || generation.renderedDigest != renderedDigest {
      actions.append(
        KeybindingsPlanAction(
          id: "publish_generation",
          message: generation.status == .missing
            ? "Publish the first immutable keybinding generation."
            : "Publish a replacement immutable keybinding generation."
        )
      )
    }
    switch provider.status {
    case .managed:
      break
    case .installRequired:
      actions.append(
        KeybindingsPlanAction(
          id: "install_provider_entry",
          message: "Install the managed skhd entry-point link."
        )
      )
    case .adoptionRequired:
      actions.append(
        KeybindingsPlanAction(
          id: provider.ownership == "directory_symlink"
            ? "adopt_skhd_directory_symlink"
            : "adopt_provider_entry",
          message: "Adopt the existing \(provider.ownership) after explicit approval."
        )
      )
    case .blocked:
      break
    }
    return actions
  }
}

private struct KeybindingsPlanReport: Encodable {
  let schemaVersion = 1
  let operation = "keybindings_plan"
  let outcome: String
  let mutated = false
  let sources: KeybindingsPlanSources
  let summary: KeybindingsPlanSummary
  let bindings: [KeybindingsPlanBinding]
  let disabledDefaults: [KeybindingsPlanDisabled]
  let renderedSkhdrc: String?
  let renderedDigest: String?
  let proposedInputDigest: String?
  let generation: KeybindingsPlanGeneration
  let provider: KeybindingProviderInspection
  let actions: [KeybindingsPlanAction]
  let diagnostics: [KeybindingsPlanDiagnostic]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }

    var lines = [
      "Macarchy keybindings plan [\(outcome)]:",
      "- profile [\(sources.profileStatus)]: \(sources.profile)",
      "- effective bindings: \(summary.effective)",
      "- packaged defaults: \(summary.packagedDefaults)",
      "- user replacements: \(summary.userReplacements)",
      "- user additions: \(summary.userAdditions)",
      "- disabled defaults: \(summary.disabledDefaults)",
      "- generation [\(generation.status)]: \(generation.message)",
      "- provider [\(provider.status.rawValue), \(provider.ownership)]: \(provider.message)",
    ]
    if !bindings.isEmpty {
      lines.append("Effective bindings:")
      lines.append(
        contentsOf: bindings.map { binding in
          let metadata = binding.metadataSource.map { ", metadata=\($0)" } ?? ""
          return "- \(binding.identity) [\(binding.commandSource)\(metadata)]: \(binding.command)"
        })
    }
    if !disabledDefaults.isEmpty {
      lines.append("Disabled packaged defaults:")
      lines.append(contentsOf: disabledDefaults.map { "- \($0.identity): \($0.command)" })
    }
    if actions.isEmpty {
      lines.append("Actions: none")
    } else {
      lines.append("Actions:")
      lines.append(contentsOf: actions.map { "- \($0.id): \($0.message)" })
    }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines.append(
        contentsOf: diagnostics.map { diagnostic in
          let location =
            diagnostic.line.map { "\(diagnostic.source):\($0)" }
            ?? diagnostic.source
          return "- \(location): \(diagnostic.severity) [\(diagnostic.code)]: \(diagnostic.message)"
        })
    }
    lines.append("No changes made.")
    return lines.joined(separator: "\n")
  }
}

private struct KeybindingsPlanSources: Encodable {
  let defaults: String
  let defaultMetadata: String
  let profile: String
  let profileStatus: String
  let override: String?
  let userMetadata: String?
}

private struct KeybindingsPlanSummary: Encodable {
  let effective: Int
  let packagedDefaults: Int
  let userReplacements: Int
  let userAdditions: Int
  let disabledDefaults: Int

  init(_ composition: KeybindingComposition?) {
    let bindings = composition?.bindings ?? []
    effective = bindings.count
    packagedDefaults =
      bindings.count {
        $0.commandSource == .packagedDefault || $0.commandSource == .userReplacement
      } + (composition?.disabledDefaults.count ?? 0)
    userReplacements = bindings.count { $0.commandSource == .userReplacement }
    userAdditions = bindings.count { $0.commandSource == .userAddition }
    disabledDefaults = composition?.disabledDefaults.count ?? 0
  }
}

private struct KeybindingsPlanBinding: Encodable {
  let identity: String
  let chord: String
  let command: String
  let commandSource: String
  let metadataSource: String?
  let metadata: KeybindingsPlanMetadata?

  init(_ effective: EffectiveKeybinding) {
    identity = effective.binding.identity
    chord = effective.binding.chord
    command = effective.binding.command
    commandSource = effective.commandSource.rawValue
    metadataSource = effective.metadataSource?.rawValue
    metadata = effective.metadata.map(KeybindingsPlanMetadata.init)
  }
}

private struct KeybindingsPlanMetadata: Encodable {
  let label: String
  let category: String
  let order: Int
  let aliases: [String]

  init(_ entry: SkhdCatalogEntry) {
    label = entry.label
    category = entry.category
    order = entry.order
    aliases = entry.aliases
  }
}

private struct KeybindingsPlanDisabled: Encodable {
  let identity: String
  let chord: String
  let command: String
  let label: String

  init(_ disabled: DisabledPackagedKeybinding) {
    identity = disabled.binding.identity
    chord = disabled.binding.chord
    command = disabled.binding.command
    label = disabled.metadata.label
  }
}

private struct KeybindingsPlanGeneration: Encodable {
  let status: String
  let generationID: String?
  let currentRenderedDigest: String?
  let message: String

  init(_ inspection: KeybindingGenerationInspection) {
    status = inspection.status.rawValue
    generationID = inspection.generationID
    currentRenderedDigest = inspection.renderedDigest
    switch inspection.status {
    case .missing:
      message = "no current keybinding generation"
    case .current:
      message = "current generation \(inspection.generationID ?? "unknown") is valid"
    case .invalid:
      message = inspection.message ?? "current generation is invalid"
    }
  }
}

private struct KeybindingsPlanAction: Encodable {
  let id: String
  let message: String
}

private struct KeybindingsPlanDiagnostic: Encodable {
  let code: String
  let severity: String
  let source: String
  let line: Int?
  let relatedLine: Int?
  let identity: String?
  let message: String

  private init(
    code: String,
    severity: String,
    source: String,
    line: Int?,
    relatedLine: Int?,
    identity: String?,
    message: String
  ) {
    self.code = code
    self.severity = severity
    self.source = source
    self.line = line
    self.relatedLine = relatedLine
    self.identity = identity
    self.message = message
  }

  init(_ diagnostic: KeybindingCompositionDiagnostic) {
    self.init(
      code: diagnostic.code,
      severity: diagnostic.severity.rawValue,
      source: diagnostic.source,
      line: diagnostic.line,
      relatedLine: diagnostic.relatedLine,
      identity: diagnostic.identity,
      message: diagnostic.message
    )
  }

  static func error(code: String, source: URL, message: String) -> Self {
    KeybindingsPlanDiagnostic(
      code: code,
      severity: "error",
      source: source.path,
      line: nil,
      relatedLine: nil,
      identity: nil,
      message: message
    )
  }

  static func order(_ lhs: Self, _ rhs: Self) -> Bool {
    (lhs.severity, lhs.source, lhs.line ?? 0, lhs.code, lhs.identity ?? "")
      < (rhs.severity, rhs.source, rhs.line ?? 0, rhs.code, rhs.identity ?? "")
  }
}
