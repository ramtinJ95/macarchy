import ArgumentParser
import Foundation
import ThemeCore

@main
struct Macarchy: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macarchy",
    abstract: "A native, theme-driven macOS desktop shell.",
    version: "0.1.0-dev",
    subcommands: [Theme.self, Reconcile.self, Doctor.self]
  )

  struct StateOptions: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Option(help: "Kitty configuration file.")
    var kittyConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/kitty/kitty.conf").path

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    var kittyConfigurationURL: URL {
      URL(filePath: kittyConfig).standardizedFileURL
    }
  }

  struct Reconcile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Reconcile the active theme with selected consumers."
    )

    @OptionGroup var state: StateOptions

    @Argument(help: "Adapter identifiers. Omit to reconcile all known adapters.")
    var adapters: [String] = []

    @Flag(help: "Inspect without running processes or writing status.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await ReconcileCommandRunner.live.execute(
        adapterIDs: adapters,
        stateRoot: state.stateRootURL,
        kittyConfigurationURL: state.kittyConfigurationURL,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose canonical theme state and consumer integration."
    )

    @OptionGroup var state: StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DoctorCommandRunner.live.execute(
        stateRoot: state.stateRootURL,
        kittyConfigurationURL: state.kittyConfigurationURL,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}

struct Theme: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect or select themes.",
    subcommands: [List.self, Set.self, Next.self, Status.self]
  )
}

extension Theme {
  struct ThemeRootOptions: ParsableArguments {
    @Option(help: "Built-in theme package directory.")
    var themesRoot = "Themes"

    func repository(userRoot: URL? = nil) -> ThemeRepository {
      ThemeRepository(
        builtInRoot: URL(filePath: themesRoot, directoryHint: .isDirectory)
          .standardizedFileURL,
        userRoot: userRoot
      )
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List valid available themes.")

    @OptionGroup var roots: ThemeRootOptions

    mutating func run() throws {
      for package in try roots.repository().packages() {
        print("\(package.id)\t\(package.appearance.rawValue)\t\(package.displayName)")
      }
    }
  }

  struct ActivationOptions: ParsableArguments {
    @OptionGroup var roots: ThemeRootOptions
    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Validate and describe outputs without writing files.")
    var dryRun = false

    var stateRootURL: URL {
      state.stateRootURL
    }

    var kittyConfigurationURL: URL {
      state.kittyConfigurationURL
    }

    var repository: ThemeRepository {
      roots.repository(
        userRoot: stateRootURL.appending(path: "themes", directoryHint: .isDirectory)
      )
    }
  }

  struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate a theme and reconcile its consumers."
    )

    @OptionGroup var options: ActivationOptions

    @Argument(help: "Theme package identifier.")
    var themeID: String

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await ThemeSetCommandRunner.live.execute(
        repository: options.repository,
        themeID: themeID,
        stateRoot: options.stateRootURL,
        kittyConfigurationURL: options.kittyConfigurationURL,
        dryRun: options.dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Next: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate the next available theme."
    )

    @OptionGroup var options: ActivationOptions

    mutating func run() async throws {
      let execution = try await ThemeNextCommandRunner.live.execute(
        repository: options.repository,
        stateRoot: options.stateRootURL,
        kittyConfigurationURL: options.kittyConfigurationURL,
        dryRun: options.dryRun
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the canonical theme and its reconciliation state."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try ThemeStatusCommandRunner.live.execute(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}

struct ThemeSetCommandRunner: Sendable {
  let preflight: @Sendable (ThemePackage, URL, URL) throws -> Void
  let activate: @Sendable (ThemePackage, URL, URL, String?) async throws -> ThemeActivationResult

  static let live = ThemeSetCommandRunner(
    preflight: { package, stateRoot, kittyConfigurationURL in
      try ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).preflight(package: package)
    },
    activate: { package, stateRoot, kittyConfigurationURL, expectedActiveGenerationID in
      try await ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).activate(
        package: package,
        expectedActiveGenerationID: expectedActiveGenerationID
      )
    }
  )

  func execute(
    repository: ThemeRepository,
    themeID: String,
    stateRoot: URL,
    kittyConfigurationURL: URL,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    do {
      let package = try repository.package(id: themeID)
      return try await execute(
        package: package,
        stateRoot: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL,
        dryRun: dryRun,
        expectedActiveGenerationID: nil,
        json: json
      )
    } catch {
      let report = ThemeSetReport.precommitFailure(themeID: themeID, error: error)
      return (try report.render(json: json), report.succeeded)
    }
  }

  func execute(
    package: ThemePackage,
    stateRoot: URL,
    kittyConfigurationURL: URL,
    dryRun: Bool,
    expectedActiveGenerationID: String?,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let report: ThemeSetReport
    if dryRun {
      do {
        try preflight(package, stateRoot, kittyConfigurationURL)
        report = .dryRun(themeID: package.id)
      } catch {
        report = .precommitFailure(themeID: package.id, error: error)
      }
    } else {
      do {
        report = .committed(
          try await activate(
            package,
            stateRoot,
            kittyConfigurationURL,
            expectedActiveGenerationID
          )
        )
      } catch let error as ThemeActivationError {
        if case .activeGenerationChanged = error { throw error }
        report = .precommitFailure(themeID: package.id, error: error)
      } catch let error as ThemeCommittedWithReconciliationError {
        report = .committedError(manifest: error.manifest, cause: error.cause)
      } catch {
        report = .precommitFailure(themeID: package.id, error: error)
      }
    }
    return (try report.render(json: json), report.succeeded)
  }
}

enum ThemeNextError: Error, CustomStringConvertible, Equatable {
  case noActiveTheme
  case activeThemeUnavailable(String)

  var description: String {
    switch self {
    case .noActiveTheme:
      "No active theme; activate one with 'macarchy theme set <theme-id>'"
    case .activeThemeUnavailable(let themeID):
      "Active theme '\(themeID)' is not available; cannot determine the next theme"
    }
  }
}

struct ThemeNextCommandRunner: Sendable {
  let activeManifest: @Sendable (URL) throws -> GenerationManifest
  let activation: ThemeSetCommandRunner

  static let live = ThemeNextCommandRunner(
    activeManifest: { root in
      try ReconciliationStatusStore(root: root).activeManifest()
    },
    activation: .live
  )

  func execute(
    repository: ThemeRepository,
    stateRoot: URL,
    kittyConfigurationURL: URL,
    dryRun: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let packages = try repository.packages()
    while true {
      let active: GenerationManifest
      do {
        active = try activeManifest(stateRoot)
      } catch ReconciliationStatusError.noActiveGeneration {
        throw ThemeNextError.noActiveTheme
      }
      guard let activeIndex = packages.firstIndex(where: { $0.id == active.themeID }) else {
        throw ThemeNextError.activeThemeUnavailable(active.themeID)
      }
      let package = packages[(activeIndex + 1) % packages.count]
      do {
        return try await activation.execute(
          package: package,
          stateRoot: stateRoot,
          kittyConfigurationURL: kittyConfigurationURL,
          dryRun: dryRun,
          expectedActiveGenerationID: dryRun ? nil : active.generationID,
          json: false
        )
      } catch ThemeActivationError.activeGenerationChanged {
        continue
      }
    }
  }
}

struct ThemeStatusCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> ThemeStatusSnapshot

  static let live = ThemeStatusCommandRunner(
    read: readThemeStatusSnapshot
  )

  func execute(
    stateRoot: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let report: ThemeStatusReport
    do {
      let snapshot = try read(stateRoot)
      switch snapshot {
      case .state(let manifest, let reconciliation):
        report = .active(manifest: manifest, reconciliation: reconciliation)
      case .reconciliationFailure(let manifest, let error):
        report = .activeFailure(manifest: manifest, error: error)
      }
    } catch ReconciliationStatusError.noActiveGeneration {
      report = .inactive
    } catch {
      report = .failure(String(describing: error))
    }
    return (try report.render(json: json), report.succeeded)
  }
}

enum ThemeStatusSnapshot: Sendable {
  case state(manifest: GenerationManifest, reconciliation: ReconciliationState)
  case reconciliationFailure(manifest: GenerationManifest, error: String)
}

struct ReconcileCommandRunner: Sendable {
  let preview:
    @Sendable ([String], URL, URL) throws -> (
      manifest: GenerationManifest, inspections: [AdapterInspection]
    )
  let reconcile:
    @Sendable ([String], URL, URL) async throws -> (
      manifest: GenerationManifest, record: ReconciliationRecord
    )

  static let live = ReconcileCommandRunner(
    preview: { adapterIDs, stateRoot, kittyConfigurationURL in
      try ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).previewReconciliation(adapterIDs)
    },
    reconcile: { adapterIDs, stateRoot, kittyConfigurationURL in
      try await ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).reconcile(adapterIDs: adapterIDs)
    }
  )

  func execute(
    adapterIDs: [String],
    stateRoot: URL,
    kittyConfigurationURL: URL,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let report: ReconcileReport
    do {
      if dryRun {
        let preview = try preview(adapterIDs, stateRoot, kittyConfigurationURL)
        report = .preview(
          manifest: preview.manifest,
          inspections: preview.inspections
        )
      } else {
        let result = try await reconcile(adapterIDs, stateRoot, kittyConfigurationURL)
        report = .completed(manifest: result.manifest, record: result.record)
      }
    } catch let error as ReconciliationPersistenceError {
      report = .persistenceFailure(error)
    } catch {
      report = .failure(dryRun: dryRun, error: String(describing: error))
    }
    return (try report.render(json: json), report.succeeded)
  }
}

struct DoctorCommandRunner: Sendable {
  let read: @Sendable (URL) throws -> ThemeStatusSnapshot
  let inspect: @Sendable (URL, URL) throws -> [AdapterInspection]

  static let live = DoctorCommandRunner(
    read: readThemeStatusSnapshot,
    inspect: { stateRoot, kittyConfigurationURL in
      try ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).inspectAdapters([])
    }
  )

  func execute(
    stateRoot: URL,
    kittyConfigurationURL: URL,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var findings = canonicalFindings(stateRoot: stateRoot)
    do {
      findings.append(
        contentsOf: try inspect(stateRoot, kittyConfigurationURL).map { inspection in
          DoctorFinding(
            id: "\(inspection.adapterID).integration",
            status: inspectionFindingStatus(inspection),
            message: inspection.message ?? "Integration preflight passed."
          )
        }
      )
    } catch {
      findings.append(
        DoctorFinding(
          id: "adapter.integration",
          status: .failure,
          message: String(describing: error)
        )
      )
    }
    let report = DoctorReport(findings: findings)
    return (try report.render(json: json), report.succeeded)
  }

  private func canonicalFindings(stateRoot: URL) -> [DoctorFinding] {
    do {
      switch try read(stateRoot) {
      case .reconciliationFailure(let manifest, let error):
        return [
          canonicalFinding(manifest),
          DoctorFinding(id: "reconciliation", status: .failure, message: error),
        ]
      case .state(let manifest, let reconciliation):
        var findings = [canonicalFinding(manifest)]
        switch reconciliation {
        case .missing:
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .failure,
              message: "Status is missing for the active generation."
            )
          )
        case .stale(_, let record):
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .failure,
              message:
                "Status belongs to theme '\(record.themeID)' generation '\(record.generationID)'."
            )
          )
        case .current(let record):
          findings.append(
            DoctorFinding(
              id: "reconciliation",
              status: .ok,
              message: "Status matches the active generation."
            )
          )
          for result in record.results {
            guard let requirement = ThemeActivationCoordinator.adapterRequirements[result.adapterID]
            else {
              findings.append(
                DoctorFinding(
                  id: "reconciliation.\(result.adapterID)",
                  status: .failure,
                  message: "Status contains an unknown adapter result."
                )
              )
              continue
            }
            if result.requirement != requirement {
              findings.append(
                DoctorFinding(
                  id: "reconciliation.\(result.adapterID)",
                  status: .failure,
                  message:
                    "Requirement is \(result.requirement.rawValue), expected \(requirement.rawValue)."
                )
              )
            } else {
              findings.append(reconciliationFinding(result))
            }
          }
          for adapterID in ThemeActivationCoordinator.adapterRequirements.keys.sorted()
          where !record.results.contains(where: { $0.adapterID == adapterID }) {
            findings.append(
              DoctorFinding(
                id: "reconciliation.\(adapterID)",
                status: .failure,
                message: "Current status has no result for this known adapter."
              )
            )
          }
        }
        return findings
      }
    } catch ReconciliationStatusError.noActiveGeneration {
      return [
        DoctorFinding(id: "canonical", status: .failure, message: "No active generation."),
        DoctorFinding(
          id: "reconciliation",
          status: .failure,
          message: "Unavailable without an active generation."
        ),
      ]
    } catch {
      return [
        DoctorFinding(
          id: "canonical",
          status: .failure,
          message: String(describing: error)
        ),
        DoctorFinding(
          id: "reconciliation",
          status: .failure,
          message: "Unavailable because canonical state is invalid."
        ),
      ]
    }
  }

  private func canonicalFinding(_ manifest: GenerationManifest) -> DoctorFinding {
    DoctorFinding(
      id: "canonical",
      status: .ok,
      message: "Theme '\(manifest.themeID)' generation '\(manifest.generationID)' is active."
    )
  }

  private func reconciliationFinding(_ result: AdapterResult) -> DoctorFinding {
    let accepted = result.status == .applied || result.status == .restartRequired
    let status: DoctorFinding.Status =
      accepted ? .ok : (result.requirement == .required ? .failure : .warning)
    let message =
      result.message.map { "\(result.status.rawValue): \($0)" }
      ?? result.status.rawValue
    return DoctorFinding(
      id: "reconciliation.\(result.adapterID)",
      status: status,
      message: message
    )
  }
}

private func readThemeStatusSnapshot(_ root: URL) throws -> ThemeStatusSnapshot {
  let store = ReconciliationStatusStore(root: root)
  let manifest = try store.activeManifest()
  do {
    return .state(
      manifest: manifest,
      reconciliation: try store.reconciliationState(for: manifest)
    )
  } catch {
    return .reconciliationFailure(
      manifest: manifest,
      error: String(describing: error)
    )
  }
}

private enum ReconcileReport {
  enum Outcome: String, Encodable {
    case dryRun = "dry_run"
    case inspectionFailure = "inspection_failure"
    case success
    case requiredReconciliationFailure = "required_reconciliation_failure"
    case persistenceFailure = "persistence_failure"
    case failure
  }

  case preview(manifest: GenerationManifest, inspections: [AdapterInspection])
  case completed(manifest: GenerationManifest, record: ReconciliationRecord)
  case persistenceFailure(ReconciliationPersistenceError)
  case failure(dryRun: Bool, error: String)

  var succeeded: Bool {
    switch self {
    case .preview(_, let inspections):
      !hasRequiredInspectionFailure(inspections)
    case .completed(_, let record):
      !hasRequiredReconciliationFailure(record.results)
    case .persistenceFailure, .failure:
      false
    }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .preview(let manifest, let inspections):
      return
        ([
          "Reconciliation dry run for '\(manifest.themeID)' "
            + "(generation '\(manifest.generationID)').",
          "Inspection:",
        ] + inspections.map(renderInspection)
        + [
          "Canonical state and reconciliation status: unchanged (dry run).",
          "No files written; no processes run.",
        ]).joined(separator: "\n")
    case .completed(let manifest, let record):
      var lines = [
        "Reconciled '\(manifest.themeID)' generation '\(manifest.generationID)'.",
        "Reconciliation:",
      ]
      lines.append(contentsOf: record.results.map(renderAdapterResult))
      if hasRequiredReconciliationFailure(record.results) {
        lines.append("Required reconciliation failed; canonical state was not changed.")
      }
      return lines.joined(separator: "\n")
    case .persistenceFailure(let error):
      return
        ([
          "Adapters ran for '\(error.manifest.themeID)' generation "
            + "'\(error.manifest.generationID)'.",
          "Observed reconciliation:",
        ] + error.results.map(renderAdapterResult)
        + [
          "Reconciliation status was not updated.",
          "Canonical state: unchanged.",
          "Error: \(error.cause)",
        ]).joined(separator: "\n")
    case .failure(_, let error):
      return [
        "Reconciliation could not complete.",
        "Canonical state: unchanged.",
        "Error: \(error)",
      ].joined(separator: "\n")
    }
  }

  private var jsonReport: ReconcileJSONReport {
    switch self {
    case .preview(let manifest, let inspections):
      return ReconcileJSONReport(
        outcome: hasRequiredInspectionFailure(inspections) ? .inspectionFailure : .dryRun,
        dryRun: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        inspections: inspections.map(ReconcileInspection.init)
      )
    case .completed(let manifest, let record):
      let requiredFailure = hasRequiredReconciliationFailure(record.results)
      return ReconcileJSONReport(
        outcome: requiredFailure ? .requiredReconciliationFailure : .success,
        dryRun: false,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record.results,
        error: requiredFailure ? "Required reconciliation did not complete successfully" : nil
      )
    case .persistenceFailure(let error):
      return ReconcileJSONReport(
        outcome: .persistenceFailure,
        dryRun: false,
        themeID: error.manifest.themeID,
        generationID: error.manifest.generationID,
        reconciliation: error.results,
        error: error.cause
      )
    case .failure(let dryRun, let error):
      return ReconcileJSONReport(
        outcome: .failure,
        dryRun: dryRun,
        error: error
      )
    }
  }

  private func renderInspection(_ inspection: AdapterInspection) -> String {
    let message = inspection.message.map { ": \($0)" } ?? ""
    let status = "\(inspection.status.rawValue)\(message)"
    return "- \(inspection.adapterID) [\(inspection.requirement.rawValue)]: \(status)"
  }
}

private struct ReconcileInspection: Encodable {
  let adapterID: String
  let requirement: AdapterRequirement
  let status: String
  let message: String?

  init(_ inspection: AdapterInspection) {
    adapterID = inspection.adapterID
    requirement = inspection.requirement
    status = inspection.status.rawValue
    message = inspection.message
  }
}

private struct ReconcileJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "reconcile"
  let outcome: ReconcileReport.Outcome
  let dryRun: Bool
  let canonicalChanged = false
  var themeID: String? = nil
  var generationID: String? = nil
  var inspections: [ReconcileInspection]? = nil
  var reconciliation: [AdapterResult]? = nil
  var error: String? = nil
}

private struct DoctorFinding: Encodable {
  enum Status: String, Encodable {
    case ok
    case warning
    case failure
  }

  let id: String
  let status: Status
  let message: String
}

private struct DoctorReport {
  let findings: [DoctorFinding]

  var succeeded: Bool {
    !findings.contains { $0.status == .failure }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(DoctorJSONReport(findings: findings))
    }
    return
      (["Macarchy doctor:"]
      + findings.map { "- \($0.id) [\($0.status.rawValue)]: \($0.message)" }
      + ["No changes made."])
      .joined(separator: "\n")
  }
}

private struct DoctorJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "doctor"
  let outcome: String
  let mutated = false
  let findings: [DoctorFinding]

  init(findings: [DoctorFinding]) {
    outcome = findings.contains { $0.status == .failure } ? "unhealthy" : "healthy"
    self.findings = findings
  }
}

private enum ThemeStatusReport {
  enum Outcome: String, Encodable {
    case current
    case inactive
    case reconciliationMissing = "reconciliation_missing"
    case reconciliationStale = "reconciliation_stale"
    case failure
  }

  case inactive
  case active(manifest: GenerationManifest, reconciliation: ReconciliationState)
  case activeFailure(manifest: GenerationManifest, error: String)
  case failure(String)

  var succeeded: Bool {
    switch self {
    case .inactive, .failure, .activeFailure:
      false
    case .active(_, .missing), .active(_, .stale):
      false
    case .active(_, .current(let record)):
      !hasRequiredReconciliationFailure(record.results)
    }
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .inactive:
      return "No active theme.\nCanonical state: absent."
    case .failure(let error):
      return "Theme status could not be read.\nError: \(error)"
    case .activeFailure(let manifest, let error):
      return [
        activeThemeLine(manifest),
        "Reconciliation: unreadable.",
        "Error: \(error)",
      ].joined(separator: "\n")
    case .active(let manifest, .missing):
      return [
        activeThemeLine(manifest),
        "Reconciliation: missing for the active generation.",
      ].joined(separator: "\n")
    case .active(let manifest, .current(let record)):
      return
        ([activeThemeLine(manifest), "Reconciliation: current."]
        + record.results.map(renderAdapterResult))
        .joined(separator: "\n")
    case .active(let manifest, .stale(_, let record)):
      return
        ([
          activeThemeLine(manifest),
          "Reconciliation: stale record for theme '\(record.themeID)' "
            + "(generation '\(record.generationID)').",
        ] + record.results.map(renderAdapterResult))
        .joined(separator: "\n")
    }
  }

  private var jsonReport: ThemeStatusJSONReport {
    switch self {
    case .inactive:
      ThemeStatusJSONReport(outcome: .inactive, active: false)
    case .failure(let error):
      ThemeStatusJSONReport(outcome: .failure, active: false, error: error)
    case .activeFailure(let manifest, let error):
      ThemeStatusJSONReport(
        outcome: .failure,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        error: error
      )
    case .active(let manifest, .missing):
      ThemeStatusJSONReport(
        outcome: .reconciliationMissing,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID
      )
    case .active(let manifest, .current(let record)):
      ThemeStatusJSONReport(
        outcome: .current,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record
      )
    case .active(let manifest, .stale(_, let record)):
      ThemeStatusJSONReport(
        outcome: .reconciliationStale,
        active: true,
        themeID: manifest.themeID,
        generationID: manifest.generationID,
        reconciliation: record
      )
    }
  }

  private func activeThemeLine(_ manifest: GenerationManifest) -> String {
    "Active theme: '\(manifest.themeID)' (generation '\(manifest.generationID)')."
  }
}

private struct ThemeStatusJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "theme_status"
  let outcome: ThemeStatusReport.Outcome
  let active: Bool
  var themeID: String? = nil
  var generationID: String? = nil
  var reconciliation: ReconciliationRecord? = nil
  var error: String? = nil
}

private enum ThemeSetReport {
  enum Outcome: String, Encodable {
    case dryRun = "dry_run"
    case success
    case precommitFailure = "precommit_failure"
    case requiredReconciliationFailure = "required_reconciliation_failure"
    case committedReconciliationError = "committed_reconciliation_error"
  }

  case dryRun(themeID: String)
  case precommitFailure(themeID: String, error: String)
  case committed(result: ThemeActivationResult, requiredFailure: Bool)
  case committedError(manifest: GenerationManifest, cause: String)

  var succeeded: Bool {
    switch self {
    case .dryRun, .committed(_, requiredFailure: false):
      true
    case .precommitFailure, .committed(_, requiredFailure: true), .committedError:
      false
    }
  }

  static func committed(_ result: ThemeActivationResult) -> Self {
    let requiredFailure = hasRequiredReconciliationFailure(result.reconciliation.results)
    return .committed(result: result, requiredFailure: requiredFailure)
  }

  static func precommitFailure(themeID: String, error: any Error) -> Self {
    .precommitFailure(themeID: themeID, error: String(describing: error))
  }

  func render(json: Bool) throws -> String {
    if json {
      return try renderJSON(jsonReport)
    }

    switch self {
    case .dryRun(let themeID):
      return [
        "Theme '\(themeID)' is valid.",
        "Kitty preflight passed.",
        "Canonical state: unchanged (dry run).",
        "No files written; no processes run.",
      ].joined(separator: "\n")
    case .precommitFailure(let themeID, let error):
      return [
        "Theme '\(themeID)' was not activated.",
        "Canonical state: unchanged.",
        "Error: \(error)",
      ].joined(separator: "\n")
    case .committed(let result, let requiredFailure):
      var lines = [
        "Activated '\(result.manifest.themeID)' as generation '\(result.manifest.generationID)'.",
        "Reconciliation:",
      ]
      lines.append(contentsOf: result.reconciliation.results.map(renderAdapterResult))
      if requiredFailure {
        lines.append("Required reconciliation failed; the commit was not rolled back.")
      }
      return lines.joined(separator: "\n")
    case .committedError(let manifest, let cause):
      return [
        "Committed '\(manifest.themeID)' as generation '\(manifest.generationID)'.",
        "Reconciliation could not complete: \(cause)",
        "The commit was not rolled back.",
      ].joined(separator: "\n")
    }
  }

  private var jsonReport: ThemeSetJSONReport {
    switch self {
    case .dryRun(let themeID):
      ThemeSetJSONReport(
        themeID: themeID,
        outcome: .dryRun,
        committed: false
      )
    case .precommitFailure(let themeID, let error):
      ThemeSetJSONReport(
        themeID: themeID,
        outcome: .precommitFailure,
        committed: false,
        error: error
      )
    case .committed(let result, let requiredFailure):
      ThemeSetJSONReport(
        themeID: result.manifest.themeID,
        outcome: requiredFailure ? .requiredReconciliationFailure : .success,
        committed: true,
        generationID: result.manifest.generationID,
        reconciliation: result.reconciliation.results,
        error: requiredFailure ? "Required reconciliation did not complete successfully" : nil
      )
    case .committedError(let manifest, let cause):
      ThemeSetJSONReport(
        themeID: manifest.themeID,
        outcome: .committedReconciliationError,
        committed: true,
        generationID: manifest.generationID,
        error: cause
      )
    }
  }

}

private struct ThemeSetJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "theme_set"
  let themeID: String
  let outcome: ThemeSetReport.Outcome
  let committed: Bool
  var generationID: String? = nil
  var reconciliation: [AdapterResult]? = nil
  var error: String? = nil
}

private func renderAdapterResult(_ result: AdapterResult) -> String {
  let message = result.message.map { ": \($0)" } ?? ""
  return
    "- \(result.adapterID) [\(result.requirement.rawValue)]: "
    + "\(result.status.rawValue)\(message)"
}

private func hasRequiredReconciliationFailure(_ results: [AdapterResult]) -> Bool {
  results.contains { result in
    result.requirement == .required
      && result.status != .applied
      && result.status != .restartRequired
  }
}

private func hasRequiredInspectionFailure(_ inspections: [AdapterInspection]) -> Bool {
  inspections.contains { inspection in
    inspection.requirement == .required && inspection.status != .ready
  }
}

private func inspectionFindingStatus(_ inspection: AdapterInspection) -> DoctorFinding.Status {
  guard inspection.status != .ready else { return .ok }
  return inspection.requirement == .required ? .failure : .warning
}

private func renderJSON<Value: Encodable>(_ value: Value) throws -> String {
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
