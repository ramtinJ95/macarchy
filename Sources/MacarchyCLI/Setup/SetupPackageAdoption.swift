import Foundation
import ThemeCore

struct SetupPackageAdoptionCommandRunner: Sendable {
  enum Checkpoint: Sendable { case beforeRevalidation, beforePublication, afterPublication }

  struct Candidate: Encodable, Sendable {
    let identity: HomebrewPackageIdentity
    let versions: [String]
    let receipts: [HomebrewReceiptEvidence]
    let declarations: [SetupPackageAdoptionLedger.Declaration]
  }

  struct Report: Encodable {
    let operation = "setup_adopt_packages"
    let outcome: String
    let targets: [String]
    let approvalDigest: String?
    let candidates: [Candidate]
    let message: String
    let boundary = "macarchy_adoption_only_no_homebrew_or_provider_mutation"
  }

  struct Prepared: Encodable, Sendable {
    let candidates: [Candidate]
    let ledger: SetupPackageAdoptionLedger?
    let digest: String

    var additions: [Candidate] {
      let adopted = Set((ledger?.entries ?? []).map(\.identity))
      return candidates.filter { !adopted.contains($0.identity) }
    }
  }

  let planner: UnifiedSetupPlanCommandRunner
  var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

  static let live = Self(planner: .live)

  func execute(
    context: UnifiedSetupPlanContext, targets: [String], approval: String?, json: Bool
  ) async throws -> (output: String, succeeded: Bool) {
    let store = SetupPackageAdoptionStore(
      stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
    var reviewed: Prepared?
    do {
      let identities = try Self.parseTargets(targets)
      let prepared = try prepare(context: context, identities: identities, store: store)
      reviewed = prepared
      if prepared.additions.isEmpty {
        return try result(
          "no_change", targets: targets, prepared: prepared,
          message:
            "Every named installation already matches its adoption record; no state was written.",
          json: json)
      }
      guard let approval else {
        return try result(
          "preview", targets: targets, prepared: prepared,
          message:
            "Review the exact declarations and receipts, then repeat with --approve \(prepared.digest).",
          json: json)
      }
      guard approval == prepared.digest else {
        throw SetupPackageAdoptionError(
          "Approval does not match the current package adoption preview.")
      }
      return try await UnifiedSetupLifecycleLock(stateRoot: context.stateRoot).withLock {
        try checkpoint(.beforeRevalidation)
        let current = try prepare(context: context, identities: identities, store: store)
        guard current.digest == prepared.digest else {
          throw SetupPackageAdoptionError(
            "Package declarations, receipts or adoption state changed before publication.")
        }
        let desired = SetupPackageAdoptionLedger(
          contextDigest: store.contextDigest,
          entries: (current.ledger?.entries ?? [])
            + current.additions.map {
              .init(
                identity: $0.identity, versions: $0.versions, receipts: $0.receipts,
                declarations: $0.declarations, approvalDigest: approval
              )
            }
        )
        try checkpoint(.beforePublication)
        try store.write(desired)
        do {
          try checkpoint(.afterPublication)
          guard try store.read() == desired else {
            throw SetupPackageAdoptionError(
              "Published adoption ledger did not match the approved entries.")
          }
        } catch {
          // Publication is the commit point. Never claim rollback or erase an
          // adoption merely because reporting/verification was interrupted.
          return try result(
            "commit_unverified", targets: targets, prepared: current,
            message:
              "Adoption publication completed, but confirmation failed: \(error). Inspect package status before retrying.",
            json: json)
        }
        return try result(
          "adopted", targets: targets, prepared: current,
          message:
            "Adoption recorded after receipt revalidation. No Homebrew packages or provider configuration changed.",
          json: json)
      }
    } catch {
      return try result(
        "blocked", targets: targets, prepared: reviewed, message: String(describing: error),
        json: json)
    }
  }

  func prepare(
    context: UnifiedSetupPlanContext, identities: [HomebrewPackageIdentity],
    store: SetupPackageAdoptionStore
  ) throws -> Prepared {
    try SetupPendingWork.requireNone(
      .packageAttempt,
      .unifiedTransaction(
        refusal: SetupPackageAdoptionError(
          "Resolve interrupted unified setup before adopting packages.")),
      context: context)
    let ledger = try store.read()
    let inventory = try planner.packageInventory(
      context: context, adoptionState: .available(ledger))
    guard inventory.observation.issues.isEmpty else {
      throw SetupPackageAdoptionError(
        "Package inventory is unavailable: \(inventory.observation.issues.joined(separator: "; "))")
    }
    let candidates = try identities.map { identity in
      guard let declaration = inventory.proposed.first(where: { $0.identity == identity }) else {
        throw SetupPackageAdoptionError(
          "\(identity.key) is not declared by the effective profile and standard baseline.")
      }
      let matches = inventory.observation.packages.filter {
        $0.kind == identity.kind && $0.token == identity.token
      }
      guard matches.count == 1, let installed = matches.first,
        installed.identity == identity, installed.issue == nil, !installed.versions.isEmpty,
        !installed.receipts.isEmpty, installed.receiptPaths == installed.receipts.map(\.path)
      else {
        throw SetupPackageAdoptionError(
          "\(identity.key) has no single, complete matching installation record (\(declaration.homebrewStatus.rawValue))."
        )
      }
      if let prior = ledger?.entries.first(where: { $0.identity == identity }),
        prior.status(in: inventory.observation) != .adopted
      {
        throw SetupPackageAdoptionError(
          "\(identity.key) changed after adoption. This slice does not overwrite prior installation evidence."
        )
      }
      return Candidate(
        identity: identity, versions: installed.versions, receipts: installed.receipts,
        declarations: declaration.declarations)
    }
    struct Binding: Encodable {
      let contract = "setup_package_adoption_v1"
      let contextDigest: String
      let profilePaths: [String]
      let candidates: [Candidate]
      let ledger: SetupPackageAdoptionLedger?
    }
    let digest = try SetupPackageInstallationStore.digest(
      Binding(
        contextDigest: store.contextDigest,
        profilePaths: [context.profileURL, context.machineProfileURL].map(
          \.standardizedFileURL.path),
        candidates: candidates, ledger: ledger
      ))
    return Prepared(candidates: candidates, ledger: ledger, digest: digest)
  }

  /// Parses `formula:<name>` and `cask:<name>` command-line targets into a validated package set.
  static func parseTargets(_ targets: [String]) throws -> [HomebrewPackageIdentity] {
    try HomebrewPackageIdentity.requireTargetCount(targets.count)
    let identities = try targets.map { target in
      let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let kind = HomebrewPackageIdentity.Kind(rawValue: String(parts[0]))
      else {
        throw SetupPackageAdoptionError(
          "Invalid package target '\(target)'; use formula:<name> or cask:<name>.")
      }
      let name = String(parts[1])
      guard HomebrewPackageIdentity.validName(name) else {
        throw SetupPackageAdoptionError("Invalid package name '\(name)'.")
      }
      return HomebrewPackageIdentity(kind: kind, name: name)
    }
    return try HomebrewPackageIdentity.validated(identities)
  }

  private func result(
    _ outcome: String, targets: [String], prepared: Prepared?, message: String, json: Bool
  ) throws -> (output: String, succeeded: Bool) {
    let preview = outcome == "preview"
    let candidates = prepared?.candidates ?? []
    let report = Report(
      outcome: outcome, targets: targets,
      approvalDigest: preview ? prepared?.digest : nil,
      candidates: candidates, message: message
    )
    let output: String
    if json {
      output = try renderJSON(report)
    } else {
      var lines = ["Package adoption [\(outcome)]", message]
      if preview {
        lines.append("Adoption only; no Homebrew packages or provider configuration will change.")
      }
      for candidate in candidates {
        lines.append("- \(candidate.identity.key): \(candidate.versions.joined(separator: ", "))")
        if preview {
          for declaration in candidate.declarations {
            lines.append(
              "  - \(declaration.source): \(declaration.selectionField ?? "package declaration") from \(declaration.layer)"
                + (declaration.sourcePath.map { " (\($0))" } ?? ""))
          }
          for receipt in candidate.receipts {
            lines.append(
              "  - \(receipt.path) [\(receipt.digest); device \(receipt.device); inode \(receipt.inode)]"
            )
          }
        }
      }
      output = lines.joined(separator: "\n")
    }
    return (output, ["preview", "no_change", "adopted"].contains(outcome))
  }
}
