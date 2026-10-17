import Foundation
import ThemeCore

struct ConsumerSetupPlan {
  struct Step {
    enum Operation: String {
      case kittyInclude = "kitty.include"
      case batSelector = "bat.selector"
      case batThemeLink = "bat.theme-link"
      case ezaEnvironment = "eza.environment"
      case ezaThemeLink = "eza.theme-link"
      case btopSelector = "btop.selector"
      case btopThemeLink = "btop.theme-link"
      case yaziSelector = "yazi.selector"
      case yaziFlavorLink = "yazi.flavor-link"
      case yaziSyntaxLink = "yazi.syntax-link"
      case atuinSelector = "atuin.selector"
      case atuinThemeLink = "atuin.theme-link"
      case neovimWatcher = "neovim.watcher"
      case neovimThemeLink = "neovim.theme-link"
      case starshipBehavior = "starship.behavior"
      case starshipConfigurationLink = "starship.configuration-link"
      case piSelector = "pi.selector"
      case piThemeLink = "pi.theme-link"
      case herdrSelector = "herdr.selector"
      case tuicrSelector = "tuicr.selector"
      case tuicrThemeLink = "tuicr.theme-link"
      case tuicrSyntaxLink = "tuicr.syntax-link"
      case codexSelector = "codex.selector"
      case codexThemeLink = "codex.theme-link"
      case spicetifySelectors = "spicetify.selectors"
      case spicetifyColorLink = "spicetify.color-link"
    }

    /// How Macarchy owns the step's target, which also fixes the paths it may touch,
    /// the manifest record it may leave, and how teardown removes it.
    enum Mechanism {
      /// An externally owned prerequisite that teardown leaves alone.
      case external(teardownMessage: String)
      case regularFile(
        backup: URL, replacementName: String, label: String, read: (URL) throws -> Data)
      case themeLink(destination: URL, teardownLabel: String)
      case piSelector(replacementName: String)
      case spicetifySelectors(backup: URL, replacementName: String)
    }

    let operation: Operation
    let target: URL
    let mechanism: Mechanism
    let teardownRank: Int

    var id: String { operation.rawValue }

    var affectedPaths: [URL] {
      let parent = target.deletingLastPathComponent()
      return switch mechanism {
      case .external, .themeLink:
        [target]
      case .regularFile(let backup, let replacementName, _, _),
        .spicetifySelectors(let backup, let replacementName):
        [target, backup, parent.appending(path: replacementName)]
      case .piSelector(let replacementName):
        [target, parent.appending(path: replacementName)]
      }
    }

    var ownershipKind: SetupOwnershipRecord.Kind? {
      switch mechanism {
      case .external: nil
      case .regularFile: .regularFile
      case .themeLink: .symbolicLink
      case .piSelector: .jsonSelector
      case .spicetifySelectors: .spicetifySelection
      }
    }
  }

  typealias Execution = (
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult]

  enum ExecutionGroup {
    case independent
    case spicetify
  }

  let consumerID: ConsumerID
  let steps: [Step]
  private let manager: SetupOwnershipManager
  private let context: SetupOwnershipManager.Context
  private let executionGroup: ExecutionGroup

  init(
    consumerID: ConsumerID,
    steps: [Step],
    manager: SetupOwnershipManager,
    context: SetupOwnershipManager.Context,
    executionGroup: ExecutionGroup = .independent
  ) {
    self.consumerID = consumerID
    self.steps = steps
    self.manager = manager
    self.context = context
    self.executionGroup = executionGroup
  }

  func teardown(
    _ dryRun: Bool,
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    let operation: Execution = {
      try execute(dryRun: dryRun, records: &$0)
    }
    switch executionGroup {
    case .independent:
      return try operation(&records)
    case .spicetify:
      do {
        let results = try manager.withSpicetifyTeardownGroup(
          context: context, dryRun: dryRun, records: &records, execute: operation)
        return resultsInStepOrder(results)
      } catch let error as ConsumerSetupPlanPartialFailure {
        throw error.cause
      }
    }
  }

  private func execute(
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    let rankedSteps = steps.sorted {
      $0.teardownRank == $1.teardownRank ? $0.id < $1.id : $0.teardownRank < $1.teardownRank
    }
    var completed = [SetupIntegrationResult]()
    do {
      for step in rankedSteps {
        completed.append(
          try manager.teardown(step, context: context, dryRun: dryRun, records: &records))
      }
      return completed
    } catch let error as SetupOwnershipTransactionError {
      throw SetupOwnershipTransactionError(wrapping: error, completedResults: completed)
    } catch {
      guard !completed.isEmpty else { throw error }
      guard completed.contains(where: \.mutationAttempted) else {
        throw ConsumerSetupPlanPartialFailure(cause: error, completedResults: completed)
      }
      throw SetupOwnershipManager.afterCompletedMutations(
        error,
        completed: completed,
        homeDirectory: context.homeDirectory
      )
    }
  }

  private func resultsInStepOrder(
    _ results: [SetupIntegrationResult]
  ) -> [SetupIntegrationResult] {
    let order = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) })
    return results.sorted {
      order[$0.id, default: Int.max] < order[$1.id, default: Int.max]
    }
  }
}

struct ConsumerSetupPlanPartialFailure: Error {
  let cause: any Error
  let completedResults: [SetupIntegrationResult]
}

extension SetupOwnershipManager {
  func consumerSetupPlans(context: Context) -> [ConsumerSetupPlan] {
    let plans = [
      ConsumerSetupPlan(
        consumerID: .kitty,
        steps: [
          regularFileStep(
            .kittyInclude,
            target: context.kittyConfiguration,
            backup: context.backupURL,
            replacementName: context.replacementName,
            label: "Kitty include",
            read: { try readConfiguration($0) },
            teardownRank: 0
          )
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .bat,
        steps: [
          regularFileStep(
            .batSelector,
            target: context.batConfiguration,
            backup: context.batSelectorBackup,
            replacementName: context.batSelectorReplacementName,
            label: "bat selector",
            read: { try readConfiguration($0, id: Self.batSelectorID) },
            teardownRank: 1
          ),
          themeLinkStep(
            .batThemeLink,
            target: context.batThemeLink,
            destination: context.batThemeDestination,
            teardownLabel: "bat",
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .eza,
        steps: [
          regularFileStep(
            .ezaEnvironment,
            target: context.shellConfiguration,
            backup: context.ezaEnvironmentBackup,
            replacementName: context.ezaEnvironmentReplacementName,
            label: "eza environment",
            read: { try readConfiguration($0, id: Self.ezaEnvironmentID) },
            teardownRank: 1
          ),
          themeLinkStep(
            .ezaThemeLink,
            target: context.ezaThemeLink,
            destination: context.ezaThemeDestination,
            teardownLabel: "eza",
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .btop,
        steps: [
          externalStep(
            .btopSelector,
            target: context.btopConfiguration,
            teardownMessage: "No Macarchy-owned btop selector exists",
            teardownRank: 0
          ),
          themeLinkStep(
            .btopThemeLink,
            target: context.btopThemeLink,
            destination: context.btopThemeDestination,
            teardownLabel: "btop",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .yazi,
        steps: [
          regularFileStep(
            .yaziSelector,
            target: context.yaziConfiguration,
            backup: context.yaziSelectorBackup,
            replacementName: context.yaziSelectorReplacementName,
            label: "Yazi flavor selector",
            read: { try readConfiguration($0, id: Self.yaziSelectorID) },
            teardownRank: 0
          ),
          themeLinkStep(
            .yaziFlavorLink,
            target: context.yaziFlavorLink,
            destination: context.yaziFlavorDestination,
            teardownLabel: "Yazi flavor",
            teardownRank: 2
          ),
          themeLinkStep(
            .yaziSyntaxLink,
            target: context.yaziSyntaxLink,
            destination: context.yaziSyntaxDestination,
            teardownLabel: "Yazi syntax theme",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .atuin,
        steps: [
          regularFileStep(
            .atuinSelector,
            target: context.atuinConfiguration,
            backup: context.atuinSelectorBackup,
            replacementName: context.atuinSelectorReplacementName,
            label: "Atuin theme selector",
            read: { try readConfiguration($0, id: Self.atuinSelectorID) },
            teardownRank: 0
          ),
          themeLinkStep(
            .atuinThemeLink,
            target: context.atuinThemeLink,
            destination: context.atuinThemeDestination,
            teardownLabel: "Atuin",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .neovim,
        steps: [
          externalStep(
            .neovimWatcher,
            target: context.neovimWatcherConfiguration,
            teardownMessage: "The externally owned Neovim watcher is not a teardown target",
            teardownRank: 1
          ),
          themeLinkStep(
            .neovimThemeLink,
            target: context.neovimThemeLink,
            destination: context.neovimThemeDestination,
            teardownLabel: "Neovim theme",
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .starship,
        steps: [
          externalStep(
            .starshipBehavior,
            target: context.starshipBehavior,
            teardownMessage:
              "The externally owned Starship behavior source is not a teardown target",
            teardownRank: 1
          ),
          themeLinkStep(
            .starshipConfigurationLink,
            target: context.starshipConfigurationLink,
            destination: context.starshipBridgeDestination,
            teardownLabel: "Starship configuration",
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .pi,
        steps: [
          piSelectorStep(teardownRank: 0, context: context),
          themeLinkStep(
            .piThemeLink,
            target: context.piThemeLink,
            destination: context.piThemeDestination,
            teardownLabel: "Pi theme",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .herdr,
        steps: [
          externalStep(
            .herdrSelector,
            target: context.herdrConfiguration,
            teardownMessage: "Herdr's adapter-managed selector has no setup ownership record",
            teardownRank: 0
          )
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .tuicr,
        steps: [
          regularFileStep(
            .tuicrSelector,
            target: context.tuicrConfiguration,
            backup: context.tuicrSelectorBackup,
            replacementName: context.tuicrSelectorReplacementName,
            label: "tuicr theme selector",
            read: { try readConfiguration($0, id: Self.tuicrSelectorID) },
            teardownRank: 0
          ),
          themeLinkStep(
            .tuicrThemeLink,
            target: context.tuicrThemeLink,
            destination: context.tuicrThemeDestination,
            teardownLabel: "tuicr palette",
            teardownRank: 2
          ),
          themeLinkStep(
            .tuicrSyntaxLink,
            target: context.tuicrSyntaxLink,
            destination: context.tuicrSyntaxDestination,
            teardownLabel: "tuicr syntax theme",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .codex,
        steps: [
          regularFileStep(
            .codexSelector,
            target: context.codexConfiguration,
            backup: context.codexSelectorBackup,
            replacementName: context.codexSelectorReplacementName,
            label: "Codex TUI theme selector",
            read: { try readConfiguration($0, id: Self.codexSelectorID) },
            teardownRank: 0
          ),
          themeLinkStep(
            .codexThemeLink,
            target: context.codexThemeLink,
            destination: context.codexThemeDestination,
            teardownLabel: "Codex TextMate theme",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .spicetify,
        steps: [
          spicetifySelectorStep(teardownRank: 0, context: context),
          themeLinkStep(
            .spicetifyColorLink,
            target: context.spicetifyColorLink,
            destination: context.spicetifyColorDestination,
            teardownLabel: "Spicetify color scheme",
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context,
        executionGroup: .spicetify
      ),
    ]
    do {
      try ConsumerIntegrationConsistency.validateSetupPlans(plans)
    } catch {
      preconditionFailure("Invalid consumer setup catalog integration: \(error)")
    }
    return plans
  }

  func teardown(
    _ step: ConsumerSetupPlan.Step,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    switch step.mechanism {
    case .external(let teardownMessage):
      return integrationResult(
        id: step.id,
        target: step.target,
        status: .none,
        message: teardownMessage
      )
    case .regularFile(let backup, let replacementName, let label, let read):
      return try teardownRegularFile(
        id: step.id,
        target: step.target,
        backupURL: backup,
        replacementName: replacementName,
        label: label,
        read: read,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .themeLink(let destination, let teardownLabel):
      return try teardownThemeLink(
        id: step.id,
        target: step.target,
        destination: destination,
        label: teardownLabel,
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .piSelector:
      return try teardownPiSelector(context: context, dryRun: dryRun, records: &records)
    case .spicetifySelectors:
      return try teardownSpicetifySelectorOwnership(
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }
  }

  func validateRecord(
    _ record: SetupOwnershipRecord,
    for step: ConsumerSetupPlan.Step,
    context: Context
  ) throws {
    switch step.mechanism {
    case .external:
      throw SetupOwnershipError.invalidManifest("unknown integration \(record.id)")
    case .regularFile(let backup, _, _, _):
      try validateRegularFileRecord(
        record,
        target: step.target,
        backupURL: backup,
        context: context
      )
    case .themeLink(let destination, _):
      try validateThemeLinkRecord(record, target: step.target, destination: destination)
    case .piSelector:
      try validatePiSelectorRecord(record, context: context)
    case .spicetifySelectors(let backup, _):
      try validateSpicetifySelectorRecord(
        record,
        target: step.target,
        backupURL: backup,
        context: context
      )
    }
  }

  private func externalStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    teardownMessage: String,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .external(teardownMessage: teardownMessage),
      teardownRank: teardownRank
    )
  }

  private func regularFileStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    backup: URL,
    replacementName: String,
    label: String,
    read: @escaping (URL) throws -> Data,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .regularFile(
        backup: backup, replacementName: replacementName, label: label, read: read),
      teardownRank: teardownRank
    )
  }

  private func themeLinkStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    destination: URL,
    teardownLabel: String,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .themeLink(destination: destination, teardownLabel: teardownLabel),
      teardownRank: teardownRank
    )
  }

  private func piSelectorStep(
    teardownRank: Int,
    context: Context
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: .piSelector,
      target: context.piConfiguration,
      mechanism: .piSelector(replacementName: context.piSelectorReplacementName),
      teardownRank: teardownRank
    )
  }

  private func spicetifySelectorStep(
    teardownRank: Int,
    context: Context
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: .spicetifySelectors,
      target: context.spicetifyConfiguration,
      mechanism: .spicetifySelectors(
        backup: context.spicetifySelectorsBackup,
        replacementName: context.spicetifySelectorsReplacementName
      ),
      teardownRank: teardownRank
    )
  }
}
