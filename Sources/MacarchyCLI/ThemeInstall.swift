import ArgumentParser
import Foundation
import ThemeCore

extension Theme {
  struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Safely install and activate a public GitHub Omarchy theme."
    )

    @OptionGroup var options: ActivationOptions

    @Argument(help: "Public HTTPS GitHub theme repository URL.")
    var source: String

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await ThemeInstallCommandRunner.live.execute(
        source: source,
        repository: options.repository,
        userThemesRoot: options.stateRootURL.appending(
          path: "themes",
          directoryHint: .isDirectory
        ),
        stateRoot: options.stateRootURL,
        consumerPaths: options.consumerPaths,
        dryRun: options.dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}

struct ThemeInstallCommandRunner: Sendable {
  let converter: OmarchyThemeConverter
  let installer: OmarchyThemePackageInstaller
  let activation: ThemeSetCommandRunner

  static let live = ThemeInstallCommandRunner(
    converter: OmarchyThemeConverter(),
    installer: OmarchyThemePackageInstaller(),
    activation: .live
  )

  func execute(
    source: String,
    repository: ThemeRepository,
    userThemesRoot: URL,
    stateRoot: URL,
    consumerPaths: ThemeConsumerPaths,
    dryRun: Bool,
    json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let parsedSource: OmarchyGitHubThemeSource
    do {
      parsedSource = try OmarchyGitHubThemeSource(source)
    } catch {
      let report = ThemeInstallReport.preparationFailure(
        themeID: nil,
        sourceURL: source,
        error: String(describing: error)
      )
      return (try report.render(json: json), report.succeeded)
    }
    do {
      try validateCollision(
        themeID: parsedSource.themeID,
        repository: repository,
        userThemesRoot: userThemesRoot
      )
      _ = try installer.wouldReplace(
        themeID: parsedSource.themeID,
        userThemesRoot: userThemesRoot
      )
    } catch {
      let report = ThemeInstallReport.preparationFailure(
        themeID: parsedSource.themeID,
        sourceURL: parsedSource.repositoryURL.absoluteString,
        error: String(describing: error)
      )
      return (try report.render(json: json), report.succeeded)
    }

    let preparedRoot = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-theme-install-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    do {
      try FileManager.default.createDirectory(
        at: preparedRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let converted = try converter.convert(
        from: source,
        to: preparedRoot.appending(path: "package", directoryHint: .isDirectory)
      )
      try activation.preflight(converted.package, stateRoot, consumerPaths)

      if dryRun {
        let replacing = try installer.wouldReplace(
          themeID: converted.package.id,
          userThemesRoot: userThemesRoot
        )
        try FileManager.default.removeItem(at: preparedRoot)
        let report = ThemeInstallReport.dryRun(
          conversion: converted.report,
          replacing: replacing
        )
        return (try report.render(json: json), report.succeeded)
      }

      return try await ThemePackageLock(root: stateRoot).withLock {
        try validateCollision(
          themeID: converted.package.id,
          repository: repository,
          userThemesRoot: userThemesRoot
        )
        let installation = try installer.install(
          package: converted.package,
          userThemesRoot: userThemesRoot
        )
        do {
          try FileManager.default.removeItem(at: preparedRoot)
        } catch let cleanupError {
          do {
            try installation.rollback()
          } catch let rollbackError {
            let activationReport = ThemeSetReport.precommitFailure(
              themeID: converted.package.id,
              error: OmarchyThemePackageInstallationError.filesystem(
                "cannot remove prepared package staging before activation: \(cleanupError)"
              )
            )
            let report = ThemeInstallReport.activation(
              conversion: converted.report,
              replaced: installation.replacedExistingPackage,
              activation: activationReport,
              transactionError: String(describing: rollbackError)
            )
            return (try report.render(json: json), report.succeeded)
          }
          throw OmarchyThemePackageInstallationError.filesystem(
            "cannot remove prepared package staging before activation: \(cleanupError)"
          )
        }

        let activationReport = try await activation.report(
          package: installation.package,
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          dryRun: false,
          expectedActiveGenerationID: nil
        )
        let transactionError: String?
        if activationReport.jsonReport.committed {
          do {
            try installation.finish()
            transactionError = nil
          } catch {
            transactionError = String(describing: error)
          }
        } else {
          do {
            try installation.rollback()
            transactionError = nil
          } catch {
            transactionError = String(describing: error)
          }
        }
        let report = ThemeInstallReport.activation(
          conversion: converted.report,
          replaced: installation.replacedExistingPackage,
          activation: activationReport,
          transactionError: transactionError
        )
        return (try report.render(json: json), report.succeeded)
      }
    } catch {
      let errorDescription = preparationFailure(
        error: error,
        preparedRoot: preparedRoot
      )
      let report = ThemeInstallReport.preparationFailure(
        themeID: parsedSource.themeID,
        sourceURL: parsedSource.repositoryURL.absoluteString,
        error: errorDescription
      )
      return (try report.render(json: json), report.succeeded)
    }
  }

  private func validateCollision(
    themeID: String,
    repository: ThemeRepository,
    userThemesRoot: URL
  ) throws {
    let destination = userThemesRoot.appending(
      path: themeID,
      directoryHint: .isDirectory
    ).standardizedFileURL
    let collision = try repository.packages().first { package in
      package.id == themeID && package.packageURL.standardizedFileURL != destination
    }
    guard let collision else {
      return
    }
    throw ThemeDiagnostic(
      location: .init(file: collision.packageURL.appending(path: "theme.toml")),
      field: "id",
      message:
        "Imported theme '\(themeID)' would shadow a built-in package; "
        + "choose a repository with a different derived identifier"
    )
  }

  private func preparationFailure(error: any Error, preparedRoot: URL) -> String {
    let original = String(describing: error)
    guard FileManager.default.fileExists(atPath: preparedRoot.path) else {
      return original
    }
    do {
      try FileManager.default.removeItem(at: preparedRoot)
      return original
    } catch let cleanupError {
      return
        "\(original); prepared-package cleanup also failed (\(cleanupError)); "
        + "recovery evidence remains at \(preparedRoot.path)"
    }
  }
}

private enum ThemeInstallReport {
  case preparationFailure(themeID: String?, sourceURL: String, error: String)
  case dryRun(conversion: OmarchyThemeConversionReport, replacing: Bool)
  case activation(
    conversion: OmarchyThemeConversionReport,
    replaced: Bool,
    activation: ThemeSetReport,
    transactionError: String?
  )

  var succeeded: Bool {
    switch self {
    case .dryRun:
      true
    case .preparationFailure:
      false
    case .activation(_, _, let activation, let transactionError):
      activation.succeeded && transactionError == nil
    }
  }

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(jsonReport) }
    switch self {
    case .preparationFailure(let themeID, _, let error):
      return [
        "Theme '\(themeID ?? "unknown")' was not installed.",
        "Installed package: unchanged.",
        "Canonical state: unchanged.",
        "Error: \(error)",
      ].joined(separator: "\n")
    case .dryRun(let conversion, let replacing):
      return [
        "Omarchy theme '\(conversion.themeID)' at commit '\(conversion.resolvedCommit)' is valid.",
        "Required adapter preflight passed.",
        "Installed package: unchanged (would \(replacing ? "replace" : "install")).",
        "Canonical state: unchanged (dry run).",
        "No persistent Macarchy state written; no consumer processes run.",
      ].joined(separator: "\n")
    case .activation(let conversion, let replaced, let activation, let transactionError):
      let activationJSON = activation.jsonReport
      let packageState: String
      if transactionError != nil, !activationJSON.committed {
        packageState = "Activation failed before commit; package rollback could not be verified for"
      } else if activationJSON.committed {
        packageState = replaced ? "Replaced imported theme" : "Installed imported theme"
      } else {
        packageState =
          replaced
          ? "Activation failed before commit; restored the previous installed package"
          : "Activation failed before commit; removed the uncommitted installed package"
      }
      var lines = [
        "\(packageState) '\(conversion.themeID)' from commit '\(conversion.resolvedCommit)'.",
        try activation.render(json: false),
      ]
      if let transactionError {
        lines.append("Package transaction error: \(transactionError)")
      }
      return lines.joined(separator: "\n")
    }
  }

  private var jsonReport: ThemeInstallJSONReport {
    switch self {
    case .preparationFailure(let themeID, let sourceURL, let error):
      return ThemeInstallJSONReport(
        outcome: "precommit_failure",
        themeID: themeID,
        sourceURL: sourceURL,
        installed: false,
        committed: false,
        error: error
      )
    case .dryRun(let conversion, let replacing):
      return ThemeInstallJSONReport(
        outcome: "dry_run",
        themeID: conversion.themeID,
        sourceURL: conversion.sourceURL,
        resolvedCommit: conversion.resolvedCommit,
        packageReplaced: replacing,
        installed: false,
        committed: false
      )
    case .activation(let conversion, let replaced, let activation, let transactionError):
      let activationJSON = activation.jsonReport
      let installed =
        transactionError != nil && !activationJSON.committed ? nil : activationJSON.committed
      return ThemeInstallJSONReport(
        outcome:
          transactionError == nil
          ? activationJSON.outcome.rawValue : "package_transaction_failure",
        themeID: conversion.themeID,
        sourceURL: conversion.sourceURL,
        resolvedCommit: conversion.resolvedCommit,
        packageReplaced: replaced,
        installed: installed,
        committed: activationJSON.committed,
        generationID: activationJSON.generationID,
        reconciliation: activationJSON.reconciliation,
        error: transactionError ?? activationJSON.error
      )
    }
  }
}

private struct ThemeInstallJSONReport: Encodable {
  let schemaVersion = 1
  let operation = "theme_install"
  let outcome: String
  let themeID: String?
  let sourceURL: String
  var resolvedCommit: String? = nil
  var packageReplaced: Bool? = nil
  let installed: Bool?
  let committed: Bool
  var generationID: String? = nil
  var reconciliation: [AdapterResult]? = nil
  var error: String? = nil

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome
    case themeID = "theme_id"
    case sourceURL = "source_url"
    case resolvedCommit = "resolved_commit"
    case packageReplaced = "package_replaced"
    case installed, committed
    case generationID = "generation_id"
    case reconciliation, error
  }
}
