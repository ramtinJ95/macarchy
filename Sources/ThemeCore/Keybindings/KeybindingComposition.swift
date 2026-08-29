import Foundation

package enum KeybindingCommandSource: String, Codable, Sendable {
  case packagedDefault = "packaged_default"
  case userReplacement = "user_replacement"
  case userAddition = "user_addition"
}

package enum KeybindingMetadataSource: String, Codable, Sendable {
  case packagedDefault = "packaged_default"
  case userOverlay = "user_overlay"
}

package enum KeybindingCompositionSeverity: String, Codable, Sendable {
  case warning
  case error
}

package struct KeybindingCompositionDiagnostic: Equatable, Codable, Sendable {
  package let code: String
  package let severity: KeybindingCompositionSeverity
  package let source: String
  package let line: Int?
  package let relatedLine: Int?
  package let identity: String?
  package let message: String

  package init(
    code: String,
    severity: KeybindingCompositionSeverity,
    source: URL,
    line: Int? = nil,
    relatedLine: Int? = nil,
    identity: String? = nil,
    message: String
  ) {
    self.code = code
    self.severity = severity
    self.source = source.path
    self.line = line
    self.relatedLine = relatedLine
    self.identity = identity
    self.message = message
  }
}

package struct EffectiveKeybinding: Equatable, Sendable {
  package let binding: SkhdBinding
  package let commandSource: KeybindingCommandSource
  package let metadata: SkhdCatalogEntry?
  package let metadataSource: KeybindingMetadataSource?
}

package struct DisabledPackagedKeybinding: Equatable, Sendable {
  package let binding: SkhdBinding
  package let metadata: SkhdCatalogEntry
}

package struct KeybindingComposition: Equatable, Sendable {
  package let bindings: [EffectiveKeybinding]
  package let disabledDefaults: [DisabledPackagedKeybinding]
  package let diagnostics: [KeybindingCompositionDiagnostic]
  package let renderedConfiguration: String?
  package let renderedDigest: String?
  package let inputDigest: String?

  package var isBlocked: Bool {
    diagnostics.contains { $0.severity == .error }
  }
}

package struct KeybindingComposer: Sendable {
  package static let rendererVersion = 1

  package init() {}

  package func compose(
    defaultsText: String,
    defaultsSource: URL,
    defaultCatalog: SkhdKeybindingCatalog,
    defaultMetadataSource: URL,
    profile: KeybindingProfile,
    overrideText: String?,
    userCatalog: SkhdKeybindingCatalog?
  ) -> KeybindingComposition {
    let parser = SkhdConfigurationParser()
    let defaults = parser.parse(defaultsText)
    let user = overrideText.map(parser.parse)
    let overrideSource = profile.overrideURL
    let profileSource =
      profile.sourceURL
      ?? URL(filePath: "~/.config/macarchy/profile.toml")
    var diagnostics = parserDiagnostics(defaults.diagnostics, source: defaultsSource)
    if let user, let overrideSource {
      diagnostics.append(contentsOf: parserDiagnostics(user.diagnostics, source: overrideSource))
    }

    let defaultIdentities = Set(defaults.bindings.map(\.identity))
    let packagedMetadataIdentities = Set(defaultCatalog.entries.map(\.identity))
    for identity in defaultIdentities.subtracting(packagedMetadataIdentities).sorted() {
      diagnostics.append(
        KeybindingCompositionDiagnostic(
          code: "packaged_metadata_missing",
          severity: .error,
          source: defaultMetadataSource,
          identity: identity,
          message: "packaged binding '\(identity)' has no packaged metadata"
        )
      )
    }
    for identity in packagedMetadataIdentities.subtracting(defaultIdentities).sorted() {
      diagnostics.append(
        KeybindingCompositionDiagnostic(
          code: "packaged_metadata_stale",
          severity: .error,
          source: defaultMetadataSource,
          identity: identity,
          message: "packaged metadata '\(identity)' has no packaged binding"
        )
      )
    }

    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      return blocked(diagnostics)
    }

    let defaultsByIdentity = Dictionary(
      uniqueKeysWithValues: defaults.bindings.map { ($0.identity, $0) }
    )
    let defaultMetadataByIdentity = Dictionary(
      uniqueKeysWithValues: defaultCatalog.entries.map { ($0.identity, $0) }
    )
    let userBindings = user?.bindings ?? []
    let userByIdentity = Dictionary(
      uniqueKeysWithValues: userBindings.map { ($0.identity, $0) }
    )

    for identity in profile.disabledIdentities {
      guard defaultsByIdentity[identity] != nil else {
        diagnostics.append(
          KeybindingCompositionDiagnostic(
            code: "unknown_disabled_identity",
            severity: .error,
            source: profileSource,
            identity: identity,
            message: "disabled identity '\(identity)' is not a packaged default"
          )
        )
        continue
      }
      if userByIdentity[identity] != nil {
        diagnostics.append(
          KeybindingCompositionDiagnostic(
            code: "disabled_override_conflict",
            severity: .error,
            source: profileSource,
            identity: identity,
            message: "identity '\(identity)' is both disabled and overridden"
          )
        )
      }
    }
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      return blocked(diagnostics)
    }

    let disabled = Set(profile.disabledIdentities)
    let userMetadataByIdentity = Dictionary(
      uniqueKeysWithValues: (userCatalog?.entries ?? []).map { ($0.identity, $0) }
    )
    var effective: [String: (SkhdBinding, KeybindingCommandSource)] = [:]
    for binding in defaults.bindings where !disabled.contains(binding.identity) {
      effective[binding.identity] = (binding, .packagedDefault)
    }
    for binding in userBindings {
      effective[binding.identity] = (
        binding,
        defaultsByIdentity[binding.identity] == nil ? .userAddition : .userReplacement
      )
    }

    let effectiveIdentities = Set(effective.keys)
    for identity in userMetadataByIdentity.keys.sorted()
    where !effectiveIdentities.contains(identity) {
      diagnostics.append(
        KeybindingCompositionDiagnostic(
          code: "user_metadata_stale",
          severity: .warning,
          source: profile.metadataURL ?? profileSource,
          identity: identity,
          message: "user metadata '\(identity)' has no effective binding"
        )
      )
    }

    let bindings = effective.keys.sorted().compactMap { identity -> EffectiveKeybinding? in
      guard let (binding, commandSource) = effective[identity] else { return nil }
      if let metadata = userMetadataByIdentity[identity] {
        return EffectiveKeybinding(
          binding: binding,
          commandSource: commandSource,
          metadata: metadata,
          metadataSource: .userOverlay
        )
      }
      if let metadata = defaultMetadataByIdentity[identity] {
        return EffectiveKeybinding(
          binding: binding,
          commandSource: commandSource,
          metadata: metadata,
          metadataSource: .packagedDefault
        )
      }
      diagnostics.append(
        KeybindingCompositionDiagnostic(
          code: "user_metadata_missing",
          severity: .warning,
          source: profile.overrideURL ?? profileSource,
          line: binding.line,
          identity: identity,
          message: "user binding '\(identity)' has no metadata"
        )
      )
      return EffectiveKeybinding(
        binding: binding,
        commandSource: commandSource,
        metadata: nil,
        metadataSource: nil
      )
    }
    let disabledDefaults: [DisabledPackagedKeybinding] =
      profile.disabledIdentities.sorted().compactMap { identity in
        guard
          let binding = defaultsByIdentity[identity],
          let metadata = defaultMetadataByIdentity[identity]
        else { return nil }
        return DisabledPackagedKeybinding(binding: binding, metadata: metadata)
      }
    let rendered =
      bindings.map { "\($0.binding.chord) : \($0.binding.command)" }
      .joined(separator: "\n") + "\n"
    let inputDigest = canonicalInputDigest(
      bindings: bindings,
      disabledDefaults: disabledDefaults
    )

    return KeybindingComposition(
      bindings: bindings,
      disabledDefaults: disabledDefaults,
      diagnostics: diagnostics.sorted(by: diagnosticOrder),
      renderedConfiguration: rendered,
      renderedDigest: sha256Digest(Data(rendered.utf8)),
      inputDigest: inputDigest
    )
  }

  private func parserDiagnostics(
    _ parserDiagnostics: [SkhdDiagnostic],
    source: URL
  ) -> [KeybindingCompositionDiagnostic] {
    parserDiagnostics.map {
      KeybindingCompositionDiagnostic(
        code: $0.code.rawValue,
        severity: .error,
        source: source,
        line: $0.line,
        relatedLine: $0.relatedLine,
        message: $0.message
      )
    }
  }

  private func blocked(
    _ diagnostics: [KeybindingCompositionDiagnostic]
  ) -> KeybindingComposition {
    KeybindingComposition(
      bindings: [],
      disabledDefaults: [],
      diagnostics: diagnostics.sorted(by: diagnosticOrder),
      renderedConfiguration: nil,
      renderedDigest: nil,
      inputDigest: nil
    )
  }

  private func canonicalInputDigest(
    bindings: [EffectiveKeybinding],
    disabledDefaults: [DisabledPackagedKeybinding]
  ) -> String {
    let document = CanonicalKeybindingInput(
      schemaVersion: 1,
      rendererVersion: Self.rendererVersion,
      bindings: bindings.map(CanonicalKeybinding.init),
      disabledIdentities: disabledDefaults.map(\.binding.identity).sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(document) else {
      preconditionFailure("Canonical keybinding input encoding must not fail")
    }
    return sha256Digest(data)
  }

  private func diagnosticOrder(
    _ lhs: KeybindingCompositionDiagnostic,
    _ rhs: KeybindingCompositionDiagnostic
  ) -> Bool {
    (lhs.severity.rawValue, lhs.source, lhs.line ?? 0, lhs.code, lhs.identity ?? "")
      < (rhs.severity.rawValue, rhs.source, rhs.line ?? 0, rhs.code, rhs.identity ?? "")
  }
}

private struct CanonicalKeybindingInput: Encodable {
  let schemaVersion: Int
  let rendererVersion: Int
  let bindings: [CanonicalKeybinding]
  let disabledIdentities: [String]
}

private struct CanonicalKeybinding: Encodable {
  let identity: String
  let chord: String
  let command: String
  let commandSource: String
  let metadata: CanonicalKeybindingMetadata?
  let metadataSource: String?

  init(_ effective: EffectiveKeybinding) {
    identity = effective.binding.identity
    chord = effective.binding.chord
    command = effective.binding.command
    commandSource = effective.commandSource.rawValue
    metadata = effective.metadata.map(CanonicalKeybindingMetadata.init)
    metadataSource = effective.metadataSource?.rawValue
  }
}

private struct CanonicalKeybindingMetadata: Encodable {
  let identity: String
  let label: String
  let category: String
  let order: Int
  let aliases: [String]

  init(_ metadata: SkhdCatalogEntry) {
    identity = metadata.identity
    label = metadata.label
    category = metadata.category
    order = metadata.order
    aliases = metadata.aliases
  }
}
