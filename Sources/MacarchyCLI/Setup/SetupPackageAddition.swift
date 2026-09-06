import Foundation
import ThemeCore

struct SetupPackageAdditionCommandRunner: Sendable {
  enum Checkpoint: Sendable {
    case beforeRevalidation
    case afterInput(Int)
    case afterSave
  }
  let planner: UnifiedSetupPlanCommandRunner
  let provider: HomebrewBundleInstaller
  var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

  static func live(homeDirectory: URL) -> Self {
    .init(planner: .live, provider: .live(homeDirectory: homeDirectory))
  }

  private struct Prepared: Encodable, Sendable {
    let contract = "setup_package_addition_v2"
    let layer: String
    let targets: [HomebrewPackageIdentity]
    let profileDigests: [String: String]
    let edits: [SetupPackageInputEdit]
    let sourceBindings: [String: String]
    let installation: SetupPackageInstallationCommandRunner.Inputs?
    let adoption: SetupPackageAdoptionCommandRunner.Prepared?

    var digest: String { get throws { try SetupPackageInstallationStore.digest(self) } }
    var noChange: Bool {
      !edits.contains(where: \.changed) && (installation?.targets.isEmpty ?? true)
        && (adoption?.additions.isEmpty ?? true)
    }
  }

  func execute(
    context: UnifiedSetupPlanContext, targets: [String], machineOnly: Bool = false,
    approval: String?, recover: Bool = false, json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    var reviewed: Prepared?
    var intent = "unchanged"
    var stages: [SetupComponentExecution] = []
    do {
      if recover {
        guard targets.isEmpty, approval == nil, !machineOnly else {
          throw SetupPackageAdoptionError(
            "--recover takes no targets, approval or --machine-only; it uses the recorded selected layer."
          )
        }
        let recovered = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
          try SetupPackageInputPublicationStore(context: context).recover()
        }
        return try result(
          recovered ? "recovered" : "no_change", prepared: nil,
          intent: recovered ? "saved" : "unchanged", stages: [],
          message: recovered
            ? "Previously approved input publication is complete. No Homebrew or adoption action ran. Obtain a fresh add-packages preview and approval for pending package work."
            : "No interrupted input publication. No package action ran.", json: json)
      }
      let prepared = try prepare(context: context, targets: targets, machineOnly: machineOnly)
      reviewed = prepared
      if prepared.noChange {
        return try result(
          "no_change", prepared: prepared, intent: intent, stages: stages,
          message: "Requested intent and named declarations already match; nothing was written.",
          json: json)
      }
      let digest = try prepared.digest
      guard let approval else {
        return try result(
          "preview", prepared: prepared, intent: intent, stages: stages,
          message:
            "Review the resolved file edit, receipts and native command. Repeat with --approve \(digest). Homebrew owns dependency and related-package effects; no provider configuration will change.",
          json: json)
      }
      guard approval == digest else {
        throw SetupPackageAdoptionError(
          "Approval does not match the current file edit and named package actions.")
      }
      // Release the lifecycle lock after publication. Existing command runners
      // take their own lock and revalidate their original, reviewed scope.
      let publication = try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try checkpoint(.beforeRevalidation)
        let current = try prepare(context: context, targets: targets, machineOnly: machineOnly)
        guard try current.digest == digest else {
          throw SetupPackageAdoptionError(
            "Personal inputs or package evidence changed before saving.")
        }
        return Result {
          try SetupPackageInputPublicationStore(context: context).publish(
            edits: current.edits, sourceBindings: current.sourceBindings, approval: digest,
            checkpoint: { try checkpoint(.afterInput($0)) })
        }
      }
      do { try publication.get() } catch {
        intent = "publication_unverified"
        throw SetupPackageAdoptionError(
          "Input publication could not be confirmed: \(error). Use setup add-packages --recover with the same profile/state options. Drift or retained sibling residue requires manual inspection; no package action started."
        )
      }
      intent = "saved"
      try checkpoint(.afterSave)
      if let installation = prepared.installation, !installation.targets.isEmpty {
        let execution = try SetupComponentExecution(
          await SetupPackageInstallationCommandRunner(
            planner: planner, provider: provider
          ).execute(
            context: context, targets: installation.selected.map(\.key),
            approval: SetupPackageInstallationStore.digest(installation), json: true))
        stages.append(execution)
        guard execution.succeeded else {
          throw SetupPackageAdoptionError(
            "Named installation did not complete; inspect the installation report and use setup install-packages --recover when required."
          )
        }
      }
      if let adoption = prepared.adoption, !adoption.additions.isEmpty {
        let runner = SetupPackageAdoptionCommandRunner(planner: planner)
        let identities = adoption.candidates.map(\.identity)
        let current = try runner.prepare(
          context: context, identities: identities,
          store: SetupPackageAdoptionStore(
            stateRoot: context.stateRoot, homeDirectory: context.homeDirectory))
        // Only named installation entries may have joined the reviewed ledger.
        // Never renew consent over unrelated history changes or a newly expanded
        // adoption set, even when the installed candidate bytes still match.
        let installedIdentities = Set(prepared.installation?.targets.map(\.identity) ?? [])
        let retainedEntries =
          current.ledger?.entries.filter {
            !installedIdentities.contains($0.identity)
          } ?? []
        guard
          retainedEntries == (adoption.ledger?.entries ?? []),
          try SetupPackageInstallationStore.digest(current.candidates)
            == SetupPackageInstallationStore.digest(adoption.candidates)
        else {
          throw SetupPackageAdoptionError(
            "Reviewed installed candidates or prior adoption history changed after saving; preview again before adoption."
          )
        }
        let execution = try SetupComponentExecution(
          await runner.execute(
            context: context, targets: identities.map(\.key), approval: current.digest, json: true))
        stages.append(execution)
        guard execution.succeeded else {
          throw SetupPackageAdoptionError(
            "Named adoption did not complete; inspect the adoption report before retrying.")
        }
      }
      let verified = try prepare(context: context, targets: targets, machineOnly: machineOnly)
      guard verified.noChange,
        prepared.edits.allSatisfy({ edit in
          verified.edits.contains { $0.path == edit.path && $0.before == edit.after }
        })
      else {
        throw SetupPackageAdoptionError(
          "Saved intent or named package state changed before final verification; preview again.")
      }
      return try result(
        "complete", prepared: prepared, intent: intent, stages: stages,
        message:
          "Intent is saved and named packages converged. No provider configuration changed; native dependency effects remain Homebrew-owned.",
        json: json)
    } catch {
      return try result(
        intent == "saved" ? "pending" : "blocked", prepared: reviewed,
        intent: intent, stages: stages,
        message: (intent == "saved" ? "Intent was saved; Macarchy did not roll it back. " : "")
          + String(describing: error), json: json)
    }
  }

  private func prepare(context: UnifiedSetupPlanContext, targets: [String], machineOnly: Bool)
    throws -> Prepared
  {
    let identities = try SetupPackageAdoptionCommandRunner.parseTargets(targets)
    try SetupPackageInstallationStore(context: context).requireResolved()
    try SetupPackageInputPublicationStore(context: context).requireResolved()
    guard try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil else {
      throw SetupPackageAdoptionError("Resolve interrupted unified setup before adding packages.")
    }
    let layered = try PortableProfileLoader().load(
      portableAt: context.profileURL, portableRequired: machineOnly && context.profileRequired,
      machineAt: context.machineProfileURL,
      machineRequired: !machineOnly && context.machineProfileRequired)
    let kind: PortableProfileLayerKind = machineOnly ? .machine : .portable
    let source = machineOnly ? context.machineProfileURL : context.profileURL
    guard context.profileURL.path != context.machineProfileURL.path else {
      throw SetupPackageAdoptionError("Portable and machine profiles must have distinct paths.")
    }
    let sourceBindings = Dictionary(
      uniqueKeysWithValues: [context.profileURL, context.machineProfileURL].map {
        ($0.path, $0.resolvingSymlinksInPath().standardizedFileURL.path)
      })
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    guard Set(sourceBindings.values).count == 2 else {
      throw SetupPackageAdoptionError(
        "Both layers resolve to the same profile; separate them before editing.")
    }
    let layer = layered.profile.packages.layers.first(where: { $0.kind == kind })
    let url =
      layer?.brewfileURL
      ?? resolved.deletingLastPathComponent().appending(
        path: resolved.lastPathComponent + ".Brewfile")
    guard
      !layered.profile.packages.layers.contains(where: { $0.kind != kind && $0.brewfileURL == url })
    else {
      throw SetupPackageAdoptionError(
        "Both layers reference the same Brewfile; configure separate fragments before editing one layer."
      )
    }
    func exclusions(_ layer: PackageProfile.Layer) -> Set<HomebrewPackageIdentity> {
      Set(
        layer.excludedFormulae.map {
          HomebrewPackageIdentity(kind: .formula, name: $0)
        }
          + layer.excludedCasks.map {
            HomebrewPackageIdentity(kind: .cask, name: $0)
          })
    }
    for contribution in layered.profile.packages.layers {
      let excluded = exclusions(contribution)
      if let conflict = identities.first(where: { excluded.contains($0) }),
        !machineOnly && contribution.kind == .machine
      {
        throw SetupPackageAdoptionError(
          "\(contribution.sourceURL.path) excludes \(conflict.key). Machine intent defeats the portable request; add will not edit another layer or silently switch layers."
        )
      }
    }
    let removed = (layer.map(exclusions) ?? []).intersection(identities)
    let profileEdit = try SetupPackageProfileEdit.prepare(
      source: resolved, fragment: url, needsWiring: layer?.brewfileURL == nil, removing: removed)
    guard !sourceBindings.values.contains(url.path) else {
      throw SetupPackageAdoptionError("A profile cannot also be the selected Brewfile.")
    }
    let edit = try SetupPackageInputEdit.prepare(url: url, targets: identities)
    let future = try SetupBrewfile.parse(edit.after)
    var proposedPlanner = planner
    proposedPlanner.proposedProfileSources = [resolved: profileEdit.after]
    let originalReader = planner.personalBrewfile
    proposedPlanner.personalBrewfile = { path in
      path == url ? future : try originalReader(path)
    }
    let store = SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
    let inventory = try proposedPlanner.packageInventory(
      context: context, adoptionState: .available(store.read()))
    var missing: [HomebrewPackageIdentity] = []
    var installed: [HomebrewPackageIdentity] = []
    for identity in identities {
      guard let package = inventory.proposed.first(where: { $0.identity == identity }) else {
        throw SetupPackageAdoptionError("\(identity.key) is not effective after the proposed edit.")
      }
      if package.homebrewStatus == "missing" {
        missing.append(identity)
      } else {
        installed.append(identity)
      }
    }
    let installation =
      try missing.isEmpty
      ? nil
      : SetupPackageInstallationCommandRunner(
        planner: proposedPlanner, provider: provider
      ).inputs(context: context, identities: missing)
    if !(installation?.targets.isEmpty ?? true) { try provider.preflight() }
    let adoption =
      try installed.isEmpty
      ? nil
      : SetupPackageAdoptionCommandRunner(planner: proposedPlanner)
        .prepare(context: context, identities: installed, store: store)
    var profileDigests: [String: String] = [:]
    for source in layered.layers where source.present {
      let resolved = source.sourceURL.resolvingSymlinksInPath().standardizedFileURL
      profileDigests[source.sourceURL.path] = try SetupPackageInstallationStore.digest([
        resolved.path,
        sha256Digest(BoundedRegularFile.read(at: resolved, maximumSize: 65_536).data),
      ])
    }
    return Prepared(
      layer: kind.rawValue, targets: identities, profileDigests: profileDigests,
      edits: [edit, profileEdit], sourceBindings: sourceBindings,
      installation: installation, adoption: adoption)
  }

  private func result(
    _ outcome: String, prepared: Prepared?, intent: String,
    stages: [SetupComponentExecution], message: String, json: Bool
  )
    throws -> (output: String, succeeded: Bool)
  {
    struct Report: Encodable {
      let operation = "setup_add_packages"
      let outcome: String
      let intent: String
      let approvalDigest: String?
      let preview: Preview?
      let stages: [SetupComponentExecution]
      let message: String
    }
    let output = try renderJSON(
      Report(
        outcome: outcome, intent: intent,
        approvalDigest: outcome == "preview" ? try prepared?.digest : nil,
        preview: prepared.map(Preview.init), stages: stages, message: message))
    return (
      json ? output : "Package addition [\(outcome)]\n\(output)",
      ["preview", "no_change", "complete", "recovered"].contains(outcome)
    )
  }

  /// Keep the report named-scope only. Whole-ledger and source metadata evidence
  /// bind approval internally; neither is another inventory to dump in previews.
  private struct Preview: Encodable {
    struct Installation: Encodable {
      let targets: [SetupPackageInstallationAttempt.Target]
      let brewfile: String
      let command: [String]
      let environment: [String]
      let nativeEffects: [String]
    }
    let layer: String
    let targets: [String]
    struct Edit: Encodable {
      let path: String
      let before: String?
      let after: String
      let operation: String
    }
    let edits: [Edit]
    let installation: Installation?
    let adoption: [SetupPackageAdoptionCommandRunner.Candidate]
    let alreadyAdopted: [String]

    init(_ prepared: Prepared) {
      layer = prepared.layer
      targets = prepared.targets.map(\.key)
      edits = prepared.edits.map {
        .init(
          path: $0.path, before: $0.before, after: $0.after,
          operation: !$0.changed ? "unchanged" : $0.before == nil ? "create" : "replace")
      }
      installation = prepared.installation.map {
        .init(
          targets: $0.targets, brewfile: $0.brewfile, command: $0.command,
          environment: $0.environment, nativeEffects: $0.nativeEffects)
      }
      adoption = prepared.adoption?.additions ?? []
      let additions = Set(adoption.map(\.identity))
      alreadyAdopted =
        prepared.adoption?.candidates.filter { !additions.contains($0.identity) }.map(
          \.identity.key) ?? []
    }
  }
}
