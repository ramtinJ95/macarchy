import Foundation
import ThemeCore

struct SetupPackageInstallationCommandRunner: Sendable {
  enum Checkpoint: Sendable {
    case beforeRevalidation, afterIntent, afterNativeOutcome, afterPublication
  }
  let planner: UnifiedSetupPlanCommandRunner
  let provider: HomebrewBundleInstaller
  var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

  static func live(homeDirectory: URL) -> Self {
    .init(planner: .live, provider: .live(homeDirectory: homeDirectory))
  }

  struct Inputs: Encodable, Sendable {
    let contract = "setup_brewfile_installation_v3"
    let contextDigest: String
    let profilePaths: [String]
    let selected: [HomebrewPackageIdentity]
    let targets: [SetupPackageInstallationAttempt.Target]
    let observation: HomebrewPackageObservation
    let selectedInstallations: [HomebrewInstalledPackage]
    let brewfile: String
    let command: [String]
    let environment: [String]
    let nativeEffects: [String]
    let selectedPackages: [SetupPackageInventory.Package]
    let ledger: SetupPackageAdoptionLedger?

    enum CodingKeys: String, CodingKey {
      case contract, contextDigest, profilePaths, selected, targets
      case selectedInstallations, selectedPackages, ledger, brewfile, command, environment
      case nativeEffects
    }

    /// The `--approve` digest that authorizes installing exactly these inputs.
    var approvalDigest: String { get throws { try canonicalJSONDigest(self) } }
  }

  struct Report: CommandReport, Sendable {
    let operation = "setup_install_packages"
    let outcome: String
    let approvalDigest: String?
    let brewfile: String?
    let command: [String]?
    let environment: [String]
    let boundary = "native_dependency_and_related_package_effects_delegated_to_homebrew"
    let nativeEffects: [String]
    let targets: [SetupPackageInstallationAttempt.Target]
    let attempt: SetupPackageInstallationAttempt.Summary?
    let inventoryWarnings: [HomebrewInstalledPackage]
    let message: String

    var succeeded: Bool { ["preview", "no_change", "complete"].contains(outcome) }

    /// Human and JSON previews expose the same declared scope and limitations.
    func renderText() throws -> String {
      let json = try renderJSON(self)
      return "Package installation [\(outcome)]\n\(json)"
    }
  }

  func execute(
    context: UnifiedSetupPlanContext, targets: [String], approval: String?,
    recover: Bool = false, json: Bool
  ) async throws -> CommandExecution {
    let installation = try await report(
      context: context, targets: targets, approval: approval, recover: recover)
    return (try installation.render(json: json), installation.succeeded)
  }

  func report(
    context: UnifiedSetupPlanContext, targets: [String], approval: String?,
    recover: Bool = false
  ) async throws -> Report {
    let store = SetupPackageInstallationStore(context: context)
    var reviewed: Inputs?
    var observation: HomebrewPackageObservation?
    do {
      if recover {
        guard targets.isEmpty, approval == nil else {
          throw SetupPackageAdoptionError("--recover cannot be combined with targets or approval.")
        }
        return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
          try SetupPendingWork.requireNone(
            .unifiedTransaction(
              refusal: SetupPackageAdoptionError("Resolve the unified setup transaction first.")),
            context: context)
          guard let attempt = try store.read() else {
            return result(
              "no_change", message: "No package installation attempt exists.")
          }
          guard attempt.phase == .running else {
            return result(
              attempt.phase.rawValue, attempt: attempt,
              message: "Last attempt is already resolved; no Homebrew command was run.")
          }
          return try finish(attempt, context: context, store: store)
        }
      }
      let identities = try SetupPackageAdoptionCommandRunner.parseTargets(targets)
      try SetupPendingWork.requireNone(.packageAttempt, context: context)
      let inputs = try inputs(context: context, identities: identities)
      observation = inputs.observation
      reviewed = inputs
      guard !inputs.targets.isEmpty else {
        return result(
          "no_change", observation: observation,
          message: "Every named package matches its applied declaration; nothing was written.")
      }
      try provider.preflight()
      let digest = try inputs.approvalDigest
      guard let approval else {
        return result(
          "preview", brewfile: inputs.brewfile, command: inputs.command,
          approval: digest, targets: inputs.targets,
          observation: observation,
          message:
            "Review the Brewfile and native command scope; Homebrew owns dependency and related-package effects. Repeat with --approve \(digest). No installation occurred."
        )
      }
      guard approval == digest else {
        throw SetupPackageAdoptionError(
          "Approval does not match the current Brewfile, declared inputs and native command.")
      }
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try SetupPendingWork.requireNone(.packageAttempt, context: context)
        try checkpoint(.beforeRevalidation)
        let revalidate: @Sendable () throws -> Void = {
          let current = try self.inputs(context: context, identities: identities)
          guard try current.approvalDigest == digest else {
            throw SetupPackageAdoptionError(
              "Profile, receipts or ownership changed before native execution.")
          }
        }
        try revalidate()
        var attempt = SetupPackageInstallationAttempt(
          schemaVersion: 3, contextDigest: store.contextDigest, approvalDigest: digest,
          priorLedgerDigest: try canonicalJSONDigest(inputs.ledger),
          targets: inputs.targets, brewfile: inputs.brewfile)
        try store.write(attempt)
        do {
          try checkpoint(.afterIntent)
          try inputs.brewfile.write(to: store.brewfileURL, atomically: true, encoding: .utf8)
          try provider.preflight()
          try revalidate()
          guard try SetupBrewfile.read(at: store.brewfileURL).text == inputs.brewfile else {
            throw SetupPackageAdoptionError("Generated Brewfile changed before execution.")
          }
          let execution = try provider.apply(store.brewfileURL) { processSession in
            guard var current = try store.read(), current.phase == .running,
              current.approvalDigest == digest, current.processSession == nil
            else {
              throw SetupPackageAdoptionError(
                "Installation intent changed before process publication.")
            }
            current.processSession = processSession
            try store.write(current)
          }
          attempt.processSession = try store.read()?.processSession
          attempt.nativeExit = execution.status
          attempt.diagnostic = String(execution.diagnostic.prefix(8 * 1024))
          try store.write(attempt)
          try checkpoint(.afterNativeOutcome)
          return try finish(attempt, context: context, store: store)
        } catch {
          return result(
            "recovery_required", attempt: attempt,
            message:
              "Installation attempt needs observation-only --recover: \(error). No rollback is claimed."
          )
        }
      }
    } catch {
      return result(
        "blocked", brewfile: reviewed?.brewfile, command: reviewed?.command,
        observation: observation,
        message: String(describing: error))
    }
  }

  func inputs(context: UnifiedSetupPlanContext, identities: [HomebrewPackageIdentity])
    throws -> Inputs
  {
    try SetupPendingWork.requireNone(
      .unifiedTransaction(
        refusal: SetupPackageAdoptionError(
          "Resolve interrupted unified setup before installing packages.")),
      context: context)
    let ledger = try SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory
    ).read()
    let inventory = try planner.packageInventory(
      context: context, adoptionState: .available(ledger))
    guard inventory.observation.issues.isEmpty else {
      throw SetupPackageAdoptionError(
        "Complete formula and cask listings are required before installation: "
          + inventory.observation.issues.joined(separator: "; "))
    }
    guard
      (ledger?.entries ?? []).filter({ identities.contains($0.identity) })
        .allSatisfy({ $0.status(in: inventory.observation) == .adopted })
    else {
      throw SetupPackageAdoptionError(
        "A named target has drifted adoption evidence; installation cannot replace it.")
    }
    let targets = try identities.compactMap { identity -> SetupPackageInstallationAttempt.Target? in
      guard let package = inventory.proposed.first(where: { $0.identity == identity }) else {
        throw SetupPackageAdoptionError("\(identity.key) is not declared by the effective profile.")
      }
      if package.adoption == .adopted { return nil }
      guard package.homebrewStatus == .missing, package.externallySatisfiedCapabilities.isEmpty
      else {
        throw SetupPackageAdoptionError(
          "\(identity.key) is installed/unadopted, uncertain or externally satisfied; installation cannot replace it."
        )
      }
      return .init(identity: identity, declarations: package.declarations)
    }
    return Inputs(
      contextDigest: SetupPackageInstallationStore(context: context).contextDigest,
      profilePaths: [context.profileURL, context.machineProfileURL].map(\.standardizedFileURL.path),
      selected: identities, targets: targets, observation: inventory.observation,
      selectedInstallations: inventory.observation.packages.filter { package in
        identities.contains { $0.kind == package.kind && $0.token == package.token }
      },
      brewfile: SetupBrewfile.installing(targets.map(\.identity)).text,
      command: [ExternalTool.brew.path] + HomebrewBundleInstaller.arguments
        + [SetupPackageInstallationStore(context: context).brewfileURL.path],
      environment: HomebrewBundleInstaller.environment,
      nativeEffects: HomebrewBundleInstaller.nativeEffects(for: targets.map(\.identity)),
      selectedPackages: inventory.proposed.filter { identities.contains($0.identity) },
      ledger: ledger)
  }

  private func finish(
    _ pending: SetupPackageInstallationAttempt, context: UnifiedSetupPlanContext,
    store: SetupPackageInstallationStore
  ) throws -> Report {
    var attempt = pending
    if let session = attempt.processSession,
      try HomebrewPackageInstallProcess.sessionExists(session)
    {
      throw SetupPackageAdoptionError(
        "Installation process session is still present. Wait for it to exit before --recover; no process was killed or rerun."
      )
    }
    let observation = planner.packageInventoryReader()
    let installed = attempt.targets.compactMap { target -> HomebrewInstalledPackage? in
      let matches = observation.packages.filter {
        $0.kind == target.identity.kind && $0.token == target.identity.token
      }
      guard matches.count == 1, let package = matches.first,
        package.identity == target.identity, package.issue == nil,
        !package.versions.isEmpty, !package.receipts.isEmpty,
        package.receiptPaths == package.receipts.map(\.path)
      else { return nil }
      return package
    }
    attempt.verifiedTargets = installed.compactMap { $0.identity?.key }.sorted()
    guard attempt.nativeExit == 0, observation.issues.isEmpty,
      installed.count == attempt.targets.count
    else {
      attempt.phase = .partial
      try store.write(attempt)
      return result(
        "partial", attempt: attempt, observation: observation,
        message:
          "Native success and observed named installations were not both established. No declarations were adopted, no rollback or retry occurred. Inspect installed packages before explicit adoption or a new plan."
      )
    }
    let ledgerStore = SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
    let entries = try attempt.targets.map { target -> SetupPackageAdoptionLedger.Entry in
      guard let package = installed.first(where: { $0.identity == target.identity }) else {
        throw SetupPackageAdoptionError("Named installation missing during publication.")
      }
      return .init(
        identity: target.identity, versions: package.versions, receipts: package.receipts,
        declarations: target.declarations, approvalDigest: attempt.approvalDigest)
    }
    let current = try ledgerStore.read()
    if try canonicalJSONDigest(current) == attempt.priorLedgerDigest {
      try ledgerStore.write(
        .init(contextDigest: store.contextDigest, entries: (current?.entries ?? []) + entries))
    } else {
      // Crash after the atomic ledger commit: accept only the exact expected
      // additions over the same prior ledger, never overwrite unrelated drift.
      let targets = Set(entries.map(\.identity))
      let remainder = current?.entries.filter { !targets.contains($0.identity) } ?? []
      let prior: SetupPackageAdoptionLedger? =
        remainder.isEmpty
        ? nil
        : .init(contextDigest: store.contextDigest, entries: remainder)
      guard current?.entries.filter({ targets.contains($0.identity) }) == entries,
        try canonicalJSONDigest(prior) == attempt.priorLedgerDigest
      else {
        throw SetupPackageAdoptionError(
          "Adoption ledger changed during installation; publication requires manual review.")
      }
    }
    try checkpoint(.afterPublication)
    attempt.phase = .complete
    try store.write(attempt)
    return result(
      "complete", attempt: attempt, observation: observation,
      message:
        "Native installation succeeded and named receipts were observed. Only named declarations were recorded; dependency effects remain Homebrew-owned. No provider configuration changed."
    )
  }

  private func result(
    _ outcome: String, brewfile: String? = nil, command: [String]? = nil,
    approval: String? = nil, attempt: SetupPackageInstallationAttempt? = nil,
    targets: [SetupPackageInstallationAttempt.Target] = [],
    observation: HomebrewPackageObservation? = nil,
    message: String
  ) -> Report {
    Report(
      outcome: outcome, approvalDigest: approval, brewfile: brewfile ?? attempt?.brewfile,
      command: command, environment: HomebrewBundleInstaller.environment,
      nativeEffects: HomebrewBundleInstaller.nativeEffects(
        for: (attempt?.targets ?? targets).map(\.identity)),
      targets: attempt?.targets ?? targets,
      attempt: attempt?.summary,
      inventoryWarnings: observation?.packages.filter {
        $0.issue != nil || $0.identity == nil
      } ?? [],
      message: message)
  }
}
