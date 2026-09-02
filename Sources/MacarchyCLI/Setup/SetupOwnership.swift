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
  let lifecycle: KeybindingLifecycleAction?

  init(
    id: String,
    status: Status,
    target: String,
    message: String,
    mutationAttempted: Bool,
    lifecycle: KeybindingLifecycleAction? = nil
  ) {
    self.id = id
    self.status = status
    self.target = target
    self.message = message
    self.mutationAttempted = mutationAttempted
    self.lifecycle = lifecycle
  }

  var succeeded: Bool {
    status != .failed
  }
}

struct SetupOwnershipManager: Sendable {
  static let integrationID = ConsumerSetupPlan.Step.Operation.kittyInclude.rawValue
  static let batSelectorID = ConsumerSetupPlan.Step.Operation.batSelector.rawValue
  static let batThemeLinkID = ConsumerSetupPlan.Step.Operation.batThemeLink.rawValue
  static let ezaEnvironmentID = ConsumerSetupPlan.Step.Operation.ezaEnvironment.rawValue
  static let ezaThemeLinkID = ConsumerSetupPlan.Step.Operation.ezaThemeLink.rawValue
  static let btopSelectorID = ConsumerSetupPlan.Step.Operation.btopSelector.rawValue
  static let btopThemeLinkID = ConsumerSetupPlan.Step.Operation.btopThemeLink.rawValue
  static let yaziSelectorID = ConsumerSetupPlan.Step.Operation.yaziSelector.rawValue
  static let yaziFlavorLinkID = ConsumerSetupPlan.Step.Operation.yaziFlavorLink.rawValue
  static let yaziSyntaxLinkID = ConsumerSetupPlan.Step.Operation.yaziSyntaxLink.rawValue
  static let atuinSelectorID = ConsumerSetupPlan.Step.Operation.atuinSelector.rawValue
  static let atuinThemeLinkID = ConsumerSetupPlan.Step.Operation.atuinThemeLink.rawValue
  static let neovimWatcherID = ConsumerSetupPlan.Step.Operation.neovimWatcher.rawValue
  static let neovimThemeLinkID = ConsumerSetupPlan.Step.Operation.neovimThemeLink.rawValue
  static let starshipBehaviorID = ConsumerSetupPlan.Step.Operation.starshipBehavior.rawValue
  static let starshipConfigurationLinkID =
    ConsumerSetupPlan.Step.Operation.starshipConfigurationLink.rawValue
  static let piSelectorID = ConsumerSetupPlan.Step.Operation.piSelector.rawValue
  static let piThemeLinkID = ConsumerSetupPlan.Step.Operation.piThemeLink.rawValue
  static let herdrSelectorID = ConsumerSetupPlan.Step.Operation.herdrSelector.rawValue
  static let tuicrSelectorID = ConsumerSetupPlan.Step.Operation.tuicrSelector.rawValue
  static let tuicrThemeLinkID = ConsumerSetupPlan.Step.Operation.tuicrThemeLink.rawValue
  static let tuicrSyntaxLinkID = ConsumerSetupPlan.Step.Operation.tuicrSyntaxLink.rawValue
  static let codexSelectorID = ConsumerSetupPlan.Step.Operation.codexSelector.rawValue
  static let codexThemeLinkID = ConsumerSetupPlan.Step.Operation.codexThemeLink.rawValue
  static let spicetifySelectorsID =
    ConsumerSetupPlan.Step.Operation.spicetifySelectors.rawValue
  static let spicetifyColorLinkID =
    ConsumerSetupPlan.Step.Operation.spicetifyColorLink.rawValue
  static let maximumConfigurationSize = 1_048_576
  let faultInjector: @Sendable (SetupOwnershipCheckpoint) throws -> Void
  let keybindingRunner: KeybindingsApplyCommandRunner

  init(
    faultInjector: @escaping @Sendable (SetupOwnershipCheckpoint) throws -> Void = { _ in },
    keybindingLifecycle: KeybindingLifecycleController = .live
  ) {
    self.faultInjector = faultInjector
    keybindingRunner = KeybindingsApplyCommandRunner(lifecycle: keybindingLifecycle)
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
    let context = Context(homeDirectory: homeDirectory)
    return orderedResults(
      completed + [failureResult(error, homeDirectory: homeDirectory)],
      context: context
    )
  }

  private static func orderedResults(
    _ results: [SetupIntegrationResult],
    context: Context
  ) -> [SetupIntegrationResult] {
    let steps = SetupOwnershipManager().consumerSetupPlans(context: context).flatMap(\.steps)
    var order = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) })
    order[KeybindingProviderInspector.ownershipID] = steps.count
    return results.sorted {
      order[$0.id, default: Int.max] < order[$1.id, default: Int.max]
    }
  }

  private static func integrationIdentity(
    for url: URL,
    context: Context
  ) -> (id: String, target: String) {
    let steps = SetupOwnershipManager().consumerSetupPlans(context: context).flatMap(\.steps)
    if let step = steps.first(where: { step in
      step.affectedPaths.contains { $0.path == url.path }
    }) {
      return (step.id, url.path)
    }
    return ("setup.ownership", url.path)
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
      for plan in consumerSetupPlans(context: context) {
        results.append(contentsOf: try plan.setup(dryRun, &records))
      }
      return Self.orderedResults(results, context: context)
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(wrapping: error, completedResults: results)
    } catch let error as ConsumerSetupPlanPartialFailure {
      let completed = results + error.completedResults
      guard completed.contains(where: \.mutationAttempted) else { throw error.cause }
      let failure = Self.failureResult(error.cause, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error.cause,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: completed,
        failureMutationAttempted: false
      )
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
    var preflightRecords = records
    let pendingKeybindingTransaction = try KeybindingApplyTransactionStore(
      stateRoot: context.stateRoot
    ).read()
    let hasKeybindingState =
      records.contains(where: { $0.id == KeybindingProviderInspector.ownershipID })
      || pendingKeybindingTransaction != nil
    let keybindingPreflight: SetupIntegrationResult? =
      if hasKeybindingState {
        try keybindingRunner.teardownLocked(
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          dryRun: true
        )
      } else {
        nil
      }
    let integrationPreflight = try teardownIntegrations(
      context: context,
      dryRun: true,
      records: &preflightRecords
    )
    if dryRun {
      return Self.orderedResults(
        integrationPreflight + (keybindingPreflight.map { [$0] } ?? []),
        context: context
      )
    }
    let keybinding: SetupIntegrationResult? =
      if hasKeybindingState {
        try keybindingRunner.teardownLocked(
          stateRoot: context.stateRoot,
          homeDirectory: context.homeDirectory,
          dryRun: false
        )
      } else {
        nil
      }
    records = try readRecords(context: context)
    do {
      let integrations = try teardownIntegrations(
        context: context,
        dryRun: false,
        records: &records
      )
      return Self.orderedResults(
        integrations + (keybinding.map { [$0] } ?? []),
        context: context
      )
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(
        wrapping: error,
        completedResults: keybinding.map { [$0] } ?? []
      )
    } catch {
      guard let keybinding else { throw error }
      let failure = Self.failureResult(error, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: [keybinding],
        failureMutationAttempted: false
      )
    }
  }

  private func teardownIntegrations(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    var results = [SetupIntegrationResult]()
    do {
      for plan in consumerSetupPlans(context: context).reversed() {
        results.append(contentsOf: try plan.teardown(dryRun, &records))
      }
      return Self.orderedResults(results, context: context)
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(
        wrapping: error,
        completedResults: Self.orderedResults(results, context: context)
      )
    } catch let error as ConsumerSetupPlanPartialFailure {
      let completed = Self.orderedResults(
        results + error.completedResults,
        context: context
      )
      guard completed.contains(where: \.mutationAttempted) else { throw error.cause }
      let failure = Self.failureResult(error.cause, homeDirectory: context.homeDirectory)
      throw SetupOwnershipTransactionError(
        error.cause,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: completed,
        failureMutationAttempted: false
      )
    } catch {
      let completed = Self.orderedResults(results, context: context)
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

extension SetupOwnershipManager {
  func environmentOwns(_ ids: Set<EnvironmentEntryID>, context: Context) throws -> Bool {
    let store = EnvironmentStateStore(stateRoot: context.stateRoot)
    guard try store.readTransaction() == nil else {
      throw EnvironmentLifecycleError.blocked(
        "an interrupted environment transaction must be recovered before legacy setup"
      )
    }
    guard let ownership = try store.readOwnership()
    else { return false }
    return !ids.isDisjoint(with: Set(ownership.records.map(\.id)))
      || (ids.contains(.btopConfiguration) && ownership.btop != nil)
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
  static let softwareRemovalCommand =
    "HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "
    + "brew uninstall --formula \(HomebrewTapVersionReader.formula)"

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
    lines.append("User state under ~/.config/macarchy is preserved.")
    if integrations.allSatisfy(\.succeeded) {
      lines.append(
        dryRun
          ? "After successful teardown, remove the Homebrew formula separately with:"
          : "Remove the Homebrew formula separately with:"
      )
      lines.append("  \(Self.softwareRemovalCommand)")
    } else {
      lines.append("Resolve teardown failures before removing the Homebrew formula.")
    }
    return lines.joined(separator: "\n")
  }
}
