import Foundation
import ThemeCore

struct KeybindingsPlanCommandRunner: Sendable {
  let effectiveInspector: KeybindingEffectiveBehaviorInspector

  static let live = KeybindingsPlanCommandRunner(effectiveInspector: .live)

  func execute(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let preparation = try prepare(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      ignoreTransaction: false
    )
    return (
      try preparation.report.render(json: json),
      preparation.outcome != "blocked"
    )
  }

  func prepare(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    ignoreTransaction: Bool = false,
    effectiveBehavior suppliedBehavior: KeybindingEffectiveBehavior? = nil,
    profile: PortableProfile? = nil,
    requireRunningProcess: Bool = true
  ) throws -> KeybindingsPlanPreparation {
    let effectiveState =
      suppliedBehavior
      ?? effectiveInspector.inspect(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory,
        ignoreTransaction: ignoreTransaction,
        profile: profile
      )
    let effectiveConfiguration = effectiveState.configuration
    let generation = effectiveState.generation
    let provider = effectiveState.provider
    var diagnostics = effectiveConfiguration.diagnostics.map(KeybindingsPlanDiagnostic.init)
    if !ignoreTransaction {
      switch effectiveState.transaction.status {
      case .pending:
        if let transaction = effectiveState.transaction.pendingTransaction {
          diagnostics.append(
            .error(
              code: "keybinding_recovery_required",
              source: stateRoot.appending(path: "keybindings/transaction.json"),
              message: "interrupted \(transaction.operation.rawValue) transaction is in "
                + "phase \(transaction.phase.rawValue)"
            )
          )
        }
      case .invalid:
        diagnostics.append(
          .error(
            code: "keybinding_transaction_invalid",
            source: stateRoot.appending(path: "keybindings/transaction.json"),
            message: effectiveState.transaction.message
          )
        )
      case .clear:
        break
      }
    }

    let composition = effectiveConfiguration.composition

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
    if requireRunningProcess, provider.status != .blocked {
      switch effectiveState.process.status {
      case .running:
        break
      case .notRunning, .unsupported, .unavailable:
        diagnostics.append(
          .error(
            code: "skhd_process_prerequisite",
            source: URL(filePath: provider.entryPoint),
            message: effectiveState.process.message
          )
        )
      }
    }
    if provider.status == .managed {
      if effectiveState.lifecycleEvidence.status == .invalid {
        diagnostics.append(
          .error(
            code: "skhd_lifecycle_evidence_invalid",
            source: stateRoot.appending(path: "keybindings/lifecycle.json"),
            message: effectiveState.lifecycleEvidence.message
          )
        )
      }
    }

    let adoptionDelta = adoptionDelta(
      provider: provider,
      composition: composition,
      diagnostics: &diagnostics
    )

    let rendered = composition?.renderedConfiguration
    let renderedDigest = composition?.renderedDigest
    let proposedInputDigest = composition?.inputDigest
    let actions = plannedActions(
      generation: generation,
      provider: provider,
      lifecycleEvidence: effectiveState.lifecycleEvidence,
      renderedDigest: renderedDigest,
      inputDigest: proposedInputDigest,
      isBlocked: diagnostics.contains { $0.severity == "error" }
    )
    let outcome: String
    if diagnostics.contains(where: { $0.severity == "error" }) {
      outcome = "blocked"
    } else if effectiveState.status == .converged, actions.isEmpty {
      outcome = "no_change"
    } else {
      outcome = "ready"
    }

    let sources = effectiveConfiguration.sources
    let report = KeybindingsPlanReport(
      outcome: outcome,
      sources: KeybindingsPlanSources(
        defaults: sources.defaultsURL.path,
        defaultMetadata: sources.defaultMetadataURL.path,
        profile: sources.profileURL.path,
        profileStatus: sources.profileStatus,
        override: sources.overrideURL?.path,
        userMetadata: sources.userMetadataURL?.path
      ),
      summary: KeybindingsPlanSummary(composition),
      bindings: composition?.bindings.map(KeybindingsPlanBinding.init) ?? [],
      disabledDefaults: composition?.disabledDefaults.map(KeybindingsPlanDisabled.init) ?? [],
      renderedSkhdrc: rendered,
      renderedDigest: renderedDigest,
      proposedInputDigest: proposedInputDigest,
      generation: KeybindingsPlanGeneration(generation),
      generationAgreement: effectiveState.generationAgreement.rawValue,
      provider: provider,
      effectiveStatus: effectiveState.status,
      effectiveStatusMessage: effectiveState.statusMessage,
      transaction: effectiveState.transaction,
      process: effectiveState.process,
      lifecycleEvidence: effectiveState.lifecycleEvidence,
      adoptionDelta: adoptionDelta,
      actions: actions,
      diagnostics: diagnostics.sorted(by: KeybindingsPlanDiagnostic.order)
    )
    return KeybindingsPlanPreparation(
      outcome: outcome,
      effectiveBehavior: effectiveState,
      composition: composition,
      generation: generation,
      provider: provider,
      blockingMessages: diagnostics.filter { $0.severity == "error" }.map(\.message),
      report: report
    )
  }

  private func plannedActions(
    generation: KeybindingGenerationInspection,
    provider: KeybindingProviderInspection,
    lifecycleEvidence: KeybindingLifecycleEvidenceInspection,
    renderedDigest: String?,
    inputDigest: String?,
    isBlocked: Bool
  ) -> [KeybindingsPlanAction] {
    guard !isBlocked, let renderedDigest, let inputDigest else { return [] }
    var actions: [KeybindingsPlanAction] = []
    if generation.status == .missing
      || generation.renderedDigest != renderedDigest
      || generation.inputDigest != inputDigest
    {
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
      if generation.status == .current,
        generation.renderedDigest == renderedDigest,
        generation.inputDigest == inputDigest,
        lifecycleEvidence.status != .matched
      {
        actions.append(
          KeybindingsPlanAction(
            id: "reload_provider",
            message: "Reload skhd and record lifecycle success for the current generation."
          )
        )
      }
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

  private func adoptionDelta(
    provider: KeybindingProviderInspection,
    composition: KeybindingComposition?,
    diagnostics: inout [KeybindingsPlanDiagnostic]
  ) -> KeybindingsAdoptionDelta? {
    guard
      provider.status == .adoptionRequired,
      let source = provider.source,
      let sourceConfiguration = provider.sourceConfiguration,
      let composition,
      !composition.isBlocked
    else { return nil }

    let parsed = SkhdConfigurationParser().parse(sourceConfiguration)
    if !parsed.diagnostics.isEmpty {
      diagnostics.append(
        contentsOf: parsed.diagnostics.map {
          KeybindingsPlanDiagnostic(
            $0,
            source: URL(filePath: source)
          )
        }
      )
      return nil
    }
    let existing = Dictionary(
      uniqueKeysWithValues: parsed.bindings.map { ($0.identity, $0.command) }
    )
    let proposed = Dictionary(
      uniqueKeysWithValues: composition.bindings.map {
        ($0.binding.identity, $0.binding.command)
      }
    )
    let existingIdentities = Set(existing.keys)
    let proposedIdentities = Set(proposed.keys)
    let added = proposedIdentities.subtracting(existingIdentities).sorted().map {
      KeybindingsAdoptionChange(identity: $0, existingCommand: nil, proposedCommand: proposed[$0])
    }
    let removed = existingIdentities.subtracting(proposedIdentities).sorted().map {
      KeybindingsAdoptionChange(identity: $0, existingCommand: existing[$0], proposedCommand: nil)
    }
    let changed = existingIdentities.intersection(proposedIdentities).sorted().compactMap {
      identity -> KeybindingsAdoptionChange? in
      guard existing[identity] != proposed[identity] else { return nil }
      return KeybindingsAdoptionChange(
        identity: identity,
        existingCommand: existing[identity],
        proposedCommand: proposed[identity]
      )
    }
    return KeybindingsAdoptionDelta(
      source: source,
      added: added,
      removed: removed,
      changed: changed
    )
  }
}

struct KeybindingsPlanPreparation {
  let outcome: String
  let effectiveBehavior: KeybindingEffectiveBehavior
  let composition: KeybindingComposition?
  let generation: KeybindingGenerationInspection
  let provider: KeybindingProviderInspection
  let blockingMessages: [String]
  fileprivate let report: KeybindingsPlanReport
}

private struct KeybindingsPlanReport: Encodable {
  let schemaVersion = 2
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
  let generationAgreement: String
  let provider: KeybindingProviderInspection
  let effectiveStatus: KeybindingEffectiveStatus
  let effectiveStatusMessage: String
  let transaction: KeybindingTransactionInspection
  let process: KeybindingProcessInspection
  let lifecycleEvidence: KeybindingLifecycleEvidenceInspection
  let adoptionDelta: KeybindingsAdoptionDelta?
  let actions: [KeybindingsPlanAction]
  let diagnostics: [KeybindingsPlanDiagnostic]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }

    var lines = [
      "Macarchy keybindings plan [\(outcome)]:",
      "- profile [\(sources.profileStatus)]: \(sources.profile)",
      "- packaged defaults: \(sources.defaults)",
      "- packaged metadata: \(sources.defaultMetadata)",
      "- user override: \(sources.override ?? "none")",
      "- user metadata: \(sources.userMetadata ?? "none")",
      "- effective bindings: \(summary.effective)",
      "- packaged default count: \(summary.packagedDefaults)",
      "- user replacements: \(summary.userReplacements)",
      "- user additions: \(summary.userAdditions)",
      "- disabled defaults: \(summary.disabledDefaults)",
      "- proposed input digest: \(proposedInputDigest ?? "unavailable")",
      "- rendered digest: \(renderedDigest ?? "unavailable")",
      "- generation [\(generation.status)]: \(generation.message)",
      "- generation agreement: \(generationAgreement)",
      "- current input digest: \(generation.currentInputDigest ?? "none")",
      "- current rendered digest: \(generation.currentRenderedDigest ?? "none")",
      "- provider [\(provider.status.rawValue), \(provider.ownership)]: \(provider.message)",
      "- effective state [\(effectiveStatus.rawValue)]: \(effectiveStatusMessage)",
      "- transaction [\(transaction.status.rawValue)]: \(transaction.message)",
      "- process [\(process.status.rawValue)]: \(process.message)",
      "- lifecycle evidence [\(lifecycleEvidence.status.rawValue)]: "
        + lifecycleEvidence.message,
      "- provider entry point: \(provider.entryPoint)",
      "- provider expected target: \(provider.expectedTarget)",
      "- provider original target: \(provider.originalTarget ?? "none")",
      "- provider source: \(provider.source ?? "none")",
      "- adoption evidence: \(provider.adoptionEvidenceDigest ?? "none")",
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
    if let adoptionDelta {
      lines.append(
        "Adoption delta from \(adoptionDelta.source): "
          + "\(adoptionDelta.added.count) added, \(adoptionDelta.removed.count) removed, "
          + "\(adoptionDelta.changed.count) changed"
      )
      lines.append(contentsOf: adoptionDelta.humanLines)
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
    if let renderedSkhdrc {
      lines.append(
        "Rendered skhdrc:\n--- begin exact bytes ---\n\(renderedSkhdrc)--- end exact bytes ---")
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
  let currentInputDigest: String?
  let currentRenderedDigest: String?
  let message: String

  init(_ inspection: KeybindingGenerationInspection) {
    status = inspection.status.rawValue
    generationID = inspection.generationID
    currentInputDigest = inspection.inputDigest
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

private struct KeybindingsAdoptionDelta: Encodable {
  let source: String
  let added: [KeybindingsAdoptionChange]
  let removed: [KeybindingsAdoptionChange]
  let changed: [KeybindingsAdoptionChange]

  var humanLines: [String] {
    added.map { "- add \($0.identity): \($0.proposedCommand ?? "")" }
      + removed.map { "- remove \($0.identity): \($0.existingCommand ?? "")" }
      + changed.map {
        "- change \($0.identity): \($0.existingCommand ?? "") -> \($0.proposedCommand ?? "")"
      }
  }
}

private struct KeybindingsAdoptionChange: Encodable {
  let identity: String
  let existingCommand: String?
  let proposedCommand: String?
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

  init(_ diagnostic: SkhdDiagnostic, source: URL) {
    self.init(
      code: diagnostic.code.rawValue,
      severity: "error",
      source: source.path,
      line: diagnostic.line,
      relatedLine: diagnostic.relatedLine,
      identity: nil,
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
