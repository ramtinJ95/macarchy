import Foundation
import ThemeCore

struct SetupPackageInstallationCommandRunner: Sendable {
  enum Checkpoint: Sendable {
    case beforeRevalidation, afterIntent, afterNativeOutcome, afterPublication
  }
  let planner: UnifiedSetupPlanCommandRunner
  let provider: HomebrewFormulaInstallProvider
  var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

  static func live(homeDirectory: URL) -> Self {
    .init(planner: .live, provider: .live(homeDirectory: homeDirectory))
  }

  private struct Inputs: Encodable, Sendable {
    let contract = "setup_formula_installation_v1"
    let contextDigest: String
    let profilePaths: [String]
    let selected: [HomebrewPackageIdentity]
    let targets: [SetupPackageInstallationAttempt.Target]
    let inventory: SetupPackageInventory
    let ledger: SetupPackageAdoptionLedger?
  }

  func execute(
    context: UnifiedSetupPlanContext, targets: [String], approval: String?,
    recover: Bool = false, json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let store = SetupPackageInstallationStore(context: context)
    var effects: HomebrewFormulaInstallEffects?
    do {
      if recover {
        guard targets.isEmpty, approval == nil else {
          throw SetupPackageAdoptionError("--recover cannot be combined with targets or approval.")
        }
        return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
          guard try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil else {
            throw SetupPackageAdoptionError("Resolve the unified setup transaction first.")
          }
          guard let attempt = try store.read() else {
            return try result(
              "no_change", message: "No package installation attempt exists.", json: json)
          }
          guard attempt.phase == .running else {
            return try result(
              attempt.phase.rawValue, attempt: attempt,
              message: "Last attempt is already resolved; no Homebrew command was run.", json: json)
          }
          return try finish(attempt, context: context, store: store, json: json)
        }
      }
      let identities = try SetupPackageAdoptionCommandRunner.parseTargets(targets)
      try store.requireResolved()
      let inputs = try inputs(context: context, identities: identities)
      guard !inputs.targets.isEmpty else {
        return try result(
          "no_change",
          message: "Every named formula matches its applied declaration; nothing was written.",
          json: json)
      }
      let names = inputs.targets.map(\.identity.name)
      let prepared = try provider.prepare(names)
      effects = prepared
      try prepared.validate(roots: names)
      let componentNames = Set(prepared.components.map(\.name))
      guard
        !inputs.inventory.observation.packages.contains(where: {
          $0.kind == .formula && componentNames.contains($0.token)
        })
      else {
        throw SetupPackageAdoptionError("An effect would change an already-installed formula.")
      }
      let inputDigest = try SetupPackageInstallationStore.digest(inputs)
      struct Binding: Encodable {
        let inputDigest: String
        let effects: HomebrewFormulaInstallEffects
      }
      let digest = try SetupPackageInstallationStore.digest(
        Binding(inputDigest: inputDigest, effects: prepared))
      guard let approval else {
        return try result(
          "preview", effects: prepared, approval: digest, targets: inputs.targets,
          message:
            "Review all new formulae, versions, bottle hashes and prefix effects; repeat with --approve \(digest). No installation occurred.",
          json: json)
      }
      guard approval == digest else {
        throw SetupPackageAdoptionError(
          "Approval does not match current installation inputs and complete effects.")
      }
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try store.requireResolved()
        try checkpoint(.beforeRevalidation)
        let revalidate: @Sendable () throws -> Void = {
          let current = try self.inputs(context: context, identities: identities)
          guard try SetupPackageInstallationStore.digest(current) == inputDigest else {
            throw SetupPackageAdoptionError(
              "Profile, receipts or ownership changed before native execution.")
          }
        }
        try revalidate()
        var attempt = SetupPackageInstallationAttempt(
          schemaVersion: 1, contextDigest: store.contextDigest, approvalDigest: digest,
          priorLedgerDigest: try SetupPackageInstallationStore.digest(inputs.ledger),
          targets: inputs.targets, effects: prepared, baseline: inputs.inventory.observation)
        try store.write(attempt)
        do {
          try checkpoint(.afterIntent)
          // Live provider stages fresh effects, compares them, then calls this
          // input revalidation immediately before the confined native command.
          let execution = try provider.apply(names, prepared, revalidate) { processGroup in
            guard var current = try store.read(), current.phase == .running,
              current.approvalDigest == digest, current.processGroup == nil
            else {
              throw SetupPackageAdoptionError(
                "Installation intent changed before process publication.")
            }
            current.processGroup = processGroup
            try store.write(current)
          }
          attempt.processGroup = try store.read()?.processGroup
          attempt.nativeExit = execution.status
          attempt.diagnostic = String(execution.diagnostic.prefix(8 * 1024))
          try store.write(attempt)
          try checkpoint(.afterNativeOutcome)
          return try finish(attempt, context: context, store: store, json: json)
        } catch {
          return try result(
            "recovery_required", attempt: attempt,
            message:
              "Installation attempt needs observation-only --recover: \(error). No rollback is claimed.",
            json: json)
        }
      }
    } catch {
      return try result("blocked", effects: effects, message: String(describing: error), json: json)
    }
  }

  private func inputs(context: UnifiedSetupPlanContext, identities: [HomebrewPackageIdentity])
    throws -> Inputs
  {
    guard identities.allSatisfy({ $0.kind == .formula && !$0.name.contains("/") }) else {
      throw SetupPackageAdoptionError(
        "Only missing official formula targets are supported; no casks or third-party taps.")
    }
    guard try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil else {
      throw SetupPackageAdoptionError(
        "Resolve interrupted unified setup before installing packages.")
    }
    let ledger = try SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory
    ).read()
    let inventory = try planner.packageInventory(
      context: context, adoptionState: .available(ledger))
    guard inventory.observation.status == "available",
      (ledger?.entries ?? []).allSatisfy({ $0.status(in: inventory.observation) == "adopted" })
    else {
      throw SetupPackageAdoptionError(
        "Incomplete package inventory or drifted adoption evidence blocks installation.")
    }
    let targets = try identities.compactMap { identity -> SetupPackageInstallationAttempt.Target? in
      guard let package = inventory.proposed.first(where: { $0.identity == identity }) else {
        throw SetupPackageAdoptionError("\(identity.key) is not declared by the effective profile.")
      }
      if package.adoption == "adopted" { return nil }
      guard package.homebrewStatus == "missing", package.externallySatisfiedCapabilities.isEmpty
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
      selected: identities, targets: targets, inventory: inventory, ledger: ledger)
  }

  private func finish(
    _ pending: SetupPackageInstallationAttempt, context: UnifiedSetupPlanContext,
    store: SetupPackageInstallationStore, json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    var attempt = pending
    if let group = attempt.processGroup, try HomebrewFormulaInstallProcess.groupExists(group) {
      throw SetupPackageAdoptionError(
        "Installation process group is still present. Wait for it to exit before --recover; no process was killed or rerun."
      )
    }
    let observation = planner.packageInventoryReader()
    attempt.verifiedComponents = provider.verify(attempt.effects, observation).sorted()
    let newNames = Set(attempt.effects.components.map(\.name))
    let existing = observation.packages.filter {
      !($0.kind == .formula && newNames.contains($0.token))
    }
    let complete =
      attempt.nativeExit == 0 && observation.status == "available"
      && existing == attempt.baseline.packages
      && Set(attempt.verifiedComponents) == newNames
    guard complete else {
      attempt.phase = .partial
      try store.write(attempt)
      return try result(
        "partial", attempt: attempt,
        message:
          "Native success and complete verification were not both established. No declarations were adopted, no rollback or retry occurred. Inspect installed packages before explicit adoption or a new plan.",
        json: json)
    }
    let ledgerStore = SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
    let entries = try attempt.targets.map { target -> SetupPackageAdoptionLedger.Entry in
      let matches = observation.packages.filter { $0.identity == target.identity }
      guard matches.count == 1, let package = matches.first, package.issue == nil,
        package.receipts.count == 1, package.receiptPaths == package.receipts.map(\.path),
        package.versions
          == attempt.effects.components.filter({ $0.name == target.identity.name }).map(\.version)
      else {
        throw SetupPackageAdoptionError("Incomplete root receipts prevent declaration publication.")
      }
      return .init(
        identity: target.identity, versions: package.versions, receipts: package.receipts,
        declarations: target.declarations, approvalDigest: attempt.approvalDigest)
    }
    let current = try ledgerStore.read()
    if try SetupPackageInstallationStore.digest(current) == attempt.priorLedgerDigest {
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
        try SetupPackageInstallationStore.digest(prior) == attempt.priorLedgerDigest
      else {
        throw SetupPackageAdoptionError(
          "Adoption ledger changed during installation; publication requires manual review.")
      }
    }
    try checkpoint(.afterPublication)
    attempt.phase = .complete
    try store.write(attempt)
    return try result(
      "complete", attempt: attempt,
      message:
        "Native installation and verification completed. Only named declarations were recorded; new dependencies remain Homebrew-owned. No provider configuration changed.",
      json: json)
  }

  private func result(
    _ outcome: String, effects: HomebrewFormulaInstallEffects? = nil,
    approval: String? = nil, attempt: SetupPackageInstallationAttempt? = nil,
    targets: [SetupPackageInstallationAttempt.Target] = [],
    message: String, json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    struct Report: Encodable {
      let operation = "setup_install_packages"
      let outcome: String
      let approvalDigest: String?
      let effects: HomebrewFormulaInstallEffects?
      let targets: [SetupPackageInstallationAttempt.Target]
      let attempt: SetupPackageInstallationAttempt.Summary?
      let message: String
    }
    let report = Report(
      outcome: outcome, approvalDigest: approval, effects: effects ?? attempt?.effects,
      targets: attempt?.targets ?? targets,
      attempt: attempt?.summary, message: message)
    // Human previews include the same complete, reviewable effect document.
    let output = try renderJSON(report)
    return (
      json ? output : "Package installation [\(outcome)]\n\(output)",
      ["preview", "no_change", "complete"].contains(outcome)
    )
  }
}
