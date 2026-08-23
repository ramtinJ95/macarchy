import ArgumentParser
import Foundation
import ThemeCore

@main
struct Macarchy: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macarchy",
    abstract: "A native, theme-driven macOS desktop shell.",
    version: "0.1.0-dev",
    subcommands: [Theme.self]
  )
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

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Option(help: "Kitty configuration file to preflight.")
    var kittyConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/kitty/kitty.conf").path

    @Flag(help: "Validate and describe outputs without writing files.")
    var dryRun = false

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    var kittyConfigurationURL: URL {
      URL(filePath: kittyConfig).standardizedFileURL
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
    read: { root in
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
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(jsonReport), as: UTF8.self)
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
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(jsonReport), as: UTF8.self)
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
