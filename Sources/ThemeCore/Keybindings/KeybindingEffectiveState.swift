import Foundation

package struct KeybindingEffectiveSources: Equatable, Sendable {
  package let defaultsURL: URL
  package let defaultMetadataURL: URL
  package let profileURL: URL
  package let profileStatus: String
  package let overrideURL: URL?
  package let userMetadataURL: URL?
}

package struct KeybindingEffectiveConfiguration: Equatable, Sendable {
  package let sources: KeybindingEffectiveSources
  package let composition: KeybindingComposition?
  package let diagnostics: [KeybindingCompositionDiagnostic]

  package var isBlocked: Bool {
    diagnostics.contains { $0.severity == .error }
  }
}

package enum KeybindingGenerationAgreement: String, Codable, Sendable {
  case unavailable
  case missing
  case matches
  case differs
  case invalid
}

package struct KeybindingEffectiveState: Equatable, Sendable {
  package let configuration: KeybindingEffectiveConfiguration
  package let generation: KeybindingGenerationInspection
  package let generationAgreement: KeybindingGenerationAgreement

  package var attributedBindings: [EffectiveKeybinding] {
    configuration.composition?.bindings ?? []
  }

  /// Rows ordered for human presentation. The composition's identity order remains
  /// authoritative for deterministic rendering and digest calculation.
  package var presentedBindings: [EffectiveKeybinding] {
    attributedBindings.sorted { lhs, rhs in
      let lhsOrder = lhs.metadata?.order ?? Int.max
      let rhsOrder = rhs.metadata?.order ?? Int.max
      if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
      return lhs.binding.identity < rhs.binding.identity
    }
  }

  package var disabledDefaults: [DisabledPackagedKeybinding] {
    configuration.composition?.disabledDefaults ?? []
  }

  package var presentedDisabledDefaults: [DisabledPackagedKeybinding] {
    disabledDefaults.sorted { lhs, rhs in
      if lhs.metadata.order != rhs.metadata.order {
        return lhs.metadata.order < rhs.metadata.order
      }
      return lhs.binding.identity < rhs.binding.identity
    }
  }
}

/// Loads the portable inputs once and compares their deterministic result with the
/// canonical generated state. Provider ownership and lifecycle state deliberately
/// remain outside this read-only boundary.
package struct KeybindingEffectiveStateInspector: Sendable {
  package init() {}

  package func inspect(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    profile suppliedProfile: KeybindingProfile? = nil
  ) -> KeybindingEffectiveState {
    let configuration = loadConfiguration(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      profile: suppliedProfile
    )
    let generation = KeybindingGenerationInspector().inspect(stateRoot: stateRoot)
    return KeybindingEffectiveState(
      configuration: configuration,
      generation: generation,
      generationAgreement: agreement(configuration: configuration, generation: generation)
    )
  }

  package func loadConfiguration(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    profile suppliedProfile: KeybindingProfile? = nil
  ) -> KeybindingEffectiveConfiguration {
    let defaultsURL = resourcesRoot.appending(path: "defaults.skhdrc")
    let defaultMetadataURL = resourcesRoot.appending(path: "metadata.toml")
    var diagnostics: [KeybindingCompositionDiagnostic] = []

    let defaultsText = readConfiguration(
      at: defaultsURL,
      code: "packaged_defaults_read_failed",
      diagnostics: &diagnostics
    )
    let defaultCatalog = loadCatalog(
      at: defaultMetadataURL,
      missingCode: "packaged_metadata_missing",
      invalidCode: "packaged_metadata_invalid",
      missingMessage: "packaged keybinding metadata is absent",
      diagnostics: &diagnostics
    )

    let profile: KeybindingProfile?
    if let suppliedProfile {
      profile = suppliedProfile
    } else {
      do {
        profile = try KeybindingProfileLoader().load(at: profileURL, required: profileRequired)
      } catch {
        profile = nil
        diagnostics.append(
          diagnostic(
            code: "profile_invalid",
            source: profileURL,
            message: String(describing: error)
          )
        )
      }
    }

    var overrideText: String?
    var userCatalog: SkhdKeybindingCatalog?
    if let profile {
      if let overrideURL = profile.overrideURL {
        overrideText = readConfiguration(
          at: overrideURL,
          code: "override_read_failed",
          diagnostics: &diagnostics
        )
      }
      if let metadataURL = profile.metadataURL {
        userCatalog = loadCatalog(
          at: metadataURL,
          missingCode: "user_metadata_missing",
          invalidCode: "user_metadata_invalid",
          missingMessage: "profile-selected metadata is absent",
          diagnostics: &diagnostics
        )
      }
    }

    var composition: KeybindingComposition?
    if !diagnostics.contains(where: { $0.severity == .error }),
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
      diagnostics.append(contentsOf: result.diagnostics)
    }

    let profileStatus: String
    if profile?.sourceURL != nil {
      profileStatus = "loaded"
    } else if profile == nil {
      profileStatus = "invalid"
    } else {
      profileStatus = "absent_default"
    }
    return KeybindingEffectiveConfiguration(
      sources: KeybindingEffectiveSources(
        defaultsURL: defaultsURL,
        defaultMetadataURL: defaultMetadataURL,
        profileURL: profileURL,
        profileStatus: profileStatus,
        overrideURL: profile?.overrideURL,
        userMetadataURL: profile?.metadataURL
      ),
      composition: composition,
      diagnostics: diagnostics.sorted(by: diagnosticOrder)
    )
  }

  private func agreement(
    configuration: KeybindingEffectiveConfiguration,
    generation: KeybindingGenerationInspection
  ) -> KeybindingGenerationAgreement {
    guard
      !configuration.isBlocked,
      let composition = configuration.composition,
      let inputDigest = composition.inputDigest,
      let renderedDigest = composition.renderedDigest
    else { return .unavailable }

    switch generation.status {
    case .missing:
      return .missing
    case .invalid:
      return .invalid
    case .current:
      return generation.inputDigest == inputDigest && generation.renderedDigest == renderedDigest
        ? .matches
        : .differs
    }
  }

  private func readConfiguration(
    at source: URL,
    code: String,
    diagnostics: inout [KeybindingCompositionDiagnostic]
  ) -> String? {
    do {
      let file = try BoundedRegularFile.read(at: source.resolvingSymlinksInPath())
      guard let text = String(data: file.data, encoding: .utf8) else {
        throw KeybindingEffectiveStateError("configuration is not valid UTF-8")
      }
      return text
    } catch {
      diagnostics.append(diagnostic(code: code, source: source, message: String(describing: error)))
      return nil
    }
  }

  private func loadCatalog(
    at source: URL,
    missingCode: String,
    invalidCode: String,
    missingMessage: String,
    diagnostics: inout [KeybindingCompositionDiagnostic]
  ) -> SkhdKeybindingCatalog? {
    do {
      let catalog = try SkhdKeybindingCatalogLoader().load(at: source)
      guard catalog.isPresent else {
        diagnostics.append(diagnostic(code: missingCode, source: source, message: missingMessage))
        return nil
      }
      return catalog
    } catch {
      diagnostics.append(
        diagnostic(code: invalidCode, source: source, message: String(describing: error))
      )
      return nil
    }
  }

  private func diagnostic(
    code: String,
    source: URL,
    message: String
  ) -> KeybindingCompositionDiagnostic {
    KeybindingCompositionDiagnostic(
      code: code,
      severity: .error,
      source: source,
      message: message
    )
  }

  private func diagnosticOrder(
    _ lhs: KeybindingCompositionDiagnostic,
    _ rhs: KeybindingCompositionDiagnostic
  ) -> Bool {
    (lhs.severity.rawValue, lhs.source, lhs.line ?? 0, lhs.code, lhs.identity ?? "")
      < (rhs.severity.rawValue, rhs.source, rhs.line ?? 0, rhs.code, rhs.identity ?? "")
  }
}

private struct KeybindingEffectiveStateError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
