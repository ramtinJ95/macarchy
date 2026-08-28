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
