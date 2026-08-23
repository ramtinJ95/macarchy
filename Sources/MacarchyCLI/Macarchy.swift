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
    subcommands: [List.self, Set.self]
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

  struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate a theme and reconcile its consumers."
    )

    @OptionGroup var roots: ThemeRootOptions

    @Argument(help: "Theme package identifier.")
    var themeID: String

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Option(help: "Kitty configuration file to preflight.")
    var kittyConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/kitty/kitty.conf").path

    @Flag(help: "Validate and describe outputs without writing files.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let stateRootURL = URL(
        filePath: stateRoot,
        directoryHint: .isDirectory
      ).standardizedFileURL
      let execution = try await ThemeSetCommandRunner.live.execute(
        repository: roots.repository(
          userRoot: stateRootURL.appending(path: "themes", directoryHint: .isDirectory)
        ),
        themeID: themeID,
        stateRoot: stateRootURL,
        kittyConfigurationURL: URL(filePath: kittyConfig).standardizedFileURL,
        dryRun: dryRun,
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
  let activate: @Sendable (ThemePackage, URL, URL) async throws -> ThemeActivationResult

  static let live = ThemeSetCommandRunner(
    preflight: { package, stateRoot, kittyConfigurationURL in
      try ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).preflight(package: package)
    },
    activate: { package, stateRoot, kittyConfigurationURL in
      try await ThemeActivationCoordinator(
        root: stateRoot,
        kittyConfigurationURL: kittyConfigurationURL
      ).activate(package: package)
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
    let report: ThemeSetReport

    do {
      let package = try repository.package(id: themeID)
      if dryRun {
        try preflight(package, stateRoot, kittyConfigurationURL)
        report = .dryRun(themeID: package.id)
      } else {
        do {
          let result = try await activate(package, stateRoot, kittyConfigurationURL)
          report = .committed(result)
        } catch let error as ThemeCommittedWithReconciliationError {
          report = .committedError(manifest: error.manifest, cause: error.cause)
        } catch {
          report = .precommitFailure(themeID: themeID, error: error)
        }
      }
    } catch {
      report = .precommitFailure(themeID: themeID, error: error)
    }

    return (
      output: try report.render(json: json),
      succeeded: report.succeeded
    )
  }
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
    let requiredFailure = result.reconciliation.results.contains { result in
      result.requirement == .required
        && result.status != .applied
        && result.status != .restartRequired
    }
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
      lines.append(contentsOf: result.reconciliation.results.map(Self.renderResult))
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

  private static func renderResult(_ result: AdapterResult) -> String {
    let message = result.message.map { ": \($0)" } ?? ""
    return
      "- \(result.adapterID) [\(result.requirement.rawValue)]: "
      + "\(result.status.rawValue)\(message)"
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
