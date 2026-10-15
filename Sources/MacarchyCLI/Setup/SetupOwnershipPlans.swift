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
      /// An externally owned prerequisite that setup verifies and teardown leaves alone.
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
    let setupRank: Int
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

  func setup(
    _ dryRun: Bool,
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    try run(.setup, dryRun: dryRun, records: &records)
  }

  func teardown(
    _ dryRun: Bool,
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    try run(.teardown, dryRun: dryRun, records: &records)
  }

  private func run(
    _ phase: Phase,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    let operation: Execution = {
      try execute(phase, dryRun: dryRun, records: &$0)
    }
    switch executionGroup {
    case .independent:
      return try operation(&records)
    case .spicetify:
      do {
        let results =
          switch phase {
          case .setup:
            try manager.withSpicetifySetupGroup(
              context: context, dryRun: dryRun, records: &records, execute: operation)
          case .teardown:
            try manager.withSpicetifyTeardownGroup(
              context: context, dryRun: dryRun, records: &records, execute: operation)
          }
        return resultsInStepOrder(results)
      } catch let error as ConsumerSetupPlanPartialFailure {
        throw error.cause
      }
    }
  }

  private enum Phase {
    case setup
    case teardown
  }

  private func execute(
    _ phase: Phase,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    let rankedSteps = steps.sorted {
      let lhsRank = phase == .setup ? $0.setupRank : $0.teardownRank
      let rhsRank = phase == .setup ? $1.setupRank : $1.teardownRank
      return lhsRank == rhsRank ? $0.id < $1.id : lhsRank < rhsRank
    }
    var completed = [SetupIntegrationResult]()
    do {
      for step in rankedSteps {
        let result: SetupIntegrationResult
        switch phase {
        case .setup:
          result = try manager.setup(step, context: context, dryRun: dryRun, records: &records)
        case .teardown:
          result = try manager.teardown(step, context: context, dryRun: dryRun, records: &records)
        }
        completed.append(result)
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
            setupRank: 0,
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
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .batThemeLink,
            target: context.batThemeLink,
            destination: context.batThemeDestination,
            teardownLabel: "bat",
            setupRank: 1,
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
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .ezaThemeLink,
            target: context.ezaThemeLink,
            destination: context.ezaThemeDestination,
            teardownLabel: "eza",
            setupRank: 1,
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
            setupRank: 0,
            teardownRank: 0
          ),
          themeLinkStep(
            .btopThemeLink,
            target: context.btopThemeLink,
            destination: context.btopThemeDestination,
            teardownLabel: "btop",
            setupRank: 1,
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
            setupRank: 2,
            teardownRank: 0
          ),
          themeLinkStep(
            .yaziFlavorLink,
            target: context.yaziFlavorLink,
            destination: context.yaziFlavorDestination,
            teardownLabel: "Yazi flavor",
            setupRank: 0,
            teardownRank: 2
          ),
          themeLinkStep(
            .yaziSyntaxLink,
            target: context.yaziSyntaxLink,
            destination: context.yaziSyntaxDestination,
            teardownLabel: "Yazi syntax theme",
            setupRank: 1,
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
            setupRank: 1,
            teardownRank: 0
          ),
          themeLinkStep(
            .atuinThemeLink,
            target: context.atuinThemeLink,
            destination: context.atuinThemeDestination,
            teardownLabel: "Atuin",
            setupRank: 0,
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
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .neovimThemeLink,
            target: context.neovimThemeLink,
            destination: context.neovimThemeDestination,
            teardownLabel: "Neovim theme",
            setupRank: 1,
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
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .starshipConfigurationLink,
            target: context.starshipConfigurationLink,
            destination: context.starshipBridgeDestination,
            teardownLabel: "Starship configuration",
            setupRank: 1,
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .pi,
        steps: [
          piSelectorStep(setupRank: 1, teardownRank: 0, context: context),
          themeLinkStep(
            .piThemeLink,
            target: context.piThemeLink,
            destination: context.piThemeDestination,
            teardownLabel: "Pi theme",
            setupRank: 0,
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
            setupRank: 0,
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
            setupRank: 2,
            teardownRank: 0
          ),
          themeLinkStep(
            .tuicrThemeLink,
            target: context.tuicrThemeLink,
            destination: context.tuicrThemeDestination,
            teardownLabel: "tuicr palette",
            setupRank: 0,
            teardownRank: 2
          ),
          themeLinkStep(
            .tuicrSyntaxLink,
            target: context.tuicrSyntaxLink,
            destination: context.tuicrSyntaxDestination,
            teardownLabel: "tuicr syntax theme",
            setupRank: 1,
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
            setupRank: 1,
            teardownRank: 0
          ),
          themeLinkStep(
            .codexThemeLink,
            target: context.codexThemeLink,
            destination: context.codexThemeDestination,
            teardownLabel: "Codex TextMate theme",
            setupRank: 0,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: .spicetify,
        steps: [
          spicetifySelectorStep(setupRank: 1, teardownRank: 0, context: context),
          themeLinkStep(
            .spicetifyColorLink,
            target: context.spicetifyColorLink,
            destination: context.spicetifyColorDestination,
            teardownLabel: "Spicetify color scheme",
            setupRank: 0,
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

  func setup(
    _ step: ConsumerSetupPlan.Step,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    switch step.operation {
    case .kittyInclude:
      return try setupKitty(context: context, dryRun: dryRun, records: &records)
    case .batSelector:
      return try setupBatSelector(context: context, dryRun: dryRun, records: &records)
    case .batThemeLink:
      return try setupBatThemeLink(context: context, dryRun: dryRun, records: &records)
    case .ezaEnvironment:
      return try setupEzaEnvironment(context: context, dryRun: dryRun, records: &records)
    case .ezaThemeLink:
      return try setupEzaThemeLink(context: context, dryRun: dryRun, records: &records)
    case .btopSelector:
      return try setupBtopSelector(context: context)
    case .btopThemeLink:
      return try setupBtopThemeLink(context: context, dryRun: dryRun, records: &records)
    case .yaziSelector:
      return try setupYaziSelector(context: context, dryRun: dryRun, records: &records)
    case .yaziFlavorLink:
      return try setupYaziFlavorLink(context: context, dryRun: dryRun, records: &records)
    case .yaziSyntaxLink:
      return try setupYaziSyntaxLink(context: context, dryRun: dryRun, records: &records)
    case .atuinSelector:
      return try setupAtuinSelector(context: context, dryRun: dryRun, records: &records)
    case .atuinThemeLink:
      return try setupAtuinThemeLink(context: context, dryRun: dryRun, records: &records)
    case .neovimWatcher:
      return try setupNeovimWatcher(context: context)
    case .neovimThemeLink:
      return try setupNeovimThemeLink(context: context, dryRun: dryRun, records: &records)
    case .starshipBehavior:
      return try setupStarshipBehavior(context: context)
    case .starshipConfigurationLink:
      return try setupStarshipConfigurationLink(
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .piSelector:
      return try setupPiSelector(context: context, dryRun: dryRun, records: &records)
    case .piThemeLink:
      return try setupPiThemeLink(context: context, dryRun: dryRun, records: &records)
    case .herdrSelector:
      return try setupHerdrSelector(context: context)
    case .tuicrSelector:
      return try setupTuicrSelector(context: context, dryRun: dryRun, records: &records)
    case .tuicrThemeLink:
      return try setupTuicrThemeLink(context: context, dryRun: dryRun, records: &records)
    case .tuicrSyntaxLink:
      return try setupTuicrSyntaxLink(context: context, dryRun: dryRun, records: &records)
    case .codexSelector:
      return try setupCodexSelector(context: context, dryRun: dryRun, records: &records)
    case .codexThemeLink:
      return try setupCodexThemeLink(context: context, dryRun: dryRun, records: &records)
    case .spicetifySelectors:
      return try setupSpicetifySelectors(context: context, dryRun: dryRun, records: &records)
    case .spicetifyColorLink:
      return try setupSpicetifyColorLink(context: context, dryRun: dryRun, records: &records)
    }
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
    setupRank: Int,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .external(teardownMessage: teardownMessage),
      setupRank: setupRank,
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
    setupRank: Int,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .regularFile(
        backup: backup, replacementName: replacementName, label: label, read: read),
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }

  private func themeLinkStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    destination: URL,
    teardownLabel: String,
    setupRank: Int,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      mechanism: .themeLink(destination: destination, teardownLabel: teardownLabel),
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }

  private func piSelectorStep(
    setupRank: Int,
    teardownRank: Int,
    context: Context
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: .piSelector,
      target: context.piConfiguration,
      mechanism: .piSelector(replacementName: context.piSelectorReplacementName),
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }

  private func spicetifySelectorStep(
    setupRank: Int,
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
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }
}
