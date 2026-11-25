import Foundation
import ThemeCore

struct UnifiedSetupApplyCommandRunner: Sendable {
  typealias ComponentApply<Report> =
    @Sendable (
      UnifiedSetupPlanContext,
      PortableProfile,
      ThemeConsumerPaths,
      UnifiedSetupAdoptionApprovals,
      [String]
    ) async throws
    -> Report
  typealias ThemeApply =
    @Sendable (ThemePackage, URL) async throws -> ThemeSetJSONReport
  /// Reactivates the active theme, reconciling only the given adapters. The final
  /// closure runs under the activation lock right after the pointer swap.
  typealias ThemeRefresh =
    @Sendable (
      UnifiedSetupPlanContext, UnifiedSetupThemePlan, Set<String>, ThemeConsumerPaths,
      @escaping @Sendable (GenerationManifest) throws -> Void
    ) async throws -> ThemeSetJSONReport

  let planner: UnifiedSetupPlanCommandRunner
  let themeInspection: UnifiedSetupThemeInspection
  var packageInstaller: HomebrewBundleInstaller
  let capabilityIsAvailable: @Sendable (DependencyCapability) throws -> Bool
  var writePreMutationPlan: @Sendable (String) throws -> Void
  var themeApply: ThemeApply
  var beforeConfiguration: @Sendable (UnifiedSetupPlanContext, PortableProfile) throws -> String? =
    { _, _ in nil }
  var deferAppearanceUntilPermissions = false
  let themeRefresh: ThemeRefresh
  let desktopApply: ComponentApply<DesktopAggregateMutationReport>
  let environmentApply: ComponentApply<EnvironmentLifecycleReport>
  let transactionTeardown: UnifiedSetupTeardownCommandRunner
  let restoredSessionVerifier: EnvironmentSessionVerifier
  let faultInjector: @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void

  init(
    planner: UnifiedSetupPlanCommandRunner,
    themeInspection: @escaping UnifiedSetupThemeInspection,
    packageInstaller: HomebrewBundleInstaller,
    capabilityIsAvailable: @escaping @Sendable (DependencyCapability) throws -> Bool,
    writePreMutationPlan: @escaping @Sendable (String) throws -> Void,
    themeApply: @escaping ThemeApply,
    themeRefresh: @escaping ThemeRefresh = UnifiedSetupApplyCommandRunner.liveThemeRefresh,
    desktopApply: @escaping ComponentApply<DesktopAggregateMutationReport>,
    environmentApply: @escaping ComponentApply<EnvironmentLifecycleReport>,
    transactionTeardown: UnifiedSetupTeardownCommandRunner = .live,
    restoredSessionVerifier: EnvironmentSessionVerifier = .assumed,
    faultInjector: @escaping @Sendable (UnifiedSetupTransactionCheckpoint) throws -> Void = {
      _ in
    }
  ) {
    self.planner = planner
    self.themeInspection = themeInspection
    self.packageInstaller = packageInstaller
    self.capabilityIsAvailable = capabilityIsAvailable
    self.writePreMutationPlan = writePreMutationPlan
    self.themeApply = themeApply
    self.themeRefresh = themeRefresh
    self.desktopApply = desktopApply
    self.environmentApply = environmentApply
    self.transactionTeardown = transactionTeardown
    self.restoredSessionVerifier = restoredSessionVerifier
    self.faultInjector = faultInjector
  }

  static let liveThemeRefresh: ThemeRefresh = {
    context, theme, adapterIDs, consumerPaths, onCommittedLocked in
    let activation = ThemeActivationService.reconciling(
      adapterIDs,
      onCommittedLocked: onCommittedLocked
    )
    let repository = ThemeRepository(
      builtInRoot: context.themesRoot,
      userRoot: StateLayout(root: context.stateRoot).userThemes
    )
    return try await withThemePackageLock(stateRoot: context.stateRoot, unlessDryRun: false) {
      try await activation.reportLocked(
        package: repository.package(id: theme.id),
        stateRoot: context.stateRoot,
        consumerPaths: consumerPaths,
        dryRun: false,
        expectedActiveGenerationID: theme.currentGenerationID
      ).jsonReport
    }
  }

  private static let pendingAppearance = AdapterResult(
    adapterID: MacOSAppearanceAdapter.id, requirement: .required, status: .pending,
    message:
      "System Events Automation and appearance reconciliation follow configuration in guided setup."
  )

  private static func bootstrapTheme(
    _ package: ThemePackage, stateRoot: URL, deferAppearance: Bool
  ) async throws -> ThemeSetJSONReport {
    let store = SetupCoreOwnershipStore(stateRoot: stateRoot)
    guard try store.read() == nil else { throw SetupCoreOwnershipError.alreadyExists }
    let appearance = MacOSAppearanceAdapter.live(root: stateRoot)
    let originalAppearance = try appearance.preflight()
    // The bootstrap reconciles only macOS appearance; a failed or drifted result fails it.
    let outcome = try await ThemeActivationOutcome.classify(
      requiredFailure: { results in
        results.contains { $0.status == .failed || $0.status == .drifted }
      },
      {
        let manifest = try ThemeActivator(root: stateRoot).activate(
          package: package,
          onCommittedLocked: { manifest in
            try store.write(
              SetupCoreOwnership(
                themeGenerationID: manifest.generationID,
                originalAppearance: originalAppearance
              )
            )
          }
        )
        do {
          let appearanceResult =
            deferAppearance
            ? Self.pendingAppearance
            : try await appearance.apply(package.appearance)
          return ThemeActivationResult(
            manifest: manifest,
            reconciliation: try ReconciliationStatusStore(root: stateRoot).persist(
              manifest: manifest,
              results: [appearanceResult]
            )
          )
        } catch {
          throw ThemeCommittedWithReconciliationError(
            manifest: manifest,
            cause: String(describing: error)
          )
        }
      }
    )
    return ThemeSetReport(outcome, themeID: package.id, slackTheme: nil).jsonReport
  }

  static func guided(io: GuidedSetupIO = .live) -> Self {
    var runner = live
    runner.packageInstaller = .guided(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    runner.writePreMutationPlan = { _ in
      io.write("Preflight complete; applying the setup reviewed above.\n")
    }
    runner.deferAppearanceUntilPermissions = true
    runner.themeApply = { package, root in
      try await bootstrapTheme(package, stateRoot: root, deferAppearance: true)
    }
    runner.beforeConfiguration = { context, profile in
      try GuidedSetupPermissions.live(io: io).beforeConfiguration(
        context: context, profile: profile)
    }
    return runner
  }

  static let live = Self(
    planner: .live,
    themeInspection: UnifiedSetupThemeLifecycleStatus.preflightApply,
    packageInstaller: .live(homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
    capabilityIsAvailable: { try $0.isAvailableWithFreshFonts() },
    writePreMutationPlan: { output in
      try FileHandle.standardError.write(contentsOf: Data("\(output)\n".utf8))
    },
    themeApply: { package, stateRoot in
      try await bootstrapTheme(package, stateRoot: stateRoot, deferAppearance: false)
    },
    desktopApply: { context, profile, consumerPaths, adoptions, enabledThemeAdapterIDs in
      try await DesktopApplyCommandRunner(
        lifecycle: .live,
        keybindings: .live,
        prerequisites: .live,
        theme: .live(enabling: Set(enabledThemeAdapterIDs))
      ).aggregateReport(
        resourcesRoot: context.desktopResourcesRoot,
        keybindingsResourcesRoot: context.keybindingsResourcesRoot,
        profileURL: context.profileURL,
        profileRequired: context.profileRequired,
        stateRoot: context.stateRoot,
        homeDirectory: context.homeDirectory,
        consumerPaths: consumerPaths,
        adopt: adoptions.yabai,
        keybindingsAdopt: adoptions.keybindings,
        sketchyBarAdopt: adoptions.sketchybar,
        deferFinalization: true,
        profile: profile
      )
    },
    environmentApply: { context, profile, consumerPaths, adoptions, enabledThemeAdapterIDs in
      try await EnvironmentApplyCommandRunner.live.report(
        resourcesRoot: context.environmentResourcesRoot,
        profileURL: context.profileURL,
        profileRequired: context.profileRequired,
        stateRoot: context.stateRoot,
        homeDirectory: context.homeDirectory,
        consumerPaths: consumerPaths,
        adopt: adoptions.environment,
        deferFinalization: true,
        withinUnifiedSetup: true,
        enabledThemeAdapterIDs: enabledThemeAdapterIDs,
        profile: profile
      )
    },
    restoredSessionVerifier: .live
  )

  func execute(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    packageApproval: String? = nil,
    preferencesApproval: String? = nil,
    adoptions: UnifiedSetupAdoptionApprovals = .none,
    reviewedPlan: String? = nil,
    json: Bool
  ) async throws -> CommandExecution {
    @Sendable func blocked(
      _ plan: UnifiedSetupPlanReport?,
      _ message: String
    ) throws -> CommandExecution {
      try result(outcome: "blocked", mutated: false, plan: plan, message: message, json: json)
    }
    /// Why the core-owned theme blocks setup, or nil when it may proceed.
    @Sendable func themeGateFailure(_ model: UnifiedSetupDesiredModel) -> String? {
      let ownership: SetupCoreOwnership?
      do {
        ownership = try SetupCoreOwnershipStore(stateRoot: context.stateRoot).read()
      } catch {
        return String(describing: error)
      }
      let theme = themeInspection(model, ownership, context.stateRoot)
      return theme.succeeded ? nil : theme.message
    }
    let transactionStore = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
    do {
      try SetupPendingWork.requireNone(.packageAttempt, context: context)
      if try transactionStore.read() != nil {
        if reviewedPlan != nil {
          throw UnifiedSetupTransactionError.recoveryRequired(
            "Interrupted setup requires explicit recovery, not menu apply.")
        }
        return try await recoverInterrupted(
          context: context,
          consumerPaths: consumerPaths,
          json: json
        )
      }
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: false,
        plan: nil,
        message: String(describing: error),
        json: json
      )
    }

    let preparation: UnifiedSetupPreparation
    do {
      preparation = try planner.prepare(context: context)
    } catch {
      return try blocked(nil, "Setup preflight failed: \(error)")
    }
    guard case .ready(let model, let plan) = preparation else {
      return try result(
        outcome: preparation.report.outcome,
        mutated: false,
        plan: preparation.report,
        message: "The unified setup plan is blocked.",
        json: json
      )
    }
    do {
      if let reviewedPlan, try plan.approvalText() != reviewedPlan {
        throw EnvironmentLifecycleError.blocked(
          "The reviewed setup plan changed; review it again before applying.")
      }
      try adoptions.validate(required: plan.adoption)
      let starterApprovals = Dictionary(
        uniqueKeysWithValues: plan.nativeStarters.map {
          ($0.provider, $0.approval)
        })
      guard context.nativeStarterApprovals == starterApprovals else {
        throw EnvironmentLifecycleError.blocked(
          "Native starter approval changed; review guided setup again before any mutation.")
      }
      guard preferencesApproval == plan.preferencesApprovalDigest else {
        throw PreferencesError.invalid(
          "Supply exactly --approve-preferences from the reviewed setup plan before any setup mutation."
        )
      }
    } catch {
      return try blocked(plan, String(describing: error))
    }
    guard model.packages.external.isEmpty else {
      return try blocked(
        plan,
        "Complete every external prerequisite from the reviewed setup plan first."
      )
    }
    if let failure = themeGateFailure(model) {
      return try blocked(plan, failure)
    }
    guard
      plan.packageInstallation == nil || packageApproval == plan.packageInstallation?.approvalDigest
    else {
      return try blocked(
        plan,
        "Review the missing-package Brewfile and repeat with its exact --approve-packages digest. The legacy --install-dependencies flag does not authorize this scope."
      )
    }

    try writePreMutationPlan(try plan.render(json: json))

    do {
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try SetupPendingWork.requireNone(
          .packageAttempt,
          .unifiedTransaction(
            refusal: UnifiedSetupTransactionError.recoveryRequired(
              "another unified setup operation started after preflight")),
          context: context)
        let store = UnifiedSetupTransactionStore(stateRoot: context.stateRoot)
        let currentPreparation: UnifiedSetupPreparation
        do {
          currentPreparation = try planner.prepare(context: context)
        } catch {
          return try blocked(nil, "Setup revalidation failed: \(error)")
        }
        guard case .ready(let currentModel, let currentPlan) = currentPreparation else {
          return try result(
            outcome: currentPreparation.report.outcome,
            mutated: false,
            plan: currentPreparation.report,
            message: "The unified setup plan changed before mutation.",
            json: json
          )
        }
        guard try currentPlan.approvalText() == plan.approvalText() else {
          return try blocked(
            currentPlan,
            "The unified setup plan changed before mutation; review it and retry."
          )
        }
        if let failure = themeGateFailure(currentModel) {
          return try blocked(currentPlan, failure)
        }

        let packages = install(currentPlan.packageInstallation, context: context)
        guard packages.succeeded else {
          return try result(
            outcome: "failed",
            mutated: packages.mutated,
            plan: currentPlan,
            packages: packages,
            message: packages.message,
            json: json
          )
        }
        if let reason = try beforeConfiguration(context, currentModel.profile) {
          return try result(
            outcome: "blocked", mutated: packages.mutated, plan: currentPlan,
            packages: packages, message: reason, json: json)
        }
        let unresolved: [String]
        do {
          unresolved = try DependencyProfile.personal(homeDirectory: context.homeDirectory)
            .selectedForSetup(
              currentModel.profile,
              defaultsURL: DesktopDesiredState.sketchyBarDefaultsURL(
                resourcesRoot: context.desktopResourcesRoot)
            )
            .filter { try !capabilityIsAvailable($0) }
            .map(\.id)
        } catch {
          return try result(
            outcome: "failed", mutated: packages.mutated, plan: currentPlan, packages: packages,
            message: "Post-install capability verification failed: \(error)", json: json)
        }
        guard unresolved.isEmpty else {
          return try result(
            outcome: "failed",
            mutated: packages.mutated,
            plan: currentPlan,
            packages: packages,
            message: "Selected capabilities remain missing: \(unresolved.joined(separator: ", ")).",
            json: json
          )
        }
        let replacements = currentModel.nativeStarters.compactMap { $0.replacement }
        let contextDigest = unifiedSetupContextDigest(
          context: context, consumerPaths: consumerPaths)
        var transaction: UnifiedSetupTransaction?
        // Replacement intent belongs to this exact aggregate operation. Write it
        // before the per-entry journal or any staging/publication can occur.
        if !replacements.isEmpty {
          let initial = UnifiedSetupTransaction(
            operation: .apply, stages: [], desiredAppearance: currentModel.themePackage.appearance,
            contextDigest: contextDigest, nativeReplacements: replacements)
          try store.write(initial)
          transaction = initial
        }
        // These become user-owned immediately, like the emitted profile. Never
        // remove them during provider rollback: the user may already have edited them.
        do {
          for starter in currentModel.nativeStarters {
            guard let approval = context.nativeStarterApprovals[starter.provider.rawValue] else {
              throw EnvironmentLifecycleError.blocked("Missing native starter approval")
            }
            _ = try starter.seed(approval: approval)
          }
        } catch {
          return try result(
            outcome: transaction == nil ? "failed" : "recovery_required", mutated: true,
            plan: currentPlan, packages: packages,
            message:
              "Native starter publication stopped: \(error). Created files and originals were retained. "
              + (transaction == nil
                ? "Review existing files before retrying."
                : "Run macarchy setup recover before retrying."),
            json: json)
        }
        let plannedStages = Set(
          currentPlan.actions.compactMap { SetupStage(rawValue: $0.stage) }
        )
        func start(_ stage: SetupStage) throws {
          let next = UnifiedSetupTransaction(
            operation: .apply,
            stages: (transaction?.stages ?? []) + [stage],
            desiredAppearance: currentModel.themePackage.appearance,
            contextDigest: contextDigest,
            nativeReplacements: replacements.isEmpty ? nil : replacements
          )
          try store.write(next)
          transaction = next
        }

        var mutated = packages.mutated || !currentModel.nativeStarters.isEmpty
        let theme: UnifiedSetupApplyStage
        if currentModel.theme.status == "activation_required" {
          try start(.theme)
          do {
            theme = try stage(
              await themeApply(currentModel.themePackage, context.stateRoot),
              successMessage: "The curated default theme is active."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              message: "Theme activation failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || theme.mutated
          guard theme.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              message: "Theme activation did not converge.",
              json: json
            )
          }
          try faultInjector(.themeApplied)
        } else if currentPlan.actions.contains(where: {
          $0.stage == SetupStage.desktop.rawValue
            && $0.id == DesktopPlanCommandRunner.themePaletteActionID
        }) {
          // Theme activation is the only palette publisher (ADR-0189). The desktop and
          // environment stages reconcile their own consumers after publishing their seams.
          var adapterIDs: Set<String> =
            deferAppearanceUntilPermissions ? [] : [MacOSAppearanceAdapter.id]
          if !plannedStages.contains(.environment) {
            adapterIDs.formUnion(currentModel.profile.environment.selectedThemeAdapterIDs)
          }
          // Republishing the bootstrap generation must keep it removable by teardown, so
          // the receipt follows the pointer swap like the bootstrap write. It is not
          // journaled: the refresh stays active on rollback, and so must its receipt.
          let ownershipStore = SetupCoreOwnershipStore(stateRoot: context.stateRoot)
          let previous = currentModel.theme
          let followSetupOwnedTheme: @Sendable (GenerationManifest) throws -> Void = {
            manifest in
            guard let previousGenerationID = previous.currentGenerationID,
              manifest.themeID == previous.id
            else { return }
            try ownershipStore.transfer(from: previousGenerationID, to: manifest.generationID)
          }
          do {
            var refreshed = try await themeRefresh(
              context, currentModel.theme, adapterIDs, consumerPaths, followSetupOwnedTheme)
            if deferAppearanceUntilPermissions, refreshed.succeeded {
              refreshed.reconciliation = try ActivationLock(root: context.stateRoot).withLock {
                let manifest = try ThemeGenerationReader(root: context.stateRoot).activeManifest()
                let status = ReconciliationStatusStore(root: context.stateRoot)
                guard manifest.generationID == refreshed.generationID,
                  case .current(let record) = try status.read()
                else {
                  throw SetupComponentReportError(
                    description:
                      "Refreshed theme changed before deferred appearance could be recorded; review the current setup."
                  )
                }
                // Environment's missing-adapter expansion must not pull appearance back
                // into configuration before the guided permission step.
                return try status.persist(
                  manifest: manifest,
                  results: record.results.filter { $0.adapterID != MacOSAppearanceAdapter.id }
                    + [Self.pendingAppearance]
                ).results
              }
            }
            theme = try stage(
              refreshed,
              successMessage:
                "Reactivated '\(currentModel.theme.id)' to publish the current SketchyBar palette; it stays active if a later stage rolls back."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              message: "Theme reactivation failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || theme.mutated
          guard theme.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              message: "Theme reactivation did not converge; later stages were not run.",
              json: json
            )
          }
        } else {
          theme = .noChange("Preserved active theme '\(currentModel.theme.id)'.")
        }

        let desktop: UnifiedSetupApplyStage
        if plannedStages.contains(.desktop) {
          try start(.desktop)
          do {
            desktop = try stage(
              await desktopApply(
                context,
                currentModel.profile,
                consumerPaths,
                adoptions,
                currentModel.enabledThemeAdapterIDs
              ),
              successMessage:
                "Desktop configuration and core applied; Apple-menu permission is checked separately."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              message: "Desktop apply failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || desktop.mutated
          guard desktop.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              message: "Desktop apply could not verify the selected services: \(desktop.message)",
              json: json
            )
          }
          try faultInjector(.desktopApplied)
        } else {
          desktop = .noChange("Preserved converged desktop providers.")
        }

        var environment: UnifiedSetupApplyStage
        if plannedStages.contains(.environment) {
          try start(.environment)
          do {
            environment = try stage(
              await environmentApply(
                context,
                currentModel.profile,
                consumerPaths,
                adoptions,
                currentModel.enabledThemeAdapterIDs
              ),
              successMessage: "The daily tool environment converged."
            )
          } catch {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: true,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              message: "Environment apply failed before a result was available: \(error)",
              json: json
            )
          }
          mutated = mutated || environment.mutated
          guard environment.succeeded else {
            return try await failureAfterRollback(
              transaction: transaction,
              mutated: mutated,
              context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan,
              packages: packages,
              theme: theme,
              desktop: desktop,
              environment: environment,
              message: "Environment apply did not converge.",
              json: json
            )
          }
          try faultInjector(.environmentApplied)
        } else {
          environment = .noChange("Preserved the converged daily tool environment.")
        }

        let preferences: UnifiedSetupApplyStage
        if plannedStages.contains(.preferences) {
          try start(.preferences)
          do {
            var report = try planner.preferences.apply(
              context: context.preferencesContext, desired: currentModel.profile.macOSPreferences,
              approval: preferencesApproval, deferFinalization: true)
            // This success report is emitted only after unified finalization below.
            if report.outcome == "pending_commit" { report.outcome = "applied" }
            preferences = try stage(
              report, successMessage: "Selected macOS preferences converged.")
          } catch {
            return try await failureAfterRollback(
              transaction: transaction, mutated: true, context: context,
              consumerPaths: consumerPaths,
              plan: currentPlan, packages: packages, theme: theme, desktop: desktop,
              environment: environment,
              message: "macOS preferences apply failed: \(error)", json: json)
          }
          mutated = mutated || preferences.mutated
          try faultInjector(.preferencesApplied)
        } else {
          preferences = .noChange("No native preference changes were required.")
        }

        if let transaction {
          let committing = transaction.replacing(phase: .committing)
          try store.write(committing)
          let finalized = try await transactionTeardown.recover(
            transaction: committing,
            context: context,
            consumerPaths: consumerPaths
          )
          environment = environment.finalized(by: finalized.environment)
          mutated = mutated || finalized.mutated
        }

        return try result(
          outcome: environment.hasPendingThemeVerification
            ? "applied_incomplete" : mutated ? "applied" : "no_change",
          mutated: mutated,
          plan: currentPlan,
          packages: packages,
          theme: theme,
          desktop: desktop,
          environment: environment,
          preferences: preferences,
          message: environment.hasPendingThemeVerification
            ? "Reviewed configuration is applied; required theme verification remains incomplete. Run macarchy reconcile. Permission checks are separate."
            : mutated
              ? "Reviewed configuration applied. Permission grants are not implied verified; use setup guided --resume for context-specific checks."
              : "Reviewed configuration is already current. Permission grants are not implied verified; use setup guided --resume for context-specific checks.",
          json: json
        )
      }
    } catch let error as UnifiedSetupInterruptionError {
      throw error
    } catch {
      let recoveryPending = (try? transactionStore.read()) != nil
      return try result(
        outcome: recoveryPending ? "recovery_required" : "failed",
        mutated: recoveryPending || (packageApproval != nil && plan.packageInstallation != nil),
        plan: plan,
        message: String(describing: error),
        json: json
      )
    }
  }

  private func install(
    _ preview: HomebrewBundleInstaller.Preview?, context: UnifiedSetupPlanContext
  ) -> UnifiedSetupPackageApply {
    guard let preview else { return .noChange }
    var commands = [UnifiedSetupHomebrewCommand]()
    var mutated = false
    do {
      try packageInstaller.preflight()
      let file = HomebrewBundleInstaller.Preview.fileURL(context: context)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try preview.brewfile.write(to: file, atomically: true, encoding: .utf8)
      mutated = true
      guard try SetupBrewfile.read(at: file).text == preview.brewfile else {
        throw SetupPackageAdoptionError("Generated Brewfile changed before execution.")
      }
      // Normal setup delegates to native Homebrew, not the named ownership
      // workflow. No package ledger, rollback or interrupted-operation replay.
      let execution = try packageInstaller.apply(file) { _ in }
      commands.append(
        .init(
          executable: preview.command[0], arguments: Array(preview.command.dropFirst()),
          terminationStatus: execution.status, output: execution.diagnostic))
      guard execution.status == 0 else {
        throw SetupPackageAdoptionError(
          "Homebrew exited with status \(execution.status): \(execution.diagnostic)")
      }
      let inventory = try planner.packageInventory(context: context, adoptionState: .available(nil))
      guard inventory.effectiveBrewfile == preview.effectiveBrewfile else {
        throw SetupPackageAdoptionError(
          "Package intent changed during installation; review the new plan.")
      }
      let remaining = try HomebrewInstallPlan(inventory: inventory)
      guard remaining.identities.isEmpty else {
        throw SetupPackageAdoptionError(
          "Packages remain missing: " + remaining.identities.map(\.key).joined(separator: ", "))
      }
      return .init(
        outcome: "installed", mutated: true, commands: commands,
        message:
          "Missing setup packages installed. No package adoption or provider configuration was performed by this stage."
      )
    } catch {
      return .init(
        outcome: "failed", mutated: mutated, commands: commands,
        message:
          "Package installation stopped: \(error). Native effects are retained, not rolled back. Let any native work finish, then review a fresh setup plan before retrying."
      )
    }
  }

  private func failureAfterRollback(
    transaction: UnifiedSetupTransaction?,
    mutated: Bool,
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    plan: UnifiedSetupPlanReport,
    packages: UnifiedSetupPackageApply,
    theme: UnifiedSetupApplyStage? = nil,
    desktop: UnifiedSetupApplyStage? = nil,
    environment: UnifiedSetupApplyStage? = nil,
    message: String,
    json: Bool
  ) async throws -> CommandExecution {
    guard let transaction else {
      return try result(
        outcome: "failed",
        mutated: mutated,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: message,
        json: json
      )
    }
    do {
      _ = try await transactionTeardown.recover(
        transaction: transaction,
        context: context,
        consumerPaths: consumerPaths
      )
      // Only now are native replacements and every component back in place.
      let sessionMessage: String
      do {
        let restoredProfile = try context.loadProfile().profile.environment
        sessionMessage = restoredSessionMessage(
          restoredSessionVerifier.verifyRestored(restoredProfile, context.homeDirectory))
      } catch {
        sessionMessage =
          " Configuration files were restored; native startup could not be verified because the profile could not be read: \(error)."
      }
      return try result(
        outcome: "rolled_back",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message:
          "Configuration was rolled back. \(message)\(sessionMessage) Installed packages and manual permission decisions remain. Resume: \(GuidedSetupPermissions.resumeCommand(context)). The current configuration plan must be reviewed again before retrying.",
        json: json
      )
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: true,
        plan: plan,
        packages: packages,
        theme: theme,
        desktop: desktop,
        environment: environment,
        message: "\(message) Rollback requires recovery: \(error)",
        json: json
      )
    }
  }

  private func recoverInterrupted(
    context: UnifiedSetupPlanContext,
    consumerPaths: ThemeConsumerPaths,
    json: Bool
  ) async throws -> CommandExecution {
    do {
      let recovered = try await transactionTeardown.recoverPendingLocked(
        context: context,
        consumerPaths: consumerPaths
      )
      let warning =
        try EnvironmentStateStore(stateRoot: context.stateRoot)
        .hasUnverifiedSpicetifyRecovery()
        ? " \(EnvironmentStateStore.spicetifyRecoveryMessage)" : ""
      if recovered.transaction.operation == .apply,
        recovered.transaction.phase == .committing
      {
        return try result(
          outcome: "applied",
          mutated: recovered.result.mutated,
          plan: nil,
          environment: recovered.result.environment.map {
            UnifiedSetupApplyStage(
              succeeded: $0.succeeded, mutated: $0.mutated, message: $0.message,
              details: nil, finalization: $0)
          },
          message: "Interrupted unified apply had committed; transaction cleanup completed."
            + warning,
          json: json
        )
      }
      return try result(
        outcome: recovered.transaction.operation == .apply ? "rolled_back" : "blocked",
        mutated: recovered.result.mutated,
        plan: nil,
        message: (recovered.transaction.operation == .apply
          ? "Interrupted unified apply was rolled back; review the current plan before retrying."
          : "Interrupted teardown was completed; review the current plan before applying.")
          + warning,
        json: json
      )
    } catch {
      return try result(
        outcome: "recovery_required",
        mutated: true,
        plan: nil,
        message: String(describing: error),
        json: json
      )
    }
  }

  private func stage(
    _ report: ThemeSetJSONReport,
    successMessage: String
  ) -> UnifiedSetupApplyStage {
    stage(
      .theme(report), succeeded: report.succeeded, mutated: report.committed,
      failureMessage: report.error, successMessage: successMessage)
  }

  private func stage(
    _ report: DesktopAggregateMutationReport,
    successMessage: String
  ) -> UnifiedSetupApplyStage {
    stage(
      .desktopApply(report), succeeded: report.succeeded, mutated: report.mutated,
      failureMessage: report.message, successMessage: successMessage)
  }

  private func stage(
    _ report: EnvironmentLifecycleReport,
    successMessage: String
  ) -> UnifiedSetupApplyStage {
    stage(
      .environment(report), succeeded: report.succeeded, mutated: report.mutated,
      failureMessage: report.message,
      successMessage: report.outcome == "applied_incomplete" ? report.message : successMessage)
  }

  private func stage(
    _ report: PreferencesReport,
    successMessage: String
  ) throws -> UnifiedSetupApplyStage {
    guard let mutated = report.mutated else {
      throw SetupComponentReportError(
        description: "Delegated result is missing boolean field 'mutated'.")
    }
    return stage(
      .preferences(report), succeeded: report.succeeded, mutated: mutated,
      failureMessage: report.message, successMessage: successMessage)
  }

  private func stage(
    _ details: SetupStageDetails,
    succeeded: Bool,
    mutated: Bool,
    failureMessage: String?,
    successMessage: String
  ) -> UnifiedSetupApplyStage {
    UnifiedSetupApplyStage(
      succeeded: succeeded,
      mutated: mutated,
      message: succeeded ? successMessage : failureMessage ?? "The delegated operation failed.",
      details: details
    )
  }

  private func result(
    outcome: String,
    mutated: Bool,
    plan: UnifiedSetupPlanReport?,
    packages: UnifiedSetupPackageApply? = nil,
    theme: UnifiedSetupApplyStage? = nil,
    desktop: UnifiedSetupApplyStage? = nil,
    environment: UnifiedSetupApplyStage? = nil,
    preferences: UnifiedSetupApplyStage? = nil,
    message: String,
    json: Bool
  ) throws -> CommandExecution {
    let report = UnifiedSetupApplyReport(
      outcome: outcome,
      mutated: mutated,
      plan: plan,
      packages: packages,
      theme: theme,
      desktop: desktop,
      environment: environment,
      preferences: preferences,
      message: message
    )
    return (try report.render(json: json), report.succeeded)
  }
}

struct UnifiedSetupPackageApply: Encodable, Sendable {
  let outcome: String
  let mutated: Bool
  let commands: [UnifiedSetupHomebrewCommand]
  let message: String

  var succeeded: Bool { outcome != "failed" }

  static let noChange = Self(
    outcome: "no_change",
    mutated: false,
    commands: [],
    message:
      "Effective setup packages are already satisfied; no Homebrew command or adoption was needed."
  )
}

struct UnifiedSetupHomebrewCommand: Encodable, Sendable {
  let executable: String
  let arguments: [String]
  let terminationStatus: Int32
  let output: String

  enum CodingKeys: String, CodingKey {
    case executable, arguments, output
    case terminationStatus = "termination_status"
  }
}

struct UnifiedSetupApplyStage: Encodable, Sendable {
  let succeeded: Bool
  let mutated: Bool
  let message: String
  let details: SetupStageDetails?
  var finalization: UnifiedSetupTeardownStage? = nil

  var hasPendingThemeVerification: Bool {
    if case .environment(let report) = details { return report.outcome == "applied_incomplete" }
    return false
  }

  func finalized(by report: UnifiedSetupTeardownStage?) -> Self {
    guard let report else { return self }
    return Self(
      succeeded: succeeded && report.succeeded,
      mutated: mutated || report.mutated,
      message: message + " " + report.message,
      details: details,
      finalization: report)
  }

  static func noChange(_ message: String) -> Self {
    Self(succeeded: true, mutated: false, message: message, details: nil)
  }
}

private struct UnifiedSetupApplyReport: CommandReport {
  let schemaVersion = 1
  let operation = "setup_apply"
  let outcome: String
  let mutated: Bool
  let plan: UnifiedSetupPlanReport?
  let packages: UnifiedSetupPackageApply?
  let theme: UnifiedSetupApplyStage?
  let desktop: UnifiedSetupApplyStage?
  let environment: UnifiedSetupApplyStage?
  let preferences: UnifiedSetupApplyStage?
  let message: String

  var succeeded: Bool {
    outcome == "applied" || outcome == "applied_incomplete" || outcome == "no_change"
  }

  func renderText() throws -> String {
    var lines = [
      "Macarchy setup apply [\(outcome)]:",
      "- mutated: \(mutated ? "yes" : "no")",
      "- \(message)",
    ]
    if let packages { lines.append("- packages [\(packages.outcome)]: \(packages.message)") }
    if let theme { lines.append("- theme: \(theme.message)") }
    if let desktop { lines.append("- desktop: \(desktop.message)") }
    if let environment { lines.append("- environment: \(environment.message)") }
    if let preferences { lines.append("- preferences: \(preferences.message)") }
    return lines.joined(separator: "\n")
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, outcome, mutated, plan, packages, theme, desktop, environment, preferences,
      message
  }
}
