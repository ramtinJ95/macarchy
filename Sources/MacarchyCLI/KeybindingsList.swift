import Foundation
import ThemeCore

enum SkhdConfigurationReadError: Error, CustomStringConvertible, Sendable {
  case invalidUTF8

  var description: String {
    "configuration is not valid UTF-8"
  }
}

struct KeybindingsListCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> String
  let loadCatalog: @Sendable (URL) throws -> SkhdKeybindingCatalog

  static let live = KeybindingsListCommandRunner(
    read: readSkhdConfiguration,
    loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) }
  )

  func execute(
    effectiveState: KeybindingEffectiveState,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report = EffectiveKeybindingsListReport(effectiveState)
    return (try report.render(json: json), report.succeeded)
  }

  func execute(
    configurationURL: URL,
    catalogURL: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let parsed: SkhdParseResult
    do {
      parsed = SkhdConfigurationParser().parse(try read(configurationURL))
    } catch {
      let report = KeybindingsListReport(
        source: configurationURL.path,
        bindings: [],
        diagnostics: [
          KeybindingsListDiagnostic(
            code: "configuration_read_failed",
            source: configurationURL.path,
            message: String(describing: error)
          )
        ]
      )
      return (try report.render(json: json), report.succeeded)
    }

    let catalog: SkhdKeybindingCatalog
    var diagnostics = parsed.diagnostics.map {
      KeybindingsListDiagnostic($0, source: configurationURL.path)
    }
    do {
      catalog = try loadCatalog(catalogURL)
    } catch {
      catalog = .missing
      let message =
        (error as? SkhdCatalogError)?.diagnosticMessage
        ?? String(describing: error)
      diagnostics.append(
        KeybindingsListDiagnostic(
          code: "catalog_invalid",
          source: catalogURL.path,
          message: message
        )
      )
    }

    let correlation = SkhdKeybindingCatalogLoader().correlate(
      bindings: parsed.bindings,
      catalog: catalog
    )
    let report = KeybindingsListReport(
      source: configurationURL.path,
      bindings: correlation.bindings.map(KeybindingListRow.init),
      diagnostics: diagnostics
    )
    return (try report.render(json: json), report.succeeded)
  }
}

private struct EffectiveKeybindingsListReport: Encodable {
  let schemaVersion = 2
  let operation = "keybindings_list"
  let profileStatus: String
  let generationStatus: String
  let generationAgreement: String
  let generationMessage: String?
  let bindings: [EffectiveKeybindingListRow]
  let disabledDefaults: [DisabledKeybindingListRow]
  let diagnostics: [EffectiveKeybindingsListDiagnostic]

  init(_ state: KeybindingEffectiveState) {
    profileStatus = state.configuration.sources.profileStatus
    generationStatus = state.generation.status.rawValue
    generationAgreement = state.generationAgreement.rawValue
    generationMessage = state.generation.message
    bindings = state.attributedBindings.map(EffectiveKeybindingListRow.init)
    disabledDefaults = state.disabledDefaults.map(DisabledKeybindingListRow.init)
    diagnostics = state.configuration.diagnostics.map(EffectiveKeybindingsListDiagnostic.init)
  }

  var succeeded: Bool {
    !diagnostics.contains { $0.severity == "error" }
      && generationStatus != KeybindingGenerationStatus.invalid.rawValue
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }

    var lines = [
      "Macarchy effective keybindings [generation \(generationAgreement)]:"
    ]
    if let generationMessage {
      lines.append("Generation diagnostic: \(generationMessage)")
    }
    lines.append(
      contentsOf: bindings.map { binding in
        var source = binding.commandSource
        if let metadataSource = binding.metadataSource {
          source += ", metadata=\(metadataSource)"
        }
        var line = "\(binding.chord)\t\(binding.command)\t[\(source)]"
        if let metadata = binding.metadata {
          line += "\t\(metadata.category)\t\(metadata.label)"
        }
        return line
      }
    )
    if bindings.isEmpty {
      lines.append("No effective keybindings.")
    }
    if !disabledDefaults.isEmpty {
      lines.append("Disabled packaged defaults:")
      lines.append(contentsOf: disabledDefaults.map { "- \($0.identity): \($0.command)" })
    }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines.append(contentsOf: diagnostics.map(\.humanDescription))
    }
    return lines.joined(separator: "\n")
  }
}

private struct EffectiveKeybindingListRow: Encodable {
  let identity: String
  let chord: String
  let command: String
  let commandSource: String
  let metadataSource: String?
  let metadata: KeybindingMetadataReport?

  init(_ effective: EffectiveKeybinding) {
    identity = effective.binding.identity
    chord = effective.binding.chord
    command = effective.binding.command
    commandSource = effective.commandSource.rawValue
    metadataSource = effective.metadataSource?.rawValue
    metadata = effective.metadata.map(KeybindingMetadataReport.init)
  }
}

private struct DisabledKeybindingListRow: Encodable {
  let identity: String
  let chord: String
  let command: String
  let commandSource = "packaged_default"
  let state = "disabled"
  let metadata: KeybindingMetadataReport

  init(_ disabled: DisabledPackagedKeybinding) {
    identity = disabled.binding.identity
    chord = disabled.binding.chord
    command = disabled.binding.command
    metadata = KeybindingMetadataReport(disabled.metadata)
  }
}

private struct EffectiveKeybindingsListDiagnostic: Encodable {
  let code: String
  let severity: String
  let source: String
  let line: Int?
  let relatedLine: Int?
  let identity: String?
  let message: String

  init(_ diagnostic: KeybindingCompositionDiagnostic) {
    code = diagnostic.code
    severity = diagnostic.severity.rawValue
    source = diagnostic.source
    line = diagnostic.line
    relatedLine = diagnostic.relatedLine
    identity = diagnostic.identity
    message = diagnostic.message
  }

  var humanDescription: String {
    let location = line.map { "\(source):\($0)" } ?? source
    return "\(location): \(severity) [\(code)]: \(message)"
  }
}

func readSkhdConfiguration(_ source: URL) throws -> String {
  let file = try BoundedRegularFile.read(at: source.resolvingSymlinksInPath())
  guard let text = String(data: file.data, encoding: .utf8) else {
    throw SkhdConfigurationReadError.invalidUTF8
  }
  return text
}

private struct KeybindingsListReport: Encodable {
  let schemaVersion = 1
  let source: String
  let bindings: [KeybindingListRow]
  let diagnostics: [KeybindingsListDiagnostic]

  var succeeded: Bool { diagnostics.isEmpty }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }

    var lines = bindings.map { binding in
      var line = "\(binding.chord)\t\(binding.command)"
      if let metadata = binding.metadata {
        line += "\t\(metadata.category)\t\(metadata.label)"
      }
      return line
    }
    if bindings.isEmpty {
      lines.append("No enabled keybindings.")
    }
    if !diagnostics.isEmpty {
      lines.append("Diagnostics:")
      lines.append(
        contentsOf: diagnostics.map { diagnostic in
          let location = diagnostic.line.map { "\(diagnostic.source):\($0)" } ?? diagnostic.source
          return "\(location): error [\(diagnostic.code)]: \(diagnostic.message)"
        }
      )
    }
    return lines.joined(separator: "\n")
  }
}

private struct KeybindingsListDiagnostic: Encodable {
  let code: String
  let severity = "error"
  let source: String
  let line: Int?
  let relatedLine: Int?
  let message: String

  init(
    code: String,
    source: String,
    line: Int? = nil,
    relatedLine: Int? = nil,
    message: String
  ) {
    self.code = code
    self.source = source
    self.line = line
    self.relatedLine = relatedLine
    self.message = message
  }

  init(_ diagnostic: SkhdDiagnostic, source: String) {
    self.init(
      code: diagnostic.code.rawValue,
      source: source,
      line: diagnostic.line,
      relatedLine: diagnostic.relatedLine,
      message: diagnostic.message
    )
  }
}

private struct KeybindingListRow: Encodable {
  let identity: String
  let chord: String
  let command: String
  let line: Int
  let metadata: KeybindingMetadataReport?

  init(_ presented: SkhdPresentedBinding) {
    identity = presented.binding.identity
    chord = presented.binding.chord
    command = presented.binding.command
    line = presented.binding.line
    metadata = presented.metadata.map(KeybindingMetadataReport.init)
  }
}

private struct KeybindingMetadataReport: Encodable {
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
