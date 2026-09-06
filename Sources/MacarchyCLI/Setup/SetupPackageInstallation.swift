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
    let selectedPackages: [SetupPackageInventory.Package]
    let ledger: SetupPackageAdoptionLedger?

    enum CodingKeys: String, CodingKey {
      case contract, contextDigest, profilePaths, selected, targets
      case selectedInstallations, selectedPackages, ledger, brewfile, command, environment
    }
  }

  func execute(
    context: UnifiedSetupPlanContext, targets: [String], approval: String?,
    recover: Bool = false, json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let store = SetupPackageInstallationStore(context: context)
    var reviewed: Inputs?
    var observation: HomebrewPackageObservation?
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
      observation = inputs.observation
      reviewed = inputs
      guard !inputs.targets.isEmpty else {
        return try result(
          "no_change", observation: observation,
          message: "Every named formula matches its applied declaration; nothing was written.",
          json: json)
      }
      try provider.preflight()
      let digest = try SetupPackageInstallationStore.digest(inputs)
      guard let approval else {
        return try result(
          "preview", brewfile: inputs.brewfile, command: inputs.command,
          approval: digest, targets: inputs.targets,
          observation: observation,
          message:
            "Review the Brewfile and native command scope; Homebrew owns dependency and related-package effects. Repeat with --approve \(digest). No installation occurred.",
          json: json)
      }
      guard approval == digest else {
        throw SetupPackageAdoptionError(
          "Approval does not match the current Brewfile, declared inputs and native command.")
      }
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try store.requireResolved()
        try checkpoint(.beforeRevalidation)
        let revalidate: @Sendable () throws -> Void = {
          let current = try self.inputs(context: context, identities: identities)
          guard try SetupPackageInstallationStore.digest(current) == digest else {
            throw SetupPackageAdoptionError(
              "Profile, receipts or ownership changed before native execution.")
          }
        }
        try revalidate()
        var attempt = SetupPackageInstallationAttempt(
          schemaVersion: 3, contextDigest: store.contextDigest, approvalDigest: digest,
          priorLedgerDigest: try SetupPackageInstallationStore.digest(inputs.ledger),
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
      return try result(
        "blocked", brewfile: reviewed?.brewfile, command: reviewed?.command,
        observation: observation,
        message: String(describing: error), json: json)
    }
  }

  func inputs(context: UnifiedSetupPlanContext, identities: [HomebrewPackageIdentity])
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
    guard inventory.observation.issues.isEmpty else {
      throw SetupPackageAdoptionError(
        "Complete formula and cask listings are required before installation: "
          + inventory.observation.issues.joined(separator: "; "))
    }
    guard
      (ledger?.entries ?? []).filter({ identities.contains($0.identity) })
        .allSatisfy({ $0.status(in: inventory.observation) == "adopted" })
    else {
      throw SetupPackageAdoptionError(
        "A named target has drifted adoption evidence; installation cannot replace it.")
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
      selected: identities, targets: targets, observation: inventory.observation,
      selectedInstallations: inventory.observation.packages.filter { package in
        identities.contains { $0.kind == package.kind && $0.token == package.token }
      },
      brewfile: SetupBrewfile(packages: targets.map(\.identity)).text,
      command: ["/opt/homebrew/bin/brew"] + HomebrewBundleInstaller.arguments
        + [SetupPackageInstallationStore(context: context).brewfileURL.path],
      environment: HomebrewBundleInstaller.environment,
      selectedPackages: inventory.proposed.filter { identities.contains($0.identity) },
      ledger: ledger)
  }

  private func finish(
    _ pending: SetupPackageInstallationAttempt, context: UnifiedSetupPlanContext,
    store: SetupPackageInstallationStore, json: Bool
  ) throws -> (output: String, succeeded: Bool) {
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
      return try result(
        "partial", attempt: attempt, observation: observation,
        message:
          "Native success and observed named installations were not both established. No declarations were adopted, no rollback or retry occurred. Inspect installed packages before explicit adoption or a new plan.",
        json: json)
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
      "complete", attempt: attempt, observation: observation,
      message:
        "Native installation succeeded and named receipts were observed. Only named declarations were recorded; dependency effects remain Homebrew-owned. No provider configuration changed.",
      json: json)
  }

  private func result(
    _ outcome: String, brewfile: String? = nil, command: [String]? = nil,
    approval: String? = nil, attempt: SetupPackageInstallationAttempt? = nil,
    targets: [SetupPackageInstallationAttempt.Target] = [],
    observation: HomebrewPackageObservation? = nil,
    message: String, json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    struct Report: Encodable {
      let operation = "setup_install_packages"
      let outcome: String
      let approvalDigest: String?
      let brewfile: String?
      let command: [String]?
      let environment: [String]
      let boundary = "native_dependency_and_related_package_effects_delegated_to_homebrew"
      let targets: [SetupPackageInstallationAttempt.Target]
      let attempt: SetupPackageInstallationAttempt.Summary?
      let inventoryWarnings: [HomebrewInstalledPackage]
      let message: String
    }
    let report = Report(
      outcome: outcome, approvalDigest: approval, brewfile: brewfile ?? attempt?.brewfile,
      command: command, environment: HomebrewBundleInstaller.environment,
      targets: attempt?.targets ?? targets,
      attempt: attempt?.summary,
      inventoryWarnings: observation?.packages.filter {
        $0.issue != nil || $0.identity == nil
      } ?? [],
      message: message)
    // Human and JSON previews expose the same declared scope and limitations.
    let output = try renderJSON(report)
    return (
      json ? output : "Package installation [\(outcome)]\n\(output)",
      ["preview", "no_change", "complete"].contains(outcome)
    )
  }
}
