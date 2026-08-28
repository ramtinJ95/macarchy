import Foundation

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

    let operation: Operation
    let target: URL
    let affectedPaths: [URL]
    let ownershipKind: SetupOwnershipRecord.Kind?
    let validateOwnershipRecord: ((SetupOwnershipRecord) throws -> Void)?
    let setupRank: Int
    let teardownRank: Int

    var id: String { operation.rawValue }
  }

  typealias Execution = (
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult]

  enum ExecutionGroup {
    case independent
    case spicetify
  }

  let consumerID: String
  let steps: [Step]
  private let manager: SetupOwnershipManager
  private let context: SetupOwnershipManager.Context
  private let executionGroup: ExecutionGroup

  init(
    consumerID: String,
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
    let operation: Execution = {
      try execute(.setup, dryRun: dryRun, records: &$0)
    }
    switch executionGroup {
    case .independent:
      return try operation(&records)
    case .spicetify:
      do {
        let results = try manager.withSpicetifySetupGroup(
          context: context,
          dryRun: dryRun,
          records: &records,
          execute: operation
        )
        return resultsInStepOrder(results)
      } catch let error as ConsumerSetupPlanPartialFailure {
        throw error.cause
      }
    }
  }

  func teardown(
    _ dryRun: Bool,
    _ records: inout [SetupOwnershipRecord]
  ) throws -> [SetupIntegrationResult] {
    let operation: Execution = {
      try execute(.teardown, dryRun: dryRun, records: &$0)
    }
    switch executionGroup {
    case .independent:
      return try operation(&records)
    case .spicetify:
      do {
        let results = try manager.withSpicetifyTeardownGroup(
          context: context,
          dryRun: dryRun,
          records: &records,
          execute: operation
        )
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
      let failure = SetupOwnershipManager.failureResult(
        error,
        homeDirectory: context.homeDirectory
      )
      throw SetupOwnershipTransactionError(
        error,
        integrationID: failure.id,
        target: URL(filePath: failure.target),
        completedResults: completed,
        failureMutationAttempted: false
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
    [
      ConsumerSetupPlan(
        consumerID: "kitty",
        steps: [
          regularFileStep(
            .kittyInclude,
            target: context.kittyConfiguration,
            backup: context.backupURL,
            replacementName: context.replacementName,
            setupRank: 0,
            teardownRank: 0,
            context: context
          )
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "bat",
        steps: [
          regularFileStep(
            .batSelector,
            target: context.batConfiguration,
            backup: context.batSelectorBackup,
            replacementName: context.batSelectorReplacementName,
            setupRank: 0,
            teardownRank: 1,
            context: context
          ),
          themeLinkStep(
            .batThemeLink,
            target: context.batThemeLink,
            destination: context.batThemeDestination,
            setupRank: 1,
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "eza",
        steps: [
          regularFileStep(
            .ezaEnvironment,
            target: context.shellConfiguration,
            backup: context.ezaEnvironmentBackup,
            replacementName: context.ezaEnvironmentReplacementName,
            setupRank: 0,
            teardownRank: 1,
            context: context
          ),
          themeLinkStep(
            .ezaThemeLink,
            target: context.ezaThemeLink,
            destination: context.ezaThemeDestination,
            setupRank: 1,
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "btop",
        steps: [
          externalStep(
            .btopSelector,
            target: context.btopConfiguration,
            setupRank: 0,
            teardownRank: 0
          ),
          themeLinkStep(
            .btopThemeLink,
            target: context.btopThemeLink,
            destination: context.btopThemeDestination,
            setupRank: 1,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "yazi",
        steps: [
          regularFileStep(
            .yaziSelector,
            target: context.yaziConfiguration,
            backup: context.yaziSelectorBackup,
            replacementName: context.yaziSelectorReplacementName,
            setupRank: 2,
            teardownRank: 0,
            context: context
          ),
          themeLinkStep(
            .yaziFlavorLink,
            target: context.yaziFlavorLink,
            destination: context.yaziFlavorDestination,
            setupRank: 0,
            teardownRank: 2
          ),
          themeLinkStep(
            .yaziSyntaxLink,
            target: context.yaziSyntaxLink,
            destination: context.yaziSyntaxDestination,
            setupRank: 1,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "atuin",
        steps: [
          regularFileStep(
            .atuinSelector,
            target: context.atuinConfiguration,
            backup: context.atuinSelectorBackup,
            replacementName: context.atuinSelectorReplacementName,
            setupRank: 1,
            teardownRank: 0,
            context: context
          ),
          themeLinkStep(
            .atuinThemeLink,
            target: context.atuinThemeLink,
            destination: context.atuinThemeDestination,
            setupRank: 0,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "neovim",
        steps: [
          externalStep(
            .neovimWatcher,
            target: context.neovimWatcherConfiguration,
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .neovimThemeLink,
            target: context.neovimThemeLink,
            destination: context.neovimThemeDestination,
            setupRank: 1,
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "starship",
        steps: [
          externalStep(
            .starshipBehavior,
            target: context.starshipBehavior,
            setupRank: 0,
            teardownRank: 1
          ),
          themeLinkStep(
            .starshipConfigurationLink,
            target: context.starshipConfigurationLink,
            destination: context.starshipBridgeDestination,
            setupRank: 1,
            teardownRank: 0
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "pi",
        steps: [
          piSelectorStep(setupRank: 1, teardownRank: 0, context: context),
          themeLinkStep(
            .piThemeLink,
            target: context.piThemeLink,
            destination: context.piThemeDestination,
            setupRank: 0,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "herdr",
        steps: [
          externalStep(
            .herdrSelector,
            target: context.herdrConfiguration,
            setupRank: 0,
            teardownRank: 0
          )
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "tuicr",
        steps: [
          regularFileStep(
            .tuicrSelector,
            target: context.tuicrConfiguration,
            backup: context.tuicrSelectorBackup,
            replacementName: context.tuicrSelectorReplacementName,
            setupRank: 2,
            teardownRank: 0,
            context: context
          ),
          themeLinkStep(
            .tuicrThemeLink,
            target: context.tuicrThemeLink,
            destination: context.tuicrThemeDestination,
            setupRank: 0,
            teardownRank: 2
          ),
          themeLinkStep(
            .tuicrSyntaxLink,
            target: context.tuicrSyntaxLink,
            destination: context.tuicrSyntaxDestination,
            setupRank: 1,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "codex",
        steps: [
          regularFileStep(
            .codexSelector,
            target: context.codexConfiguration,
            backup: context.codexSelectorBackup,
            replacementName: context.codexSelectorReplacementName,
            setupRank: 1,
            teardownRank: 0,
            context: context
          ),
          themeLinkStep(
            .codexThemeLink,
            target: context.codexThemeLink,
            destination: context.codexThemeDestination,
            setupRank: 0,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context
      ),
      ConsumerSetupPlan(
        consumerID: "spicetify",
        steps: [
          spicetifySelectorStep(setupRank: 1, teardownRank: 0, context: context),
          themeLinkStep(
            .spicetifyColorLink,
            target: context.spicetifyColorLink,
            destination: context.spicetifyColorDestination,
            setupRank: 0,
            teardownRank: 1
          ),
        ],
        manager: self,
        context: context,
        executionGroup: .spicetify
      ),
    ]
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
    switch step.operation {
    case .kittyInclude:
      return try teardownRegularFile(
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
    case .batSelector:
      return try teardownRegularFile(
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
    case .batThemeLink:
      return try teardownThemeLink(
        id: Self.batThemeLinkID,
        target: context.batThemeLink,
        destination: context.batThemeDestination,
        label: "bat",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .ezaEnvironment:
      return try teardownRegularFile(
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
    case .ezaThemeLink:
      return try teardownThemeLink(
        id: Self.ezaThemeLinkID,
        target: context.ezaThemeLink,
        destination: context.ezaThemeDestination,
        label: "eza",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .btopSelector:
      return integrationResult(
        id: Self.btopSelectorID,
        target: context.btopConfiguration,
        status: .none,
        message: "No Macarchy-owned btop selector exists"
      )
    case .btopThemeLink:
      return try teardownThemeLink(
        id: Self.btopThemeLinkID,
        target: context.btopThemeLink,
        destination: context.btopThemeDestination,
        label: "btop",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .yaziSelector:
      return try teardownRegularFile(
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
    case .yaziFlavorLink:
      return try teardownThemeLink(
        id: Self.yaziFlavorLinkID,
        target: context.yaziFlavorLink,
        destination: context.yaziFlavorDestination,
        label: "Yazi flavor",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .yaziSyntaxLink:
      return try teardownThemeLink(
        id: Self.yaziSyntaxLinkID,
        target: context.yaziSyntaxLink,
        destination: context.yaziSyntaxDestination,
        label: "Yazi syntax theme",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .atuinSelector:
      return try teardownRegularFile(
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
    case .atuinThemeLink:
      return try teardownThemeLink(
        id: Self.atuinThemeLinkID,
        target: context.atuinThemeLink,
        destination: context.atuinThemeDestination,
        label: "Atuin",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .neovimWatcher:
      return teardownNeovimWatcher(context: context)
    case .neovimThemeLink:
      return try teardownThemeLink(
        id: Self.neovimThemeLinkID,
        target: context.neovimThemeLink,
        destination: context.neovimThemeDestination,
        label: "Neovim theme",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .starshipBehavior:
      return teardownStarshipBehavior(context: context)
    case .starshipConfigurationLink:
      return try teardownThemeLink(
        id: Self.starshipConfigurationLinkID,
        target: context.starshipConfigurationLink,
        destination: context.starshipBridgeDestination,
        label: "Starship configuration",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .piSelector:
      return try teardownPiSelector(context: context, dryRun: dryRun, records: &records)
    case .piThemeLink:
      return try teardownPiThemeLink(context: context, dryRun: dryRun, records: &records)
    case .herdrSelector:
      return teardownHerdrSelector(context: context)
    case .tuicrSelector:
      return try teardownTuicrSelector(context: context, dryRun: dryRun, records: &records)
    case .tuicrThemeLink:
      return try teardownTuicrThemeLink(context: context, dryRun: dryRun, records: &records)
    case .tuicrSyntaxLink:
      return try teardownTuicrSyntaxLink(context: context, dryRun: dryRun, records: &records)
    case .codexSelector:
      return try teardownCodexSelector(context: context, dryRun: dryRun, records: &records)
    case .codexThemeLink:
      return try teardownCodexThemeLink(context: context, dryRun: dryRun, records: &records)
    case .spicetifySelectors:
      return try teardownSpicetifySelectorOwnership(
        context: context,
        dryRun: dryRun,
        records: &records
      )
    case .spicetifyColorLink:
      return try teardownThemeLink(
        id: Self.spicetifyColorLinkID,
        target: context.spicetifyColorLink,
        destination: context.spicetifyColorDestination,
        label: "Spicetify color scheme",
        context: context,
        dryRun: dryRun,
        records: &records
      )
    }
  }

  private func externalStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    setupRank: Int,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      affectedPaths: [target],
      ownershipKind: nil,
      validateOwnershipRecord: nil,
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }

  private func regularFileStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    backup: URL,
    replacementName: String,
    setupRank: Int,
    teardownRank: Int,
    context: Context
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      affectedPaths: [
        target,
        backup,
        target.deletingLastPathComponent().appending(path: replacementName),
      ],
      ownershipKind: .regularFile,
      validateOwnershipRecord: {
        try validateRegularFileRecord(
          $0,
          target: target,
          backupURL: backup,
          context: context
        )
      },
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }

  private func themeLinkStep(
    _ operation: ConsumerSetupPlan.Step.Operation,
    target: URL,
    destination: URL,
    setupRank: Int,
    teardownRank: Int
  ) -> ConsumerSetupPlan.Step {
    ConsumerSetupPlan.Step(
      operation: operation,
      target: target,
      affectedPaths: [target],
      ownershipKind: .symbolicLink,
      validateOwnershipRecord: {
        try validateThemeLinkRecord($0, target: target, destination: destination)
      },
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
      affectedPaths: [
        context.piConfiguration,
        context.piConfiguration.deletingLastPathComponent()
          .appending(path: context.piSelectorReplacementName),
      ],
      ownershipKind: .jsonSelector,
      validateOwnershipRecord: { try validatePiSelectorRecord($0, context: context) },
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
      affectedPaths: [
        context.spicetifyConfiguration,
        context.spicetifySelectorsBackup,
        context.spicetifyConfiguration.deletingLastPathComponent()
          .appending(path: context.spicetifySelectorsReplacementName),
      ],
      ownershipKind: .spicetifySelection,
      validateOwnershipRecord: {
        try validateSpicetifySelectorRecord(
          $0,
          target: context.spicetifyConfiguration,
          backupURL: context.spicetifySelectorsBackup,
          context: context
        )
      },
      setupRank: setupRank,
      teardownRank: teardownRank
    )
  }
}
