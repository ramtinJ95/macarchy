import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageAdoptionTests {
  @Test
  func previewApprovalAndRepeatCrossTheSameInertInventoryWithoutFullSetup() async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    let runner = fixture.runner()
    let preview = try await fixture.run(runner)
    #expect(preview.succeeded && preview.outcome == "preview")
    let digest = try #require(preview.digest)
    #expect(preview.document["candidates"]?.array?.count == 1)
    #expect(preview.document["candidates"]?.array?.first?["identity"]?["name"]?.string == "jq")
    #expect(preview.document["candidates"]?.array?.first?["receipts"]?.array?.count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))

    let wrong = try await fixture.run(runner, approval: "sha256:wrong")
    #expect(!wrong.succeeded && wrong.outcome == "blocked")
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
    let applied = try await fixture.run(runner, approval: digest)
    #expect(applied.succeeded && applied.outcome == "adopted")
    let ledger = try #require(try fixture.store.read())
    #expect(ledger.entries.map(\.identity.key) == ["formula:jq"])
    #expect(ledger.entries[0].declarations.map(\.source) == ["standard_baseline"])
    #expect(ledger.entries[0].approvalDigest == digest)
    let data = try Data(contentsOf: fixture.store.url)
    let repeated = try await fixture.run(runner, approval: digest)
    #expect(repeated.succeeded && repeated.outcome == "no_change")
    #expect(try Data(contentsOf: fixture.store.url) == data)
    #expect(!FileManager.default.fileExists(atPath: fixture.context.profileURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.context.homeDirectory.path))
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.context.stateRoot).read() == nil)
    let inventory = try fixture.status(runner)
    #expect(inventory.proposed.first { $0.identity.name == "jq" }?.adoption == "adopted")
    #expect(inventory.proposed.first { $0.identity.name == "bat" }?.adoption == "unadopted")
    #expect(inventory.outsideProposedRequirements.map(\.token) == ["orphan"])
  }

  @Test(arguments: [
    [], ["jq"], ["formula:jq", "formula:homebrew/core/jq"], ["formula:../jq"],
    ["formula:orphan"], ["formula:azure-cli"], ["formula:asmvik/formulae/yabai"], ["formula:bat"],
  ])
  func missingAmbiguousUndeclaredAndMalformedTargetsCannotGrantOwnership(targets: [String])
    async throws
  {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    try fixture.inventory.formula("yabai", tap: "koekeishiya/formulae")
    try fixture.inventory.formula("bat", version: "2", tap: "vendor/tap")
    let result = try await fixture.run(
      fixture.runner(formulae: "bat\njq\norphan\nyabai"), targets: targets)
    #expect(!result.succeeded && result.outcome == "blocked")
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test
  func approvalsBindReceiptsStateRootAndTheExistingLedger() async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    let runner = fixture.runner()
    let jq = try await fixture.run(runner)
    let bat = try await fixture.run(runner, targets: ["formula:bat"])
    let digest = try #require(jq.digest)
    var otherState = fixture
    otherState.stateRoot = fixture.inventory.root.appending(path: "other-state")
    let crossContext = try await otherState.run(runner, approval: digest)
    #expect(!crossContext.succeeded)
    #expect(!FileManager.default.fileExists(atPath: otherState.stateRoot.path))

    // Same bytes, new receipt inode: a reinstallation-shaped change is not the
    // installation the user approved.
    let receipt = fixture.inventory.root.appending(path: "Cellar/jq/1/INSTALL_RECEIPT.json")
    let data = try Data(contentsOf: receipt)
    try data.write(to: receipt, options: .atomic)
    #expect(!(try await fixture.run(runner, approval: digest)).succeeded)
    let refreshed = try await fixture.run(runner)
    #expect((try await fixture.run(runner, approval: refreshed.approval())).succeeded)
    #expect(
      !(try await fixture.run(runner, targets: ["formula:bat"], approval: bat.approval())).succeeded
    )
    #expect(try fixture.store.read()?.entries.map(\.identity.name) == ["jq"])
  }

  @Test(arguments: ["receipt", "declaration"])
  func revalidationUnderTheSetupLockRejectsChangesAfterInitialApproval(change: String) async throws
  {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:bat"])
    runner.checkpoint = { checkpoint in
      guard case .beforeRevalidation = checkpoint else { return }
      if change == "receipt" {
        try fixture.inventory.formula("bat", version: "2", tap: "homebrew/core")
      } else {
        try fixture.inventory.write(
          "schema_version = 1\n[tools]\nbat = false\n", at: fixture.context.profileURL)
      }
    }
    let result = try await fixture.run(
      runner, targets: ["formula:bat"], approval: preview.approval())
    #expect(!result.succeeded && result.outcome == "blocked")
    #expect(try fixture.store.read() == nil)
  }

  @Test(arguments: [false, true])
  func interruptionHasOneAtomicLedgerCommitPoint(afterPublication: Bool) async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    runner.checkpoint = { checkpoint in
      switch (afterPublication, checkpoint) {
      case (false, .beforePublication), (true, .afterPublication):
        throw SetupPackageAdoptionError("injected interruption")
      default: break
      }
    }
    let result = try await fixture.run(runner, approval: preview.approval())
    #expect(!result.succeeded)
    #expect(result.outcome == (afterPublication ? "commit_unverified" : "blocked"))
    #expect((try fixture.store.read() != nil) == afterPublication)
    let retry = try await fixture.run(fixture.runner())
    #expect(retry.outcome == (afterPublication ? "no_change" : "preview"))
    if afterPublication {
      #expect(
        try fixture.status(runner).proposed.first { $0.identity.name == "jq" }?.adoption
          == "adopted")
    }
  }

  @Test
  func statusRetainsMissingChangedAndNoLongerDeclaredAdoptions() async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    let runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:bat", "formula:jq"])
    #expect(
      (try await fixture.run(
        runner, targets: ["formula:bat", "formula:jq"], approval: preview.approval())).succeeded)
    let ledgerBytes = try Data(contentsOf: fixture.store.url)
    let missing = try fixture.status(fixture.runner(formulae: "bat\norphan"))
    #expect(missing.proposed.first { $0.identity.name == "jq" }?.adoption == "missing")
    try fixture.inventory.formula("jq", version: "2", tap: "homebrew/core")
    let changed = try fixture.status(runner)
    #expect(changed.proposed.first { $0.identity.name == "jq" }?.adoption == "changed")
    #expect(!(try await fixture.run(runner)).succeeded)
    try fixture.inventory.write(
      "schema_version = 1\n[tools]\nbat = false\n", at: fixture.context.profileURL)
    let undeclared = try fixture.status(runner)
    #expect(!undeclared.proposed.contains { $0.identity.name == "bat" })
    #expect(undeclared.retainedAdoptionsOutsideProposed.map(\.entry.identity.name) == ["bat"])
    #expect(undeclared.retainedAdoptionsOutsideProposed.first?.status == "adopted")
    #expect(try Data(contentsOf: fixture.store.url) == ledgerBytes)
  }

  @Test
  func invalidLedgerAndUnavailableInventoryRemainExplicit() async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    let runner = fixture.runner()
    let preview = try await fixture.run(runner)
    #expect((try await fixture.run(runner, approval: preview.approval())).succeeded)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.url)) as? [String: Any])
    object["future_authority"] = true
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.store.url)
    let invalid = try fixture.status(runner)
    #expect(invalid.adoptionIssue != nil)
    #expect(invalid.proposed.allSatisfy { $0.adoption == "unknown" })
    #expect(!(try await fixture.run(runner)).succeeded)

    let absent = try AdoptionFixture()
    defer { absent.cleanup() }
    var planner = absent.runner().planner
    planner.packageInventoryReader = { .unavailable("test inventory failure") }
    let unavailable = SetupPackageAdoptionCommandRunner(planner: planner)
    #expect(!(try await absent.run(unavailable)).succeeded)
    #expect(try absent.store.read() == nil)
  }

  @Test
  func casksAndMultipleKegsRetainTheirCompleteEvidence() async throws {
    let fixture = try AdoptionFixture()
    defer { fixture.cleanup() }
    try fixture.inventory.formula("jq", version: "2", tap: "homebrew/core")
    try fixture.inventory.cask("slack", tap: "homebrew/cask")
    var planner = fixture.runner().planner
    let reader = fixture.inventory.reader(formulae: "jq", casks: "slack")
    planner.packageInventoryReader = { reader.read() }
    let runner = SetupPackageAdoptionCommandRunner(planner: planner)
    let targets = ["formula:jq", "cask:slack"]
    let preview = try await fixture.run(runner, targets: targets)
    #expect(
      (try await fixture.run(runner, targets: targets, approval: preview.approval())).succeeded)
    let entries = try #require(try fixture.store.read()).entries
    #expect(entries.map(\.identity.key) == ["cask:slack", "formula:jq"])
    #expect(entries[0].versions == ["1"] && entries[0].receipts.count == 1)
    #expect(entries[1].versions == ["1", "2"] && entries[1].receipts.count == 2)
    #expect((try await fixture.run(runner, targets: targets)).outcome == "no_change")
  }
}

private struct AdoptionFixture {
  let inventory: InventoryFixture
  var stateRoot: URL

  init() throws {
    inventory = try InventoryFixture()
    stateRoot = inventory.root.appending(path: "state")
    for token in ["bat", "jq", "orphan"] {
      try inventory.formula(token, tap: "homebrew/core")
    }
  }

  var context: UnifiedSetupPlanContext {
    let root = inventory.root
    return UnifiedSetupPlanContext(
      themesRoot: root.appending(path: "no-themes"),
      keybindingsResourcesRoot: root.appending(path: "no-keybindings"),
      desktopResourcesRoot: root.appending(path: "no-desktop"),
      environmentResourcesRoot: root.appending(path: "no-environment"),
      profileURL: root.appending(path: "profile.toml"), profileRequired: false,
      machineProfileURL: root.appending(path: "machine.toml"), machineProfileRequired: false,
      stateRoot: stateRoot, homeDirectory: root.appending(path: "home")
    )
  }

  var store: SetupPackageAdoptionStore {
    .init(stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
  }

  func cleanup() { inventory.cleanup() }

  func runner(formulae: String = "bat\njq\norphan") -> SetupPackageAdoptionCommandRunner {
    let reader = inventory.reader(formulae: formulae)
    let unrelated: UnifiedSetupPlanCommandRunner.ComponentPlanner = { _, _ in
      Issue.record("Package adoption must not invoke unrelated provider planning")
      throw SetupPackageAdoptionError("unrelated setup invoked")
    }
    return .init(
      planner: UnifiedSetupPlanCommandRunner(
        capabilityIsAvailable: { _ in false }, desktopPlanner: unrelated,
        environmentPlanner: unrelated, packageInventoryReader: { reader.read() }
      ))
  }

  func status(_ runner: SetupPackageAdoptionCommandRunner) throws -> SetupPackageInventory {
    try runner.planner.packageInventory(context: context, adoptionState: store.inspect())
  }

  struct Execution {
    let document: JSONValue
    let succeeded: Bool
    var outcome: String? { document["outcome"]?.string }
    var digest: String? { document["approval_digest"]?.string }
    func approval() throws -> String { try #require(digest) }
  }

  func run(
    _ runner: SetupPackageAdoptionCommandRunner, targets: [String] = ["formula:jq"],
    approval: String? = nil
  ) async throws -> Execution {
    let result = try await runner.execute(
      context: context, targets: targets, approval: approval, json: true)
    return try Execution(
      document: JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8)),
      succeeded: result.succeeded)
  }
}
