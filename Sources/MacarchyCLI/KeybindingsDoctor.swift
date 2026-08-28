import Foundation
import ThemeCore

struct KeybindingsDoctorCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> String
  let loadCatalog: @Sendable (URL) throws -> SkhdKeybindingCatalog

  static let live = KeybindingsDoctorCommandRunner(
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
      let report = KeybindingsDoctorReport(
        findings: [
          KeybindingsDoctorFinding(
            id: "skhd.read",
            status: .failure,
            message: String(describing: error),
            source: configurationURL.path
          )
        ]
      )
      return (try report.render(json: json), report.succeeded)
    }

    var findings: [KeybindingsDoctorFinding] = []
    if parsed.diagnostics.isEmpty {
      findings.append(
        KeybindingsDoctorFinding(
          id: "skhd.parse",
          status: .ok,
          message: "Parsed \(parsed.bindings.count) enabled bindings."
        )
      )
    } else {
      findings.append(
        contentsOf: parsed.diagnostics.map { diagnostic in
          KeybindingsDoctorFinding(
            id: diagnostic.code == .duplicateChord
              ? "skhd.duplicate.\(diagnostic.line ?? 0)"
              : "skhd.syntax.\(diagnostic.line ?? 0)",
            status: .warning,
            message: diagnostic.message,
            source: configurationURL.path,
            line: diagnostic.line,
            relatedLine: diagnostic.relatedLine
          )
        }
      )
    }

    let catalog: SkhdKeybindingCatalog
    do {
      catalog = try loadCatalog(catalogURL)
    } catch {
      let message =
        (error as? SkhdCatalogError)?.diagnosticMessage
        ?? String(describing: error)
      findings.append(
        KeybindingsDoctorFinding(
          id: "catalog.load",
          status: .failure,
          message: message,
          source: catalogURL.path
        )
      )
      let report = KeybindingsDoctorReport(findings: findings)
      return (try report.render(json: json), report.succeeded)
    }

    findings.append(
      KeybindingsDoctorFinding(
        id: "catalog.load",
        status: catalog.isPresent ? .ok : .warning,
        message: catalog.isPresent
          ? "Loaded \(catalog.entries.count) metadata entries."
          : "Catalog is absent at \(catalogURL.path)."
      )
    )

    let correlation = SkhdKeybindingCatalogLoader().correlate(
      bindings: parsed.bindings,
      catalog: catalog
    )
    findings.append(
      coverageFinding(
        id: "catalog.missing",
        identities: correlation.missingMetadataIdentities,
        emptyMessage: "Every parsed binding has metadata.",
        populatedMessage: "Parsed bindings are missing metadata."
      )
    )
    findings.append(
      coverageFinding(
        id: "catalog.stale",
        identities: correlation.staleMetadataIdentities,
        emptyMessage: "No stale metadata entries.",
        populatedMessage: "Metadata entries do not match an enabled binding."
      )
    )

    let report = KeybindingsDoctorReport(findings: findings)
    return (try report.render(json: json), report.succeeded)
  }

  private func coverageFinding(
    id: String,
    identities: [String],
    emptyMessage: String,
    populatedMessage: String
  ) -> KeybindingsDoctorFinding {
    KeybindingsDoctorFinding(
      id: id,
      status: identities.isEmpty ? .ok : .warning,
      message: identities.isEmpty
        ? emptyMessage
        : "\(populatedMessage) Count: \(identities.count).",
      identities: identities.isEmpty ? nil : identities
    )
  }
}

private struct KeybindingsDoctorFinding: Encodable {
  enum Status: String, Encodable {
    case ok
    case warning
    case failure
  }

  let id: String
  let status: Status
  let message: String
  var source: String? = nil
  var identities: [String]? = nil
  var line: Int? = nil
  var relatedLine: Int? = nil
}

private struct KeybindingsDoctorReport {
  let findings: [KeybindingsDoctorFinding]

  var succeeded: Bool {
    !findings.contains { $0.status == .failure }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(KeybindingsDoctorJSONReport(findings: findings))
    }
    let renderedFindings = findings.map { finding in
      let location = finding.source.map { source in
        finding.line.map { "\(source):\($0)" } ?? source
      }
      let locationPrefix = location.map { "\($0): " } ?? ""
      var line =
        "- \(finding.id) [\(finding.status.rawValue)]: "
        + locationPrefix + finding.message
      if let identities = finding.identities {
        line += " \(identities.joined(separator: ", "))"
      }
      return line
    }
    return (["Macarchy keybindings doctor:"] + renderedFindings + ["No changes made."])
      .joined(separator: "\n")
  }
}

private struct KeybindingsDoctorJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "keybindings_doctor"
  let outcome: String
  let mutated = false
  let findings: [KeybindingsDoctorFinding]

  init(findings: [KeybindingsDoctorFinding]) {
    outcome = findings.contains { $0.status == .failure } ? "unhealthy" : "healthy"
    self.findings = findings
  }
}
