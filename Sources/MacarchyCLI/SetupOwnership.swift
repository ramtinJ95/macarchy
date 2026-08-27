import Foundation
import ThemeCore

enum SetupOwnershipCheckpoint: Equatable, Sendable {
  case manifestPrepared
  case backupWritten
  case replacementReady
  case replacementSwapped
  case targetWritten
  case teardownReady
}

enum SetupOwnershipError: Error, CustomStringConvertible, Equatable, Sendable {
  case conflictingKittyInclude(URL)
  case conflictingDirective(String, URL)
  case conflictingThemeLink(String, URL)
  case configurationIsExternallyOwned(String, URL)
  case configurationTooLarge(String, URL)
  case corruptBackup(URL)
  case invalidManifest(String)
  case invalidConfiguration(String, URL, String)
  case installedConfigurationTooLarge(String, URL)
  case kittyConfigurationIsExternallyOwned(URL)
  case kittyConfigurationTooLarge(URL)
  case missingConfiguration(String, URL)
  case missingExternalDirective(String, URL)
  case missingIntegrationParent(String, URL)
  case missingKittyConfiguration(URL)
  case orphanedBackup(URL)
  case orphanedReplacement(URL)
  case ownershipDrift(URL)
  case system(String, URL, String)
  case unreadableConfiguration(String, URL)
  case unreadableKittyConfiguration(URL)

  var description: String {
    switch self {
    case .conflictingKittyInclude(let url):
      "Kitty configuration at \(url.path) contains a conflicting Macarchy include"
    case .conflictingDirective(let id, let url):
      "Configuration at \(url.path) contains a conflicting \(id) directive"
    case .conflictingThemeLink(let id, let url):
      "Theme path at \(url.path) conflicts with the required \(id) link"
    case .configurationIsExternallyOwned(let id, let url):
      "Configuration for \(id) at \(url.path) is symlinked or inside a symlinked directory; update its external source instead"
    case .configurationTooLarge(let id, let url):
      "Configuration for \(id) at \(url.path) exceeds 1 MiB"
    case .corruptBackup(let url):
      "Macarchy-owned backup at \(url.path) is missing or corrupt"
    case .invalidManifest(let reason):
      "Setup ownership manifest is invalid: \(reason)"
    case .invalidConfiguration(let id, let url, let reason):
      "Configuration for \(id) at \(url.path) is invalid: \(reason)"
    case .installedConfigurationTooLarge(let id, let url):
      "Adding the \(id) directive would make \(url.path) exceed 1 MiB"
    case .kittyConfigurationIsExternallyOwned(let url):
      "Kitty configuration at \(url.path) is symlinked or inside a symlinked directory; update its external source instead"
    case .kittyConfigurationTooLarge(let url):
      "Kitty configuration at \(url.path) exceeds 1 MiB"
    case .missingKittyConfiguration(let url):
      "Kitty configuration must already exist as an ordinary file at \(url.path)"
    case .missingConfiguration(let id, let url):
      "Configuration for \(id) must already exist as an ordinary file at \(url.path)"
    case .missingExternalDirective(let id, let url):
      "Configuration at \(url.path) must contain the exact externally owned \(id) directive"
    case .missingIntegrationParent(let id, let url):
      "The required external parent directory for \(id) must exist at \(url.path)"
    case .orphanedBackup(let url):
      "Setup backup exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .orphanedReplacement(let url):
      "Setup replacement residue exists without an ownership manifest at \(url.path); refusing to overwrite recovery evidence"
    case .ownershipDrift(let url):
      "Macarchy-owned integration at \(url.path) changed after setup; refusing to overwrite it"
    case .system(let operation, let url, let cause):
      "Cannot \(operation) \(url.path): \(cause)"
    case .unreadableConfiguration(let id, let url):
      "Cannot read configuration for \(id) at \(url.path) as UTF-8"
    case .unreadableKittyConfiguration(let url):
      "Cannot read Kitty configuration at \(url.path) as UTF-8"
    }
  }

}

struct SetupOwnershipTransactionError: Error, CustomStringConvertible, Sendable {
  let cause: String
  let integrationID: String
  let target: String
  let completedResults: [SetupIntegrationResult]
  let failureMutationAttempted: Bool

  init(
    _ error: any Error,
    integrationID: String,
    target: URL,
    completedResults: [SetupIntegrationResult] = [],
    failureMutationAttempted: Bool = true
  ) {
    cause = String(describing: error)
    self.integrationID = integrationID
    self.target = target.path
    self.completedResults = completedResults
    self.failureMutationAttempted = failureMutationAttempted
  }

  init(
    wrapping error: SetupOwnershipTransactionError,
    completedResults: [SetupIntegrationResult]
  ) {
    cause = error.cause
    integrationID = error.integrationID
    target = error.target
    self.completedResults = completedResults + error.completedResults
    failureMutationAttempted = error.failureMutationAttempted
  }

  var description: String { cause }
}

struct SetupIntegrationResult: Encodable, Sendable {
  enum Status: String, Encodable, Sendable {
    case disabled
    case external
    case failed
    case none
    case owned
    case planned
    case removed
  }

  let id: String
  let status: Status
  let target: String
  let message: String
  let mutationAttempted: Bool

  var succeeded: Bool {
    status != .failed
  }
}

struct SetupOwnershipManager: Sendable {
  static let integrationID = "kitty.include"
  static let batSelectorID = "bat.selector"
  static let batThemeLinkID = "bat.theme-link"
  static let ezaEnvironmentID = "eza.environment"
  static let ezaThemeLinkID = "eza.theme-link"
  static let btopSelectorID = "btop.selector"
  static let btopThemeLinkID = "btop.theme-link"
  static let yaziSelectorID = "yazi.selector"
  static let yaziFlavorLinkID = "yazi.flavor-link"
  static let yaziSyntaxLinkID = "yazi.syntax-link"
  static let atuinSelectorID = "atuin.selector"
  static let atuinThemeLinkID = "atuin.theme-link"
  static let neovimWatcherID = "neovim.watcher"
  static let neovimThemeLinkID = "neovim.theme-link"
  static let starshipBehaviorID = "starship.behavior"
  static let starshipConfigurationLinkID = "starship.configuration-link"
  static let piSelectorID = "pi.selector"
  static let piThemeLinkID = "pi.theme-link"
  static let herdrSelectorID = "herdr.selector"
  static let tuicrSelectorID = "tuicr.selector"
  static let tuicrThemeLinkID = "tuicr.theme-link"
  static let tuicrSyntaxLinkID = "tuicr.syntax-link"
  static let codexSelectorID = "codex.selector"
  static let codexThemeLinkID = "codex.theme-link"
  static let spicetifySelectorsID = "spicetify.selectors"
  static let spicetifyColorLinkID = "spicetify.color-link"
  static let maximumConfigurationSize = 1_048_576
  private static let integrationOrder = [
    integrationID,
    batSelectorID,
    batThemeLinkID,
    ezaEnvironmentID,
    ezaThemeLinkID,
    btopSelectorID,
    btopThemeLinkID,
    yaziSelectorID,
    yaziFlavorLinkID,
    yaziSyntaxLinkID,
    atuinSelectorID,
    atuinThemeLinkID,
    neovimWatcherID,
    neovimThemeLinkID,
    starshipBehaviorID,
    starshipConfigurationLinkID,
    piSelectorID,
    piThemeLinkID,
    herdrSelectorID,
    tuicrSelectorID,
    tuicrThemeLinkID,
    tuicrSyntaxLinkID,
    codexSelectorID,
    codexThemeLinkID,
    spicetifySelectorsID,
    spicetifyColorLinkID,
  ]

  let faultInjector: @Sendable (SetupOwnershipCheckpoint) throws -> Void

  init(
    faultInjector: @escaping @Sendable (SetupOwnershipCheckpoint) throws -> Void = { _ in }
  ) {
    self.faultInjector = faultInjector
  }

  static func failureResult(_ error: any Error, homeDirectory: URL) -> SetupIntegrationResult {
    let context = Context(homeDirectory: homeDirectory)
    let mutationAttempted =
      (error as? SetupOwnershipTransactionError)?.failureMutationAttempted ?? false
    let identity: (id: String, target: String)
    if let transaction = error as? SetupOwnershipTransactionError {
      identity = (transaction.integrationID, transaction.target)
    } else if let ownershipError = error as? SetupOwnershipError {
      switch ownershipError {
      case .conflictingDirective(let id, let url),
        .conflictingThemeLink(let id, let url),
        .configurationIsExternallyOwned(let id, let url),
        .configurationTooLarge(let id, let url),
        .invalidConfiguration(let id, let url, _),
        .installedConfigurationTooLarge(let id, let url),
        .missingConfiguration(let id, let url),
        .missingExternalDirective(let id, let url),
        .missingIntegrationParent(let id, let url),
        .unreadableConfiguration(let id, let url):
        identity = (id, url.path)
      case .ownershipDrift(let url):
        identity = integrationIdentity(for: url, context: context)
      case .corruptBackup(let url), .orphanedBackup(let url), .orphanedReplacement(let url):
        identity = integrationIdentity(for: url, context: context)
      case .system(_, let url, _):
        identity = integrationIdentity(for: url, context: context)
      case .invalidManifest:
        identity = ("setup.ownership", context.manifestURL.path)
      default:
        identity = (integrationID, context.kittyConfiguration.path)
      }
    } else {
      identity = ("setup.ownership", context.manifestURL.path)
    }
    return SetupIntegrationResult(
      id: identity.id,
      status: .failed,
      target: identity.target,
      message: String(describing: error),
      mutationAttempted: mutationAttempted
    )
  }

  static func failureResults(
    _ error: any Error,
    homeDirectory: URL
  ) -> [SetupIntegrationResult] {
    let completed = (error as? SetupOwnershipTransactionError)?.completedResults ?? []
    return orderedResults(completed + [failureResult(error, homeDirectory: homeDirectory)])
  }

  private static func orderedResults(
    _ results: [SetupIntegrationResult]
  ) -> [SetupIntegrationResult] {
    let order = Dictionary(uniqueKeysWithValues: integrationOrder.enumerated().map { ($1, $0) })
    return results.sorted {
      order[$0.id, default: Int.max] < order[$1.id, default: Int.max]
    }
  }

  private static func integrationIdentity(
    for url: URL,
    context: Context
  ) -> (id: String, target: String) {
    switch url.path {
    case context.batConfiguration.path, context.batSelectorBackup.path,
      context.batConfiguration.deletingLastPathComponent()
      .appending(path: context.batSelectorReplacementName).path:
      (batSelectorID, url.path)
    case context.batThemeLink.path:
      (batThemeLinkID, url.path)
    case context.shellConfiguration.path, context.ezaEnvironmentBackup.path,
      context.shellConfiguration.deletingLastPathComponent()
      .appending(path: context.ezaEnvironmentReplacementName).path:
      (ezaEnvironmentID, url.path)
    case context.ezaThemeLink.path:
      (ezaThemeLinkID, url.path)
    case context.btopConfiguration.path:
      (btopSelectorID, url.path)
    case context.btopThemeLink.path:
      (btopThemeLinkID, url.path)
    case context.yaziConfiguration.path, context.yaziSelectorBackup.path,
      context.yaziConfiguration.deletingLastPathComponent()
      .appending(path: context.yaziSelectorReplacementName).path:
      (yaziSelectorID, url.path)
    case context.yaziFlavorLink.path:
      (yaziFlavorLinkID, url.path)
    case context.yaziSyntaxLink.path:
      (yaziSyntaxLinkID, url.path)
    case context.atuinConfiguration.path, context.atuinSelectorBackup.path,
      context.atuinConfiguration.deletingLastPathComponent()
      .appending(path: context.atuinSelectorReplacementName).path:
      (atuinSelectorID, url.path)
    case context.atuinThemeLink.path:
      (atuinThemeLinkID, url.path)
    case context.neovimWatcherConfiguration.path:
      (neovimWatcherID, url.path)
    case context.neovimThemeLink.path:
      (neovimThemeLinkID, url.path)
    case context.starshipBehavior.path:
      (starshipBehaviorID, url.path)
    case context.starshipConfigurationLink.path:
      (starshipConfigurationLinkID, url.path)
    case context.piConfiguration.path,
      context.piConfiguration.deletingLastPathComponent()
      .appending(path: context.piSelectorReplacementName).path:
      (piSelectorID, url.path)
    case context.piThemeLink.path:
      (piThemeLinkID, url.path)
    case context.herdrConfiguration.path:
      (herdrSelectorID, url.path)
    case context.tuicrConfiguration.path, context.tuicrSelectorBackup.path,
      context.tuicrConfiguration.deletingLastPathComponent()
      .appending(path: context.tuicrSelectorReplacementName).path:
      (tuicrSelectorID, url.path)
    case context.tuicrThemeLink.path:
      (tuicrThemeLinkID, url.path)
    case context.tuicrSyntaxLink.path:
      (tuicrSyntaxLinkID, url.path)
    case context.codexConfiguration.path, context.codexSelectorBackup.path,
      context.codexConfiguration.deletingLastPathComponent()
      .appending(path: context.codexSelectorReplacementName).path:
      (codexSelectorID, url.path)
    case context.codexThemeLink.path:
      (codexThemeLinkID, url.path)
    case context.spicetifyConfiguration.path, context.spicetifySelectorsBackup.path,
      context.spicetifyConfiguration.deletingLastPathComponent()
      .appending(path: context.spicetifySelectorsReplacementName).path:
      (spicetifySelectorsID, url.path)
    case context.spicetifyColorLink.path:
      (spicetifyColorLinkID, url.path)
    case context.kittyConfiguration.path, context.backupURL.path, context.replacementURL.path:
      (integrationID, url.path)
    default:
      ("setup.ownership", url.path)
    }
  }

  func setup(
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try setup(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try setup(context: context, dryRun: false)
    }
  }

  func teardown(homeDirectory: URL, dryRun: Bool) throws -> [SetupIntegrationResult] {
    let context = Context(homeDirectory: homeDirectory)
    if dryRun { return try teardown(context: context, dryRun: true) }
    return try ActivationLock(root: context.stateRoot).withLock {
      try teardown(context: context, dryRun: false)
    }
  }

  private func setup(
    context: Context,
    dryRun: Bool
  ) throws -> [SetupIntegrationResult] {
    var records = try readRecords(context: context)
    var results = [SetupIntegrationResult]()
    do {
      results.append(try setupKitty(context: context, dryRun: dryRun, records: &records))
      results.append(try setupBatSelector(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupBatThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupEzaEnvironment(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupEzaThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupBtopSelector(context: context))
      results.append(
        try setupBtopThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupYaziFlavorLink(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupYaziSyntaxLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupYaziSelector(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupAtuinThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupAtuinSelector(context: context, dryRun: dryRun, records: &records))
      results.append(try setupNeovimWatcher(context: context))
      results.append(
        try setupNeovimThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupStarshipBehavior(context: context))
      results.append(
        try setupStarshipConfigurationLink(
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try setupPiThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupPiSelector(context: context, dryRun: dryRun, records: &records))
      results.append(try setupHerdrSelector(context: context))
      results.append(
        try setupTuicrThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupTuicrSyntaxLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupTuicrSelector(context: context, dryRun: dryRun, records: &records))
      results.append(
        try setupCodexThemeLink(context: context, dryRun: dryRun, records: &records))
      results.append(try setupCodexSelector(context: context, dryRun: dryRun, records: &records))
      results.append(
        contentsOf: try setupSpicetifyIntegrations(
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      return Self.orderedResults(results)
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(wrapping: error, completedResults: results)
    } catch {
      guard results.contains(where: \.mutationAttempted) else { throw error }
      let failure = Self.failureResult(error, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: results,
        failureMutationAttempted: false
      )
    }
  }

  private func teardown(context: Context, dryRun: Bool) throws -> [SetupIntegrationResult] {
    var records = try readRecords(context: context)
    if !dryRun {
      var preflightRecords = records
      _ = try teardownIntegrations(
        context: context,
        dryRun: true,
        records: &preflightRecords
      )
    }
    return try teardownIntegrations(context: context, dryRun: dryRun, records: &records)
  }

  private func teardownIntegrations(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    var results = [SetupIntegrationResult]()
    do {
      results.append(
        contentsOf: try teardownSpicetifyIntegrations(
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownCodexSelector(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownCodexThemeLink(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownTuicrSelector(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownTuicrSyntaxLink(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownTuicrThemeLink(context: context, dryRun: dryRun, records: &records)
      )
      results.append(teardownHerdrSelector(context: context))
      results.append(
        try teardownPiSelector(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownPiThemeLink(context: context, dryRun: dryRun, records: &records)
      )
      results.append(
        try teardownThemeLink(
          id: Self.starshipConfigurationLinkID,
          target: context.starshipConfigurationLink,
          destination: context.starshipBridgeDestination,
          label: "Starship configuration",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(teardownStarshipBehavior(context: context))
      results.append(
        try teardownThemeLink(
          id: Self.neovimThemeLinkID,
          target: context.neovimThemeLink,
          destination: context.neovimThemeDestination,
          label: "Neovim theme",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(teardownNeovimWatcher(context: context))
      results.append(
        try teardownRegularFile(
          id: Self.atuinSelectorID,
          target: context.atuinConfiguration,
          backupURL: context.atuinSelectorBackup,
          replacementName: context.atuinSelectorReplacementName,
          label: "Atuin theme selector",
          read: { try readConfiguration($0, id: Self.atuinSelectorID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.atuinThemeLinkID,
          target: context.atuinThemeLink,
          destination: context.atuinThemeDestination,
          label: "Atuin",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownRegularFile(
          id: Self.yaziSelectorID,
          target: context.yaziConfiguration,
          backupURL: context.yaziSelectorBackup,
          replacementName: context.yaziSelectorReplacementName,
          label: "Yazi flavor selector",
          read: { try readConfiguration($0, id: Self.yaziSelectorID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.yaziSyntaxLinkID,
          target: context.yaziSyntaxLink,
          destination: context.yaziSyntaxDestination,
          label: "Yazi syntax theme",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.yaziFlavorLinkID,
          target: context.yaziFlavorLink,
          destination: context.yaziFlavorDestination,
          label: "Yazi flavor",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        integrationResult(
          id: Self.btopSelectorID,
          target: context.btopConfiguration,
          status: .none,
          message: "No Macarchy-owned btop selector exists"
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.btopThemeLinkID,
          target: context.btopThemeLink,
          destination: context.btopThemeDestination,
          label: "btop",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.ezaThemeLinkID,
          target: context.ezaThemeLink,
          destination: context.ezaThemeDestination,
          label: "eza",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownRegularFile(
          id: Self.ezaEnvironmentID,
          target: context.shellConfiguration,
          backupURL: context.ezaEnvironmentBackup,
          replacementName: context.ezaEnvironmentReplacementName,
          label: "eza environment",
          read: { try readConfiguration($0, id: Self.ezaEnvironmentID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownThemeLink(
          id: Self.batThemeLinkID,
          target: context.batThemeLink,
          destination: context.batThemeDestination,
          label: "bat",
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownRegularFile(
          id: Self.batSelectorID,
          target: context.batConfiguration,
          backupURL: context.batSelectorBackup,
          replacementName: context.batSelectorReplacementName,
          label: "bat selector",
          read: { try readConfiguration($0, id: Self.batSelectorID) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      results.append(
        try teardownRegularFile(
          id: Self.integrationID,
          target: context.kittyConfiguration,
          backupURL: context.backupURL,
          replacementName: context.replacementName,
          label: "Kitty include",
          read: { try readConfiguration($0) },
          context: context,
          dryRun: dryRun,
          records: &records
        )
      )
      return Self.orderedResults(results)
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(
        wrapping: error,
        completedResults: Self.orderedResults(results)
      )
    } catch {
      let completed = Self.orderedResults(results)
      guard completed.contains(where: \.mutationAttempted) else { throw error }
      let failure = Self.failureResult(error, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: completed,
        failureMutationAttempted: false
      )
    }
  }

  func integrationResult(
    id: String,
    target: URL,
    status: SetupIntegrationResult.Status,
    message: String,
    mutationAttempted: Bool = false
  ) -> SetupIntegrationResult {
    SetupIntegrationResult(
      id: id,
      status: status,
      target: target.path,
      message: message,
      mutationAttempted: mutationAttempted
    )
  }

}

struct TeardownCommandRunner: Sendable {
  let ownershipManager: SetupOwnershipManager

  static let live = TeardownCommandRunner(ownershipManager: SetupOwnershipManager())

  func execute(
    homeDirectory: URL,
    dryRun: Bool,
    json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let integrations: [SetupIntegrationResult]
    do {
      integrations = try ownershipManager.teardown(
        homeDirectory: homeDirectory,
        dryRun: dryRun
      )
    } catch {
      integrations = SetupOwnershipManager.failureResults(error, homeDirectory: homeDirectory)
    }
    let report = TeardownReport(dryRun: dryRun, integrations: integrations)
    return (try report.render(json: json), integrations.allSatisfy(\.succeeded))
  }
}

private struct TeardownReport: Encodable {
  let schemaVersion = 1
  let operation = "teardown"
  let dryRun: Bool
  let integrations: [SetupIntegrationResult]

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(self) }
    let mutation =
      integrations.contains(where: \.mutationAttempted)
      ? "Recorded integration mutation attempted." : "No changes made."
    var lines = [
      "Macarchy teardown\(dryRun ? " (dry run)" : ""):"
    ]
    lines.append(
      contentsOf: integrations.map {
        "- \($0.id) [\($0.status.rawValue)]: \($0.message)"
      }
    )
    lines.append(mutation)
    return lines.joined(separator: "\n")
  }
}
