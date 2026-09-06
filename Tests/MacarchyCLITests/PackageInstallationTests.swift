import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageInstallationTests {
  @Test
  func approvalInstallsMissingClosurePublishesOnlyRootAndRepeatsWithoutProviderWork() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let runner = fixture.runner()
    let preview = try await fixture.run(runner)
    #expect(preview.outcome == "preview")
    #expect(preview.json["effects"]?["components"]?.array?.count == 2)
    #expect(preview.json["targets"]?.array?.count == 1)
    #expect(preview.json["targets"]?.array?.first?["identity"]?["name"]?.string == "jq")
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
    let wrong = try await fixture.run(runner, approval: "wrong")
    #expect(wrong.outcome == "blocked")
    #expect(fixture.calls.withLock { $0 } == 0)
    let complete = try await fixture.run(runner, approval: preview.approval())
    #expect(complete.outcome == "complete" && complete.succeeded)
    let ledger = try #require(try fixture.ledger.read())
    #expect(ledger.entries.map(\.identity.name) == ["jq"])
    #expect(try fixture.store.read()?.phase == .complete)
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.context.stateRoot).read() == nil)
    let bytes = try Data(contentsOf: fixture.ledger.url)
    let repeatedRunner = SetupPackageInstallationCommandRunner(
      planner: runner.planner,
      provider: .init(
        prepare: { _ in
          Issue.record("No-op must not resolve effects")
          return fixture.effects
        },
        apply: { _, _, _, _ in
          Issue.record("No-op must not install")
          return .init(status: 1, diagnostic: "")
        }))
    #expect(try await fixture.run(repeatedRunner).outcome == "no_change")
    #expect(try Data(contentsOf: fixture.ledger.url) == bytes)
    #expect(fixture.calls.withLock { $0 } == 1)
  }

  @Test(arguments: ["profile", "receipt", "context", "effects", "last_moment"])
  func staleApprovalsAndLateInputChangesBlockMutation(change: String) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    var context = fixture.context
    switch change {
    case "context":
      context = fixture.contextAt(fixture.inventory.root.appending(path: "other"))
    case "effects":
      var provider = runner.provider
      provider.prepare = { _ in fixture.effect(version: "2") }
      runner = .init(planner: runner.planner, provider: provider)
    case "last_moment":
      var provider = runner.provider
      provider.apply = { _, _, revalidate, _ in
        try fixture.inventory.formula("orphan", version: "2", tap: "homebrew/core")
        try revalidate()
        Issue.record("Late revalidation must reject changed receipts")
        return .init(status: 0, diagnostic: "")
      }
      runner = .init(planner: runner.planner, provider: provider)
    default:
      runner.checkpoint = { point in
        guard case .beforeRevalidation = point else { return }
        if change == "profile" {
          try fixture.inventory.write(
            "schema_version = 1\n[tools]\nbat = false\n", at: fixture.context.profileURL)
        } else {
          try fixture.inventory.formula("orphan", version: "2", tap: "homebrew/core")
        }
      }
    }
    let result = try await runner.execute(
      context: context, targets: ["formula:jq"],
      approval: preview.approval(), json: true)
    #expect(!result.succeeded)
    #expect(fixture.calls.withLock { $0 } == 0)
    #expect(try fixture.ledger.read() == nil)
  }

  @Test(arguments: ["nonzero", "unknown", "verification", "existing_drift"])
  func partialAndUnknownNativeOutcomesNeverPublishOwnership(mode: String) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner(
      status: mode == "nonzero" ? 1 : 0,
      verified: mode == "verification" ? ["jq"] : ["jq", "libfoo"])
    let preview = try await fixture.run(runner)
    if mode == "unknown" || mode == "existing_drift" {
      runner.checkpoint = { point in
        if mode == "unknown", case .afterIntent = point {
          try fixture.install()
          throw SetupPackageAdoptionError("interrupted without native outcome")
        }
        if mode == "existing_drift", case .afterNativeOutcome = point {
          try fixture.inventory.formula("orphan", version: "2", tap: "homebrew/core")
        }
      }
    }
    let result = try await fixture.run(runner, approval: preview.approval())
    #expect(result.outcome == (mode == "unknown" ? "recovery_required" : "partial"))
    #expect(try fixture.ledger.read() == nil)
    if mode == "unknown" {
      let recovered = try await fixture.run(fixture.runner(), recover: true)
      #expect(recovered.outcome == "partial")
      #expect(try fixture.ledger.read() == nil)
      #expect(fixture.calls.withLock { $0 } == 0)
    }
    #expect(try fixture.store.read()?.phase == .partial)
  }

  @Test(arguments: [false, true])
  func recoveryPublishesOnlyPersistedNativeSuccessAndIsIdempotent(afterPublication: Bool)
    async throws
  {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    runner.checkpoint = { point in
      switch (afterPublication, point) {
      case (false, .afterNativeOutcome), (true, .afterPublication):
        throw SetupPackageAdoptionError("interrupted")
      default: break
      }
    }
    #expect(
      try await fixture.run(runner, approval: preview.approval()).outcome == "recovery_required")
    #expect(try fixture.store.read()?.nativeExit == 0)
    #expect(try fixture.store.read()?.phase == .running)
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    let adoption = try await SetupPackageAdoptionCommandRunner(planner: runner.planner).execute(
      context: fixture.context, targets: ["formula:jq"], approval: nil, json: true)
    #expect(!adoption.succeeded)
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "complete")
    #expect(try fixture.ledger.read()?.entries.count == 1)
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "complete")
    #expect(fixture.calls.withLock { $0 } == 1)
  }

  @Test(arguments: ["unknown_field", "context", "ledger_drift"])
  func malformedAttemptAndChangedLedgerCannotBeRecoveredAsSuccess(mode: String) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    runner.checkpoint = { point in
      if case .afterNativeOutcome = point { throw SetupPackageAdoptionError("interrupted") }
    }
    _ = try await fixture.run(runner, approval: preview.approval())
    if mode == "ledger_drift" {
      let installed = try #require(fixture.observation().packages.first { $0.token == "orphan" })
      try fixture.ledger.write(
        .init(
          contextDigest: fixture.ledger.contextDigest,
          entries: [
            .init(
              identity: installed.identity!, versions: installed.versions,
              receipts: installed.receipts,
              declarations: [
                .init(source: "test", layer: "test", sourcePath: nil, selectionField: nil)
              ],
              approvalDigest: preview.approval())
          ]))
    } else {
      var data = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.url)) as? [String: Any])
      data[mode == "context" ? "context_digest" : "unknown"] = "invalid"
      try JSONSerialization.data(withJSONObject: data).write(to: fixture.store.url)
    }
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "blocked")
    #expect(try fixture.ledger.read()?.entries.contains { $0.identity.name == "jq" } != true)
  }

  @Test(arguments: [["cask:slack"], ["formula:vendor/tap/jq"], ["formula:libfoo"]])
  func unsupportedAndUndeclaredTargetsBlockBeforeProvider(targets: [String]) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let result = try await fixture.runner().execute(
      context: fixture.context, targets: targets, approval: nil, json: true)
    #expect(!result.succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test
  func installedUnadoptedAndUnknownEffectsCannotObtainApproval() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let base = fixture.effects
    var runner = fixture.runner()
    var provider = runner.provider
    provider.prepare = { _ in
      .init(
        components: base.components, links: base.links,
        directories: base.directories, footprint: base.footprint,
        dependentIssue: "UntrustedTapError")
    }
    runner = .init(planner: runner.planner, provider: provider)
    let blocked = try await fixture.run(runner)
    #expect(blocked.outcome == "blocked" && blocked.json["approval_digest"] == nil)
    #expect(blocked.json["effects"]?["dependent_issue"]?.string == "UntrustedTapError")
    try fixture.install()
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    #expect(try fixture.ledger.read() == nil)
  }

  @Test
  func pendingProcessBlocksRecoveryApplyAndTeardownAndAppearsInInspection() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    var provider = runner.provider
    provider.apply = { _, _, revalidate, record in
      try revalidate()
      // No process is launched or killed. An existing test process group proves
      // the recovery guard cannot turn active native work into a partial result.
      try record(getpgrp())
      throw SetupPackageAdoptionError("simulated live installer")
    }
    runner = .init(planner: runner.planner, provider: provider)
    #expect(
      try await fixture.run(runner, approval: preview.approval()).outcome == "recovery_required")
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "blocked")
    #expect(try fixture.store.read()?.phase == .running)
    let apply = try await UnifiedSetupApplyCommandRunner.live.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(), installDependencies: true, json: true)
    #expect(!apply.succeeded && apply.output.contains("--recover"))
    let teardown = try await UnifiedSetupTeardownCommandRunner.live.execute(
      context: fixture.context,
      consumerPaths: testConsumerPaths(), dryRun: false, json: true)
    #expect(!teardown.succeeded && teardown.output.contains("--recover"))

    let full = try ApplyFixture()
    defer { full.cleanup() }
    let store = SetupPackageInstallationStore(context: full.context)
    let prior = try #require(try fixture.store.read())
    let pending = SetupPackageInstallationAttempt(
      schemaVersion: 1, contextDigest: store.contextDigest,
      approvalDigest: prior.approvalDigest, priorLedgerDigest: prior.priorLedgerDigest,
      targets: prior.targets, effects: prior.effects, baseline: prior.baseline)
    try store.write(pending)
    let planner = full.planner()
    let plan = try planner.execute(context: full.context, json: true)
    let document = try JSONDecoder().decode(JSONValue.self, from: Data(plan.output.utf8))
    #expect(document["package_inventory"]?["installation"]?["phase"]?.string == "running")
    let inspector = UnifiedSetupInspectionCommandRunner(
      planner: planner,
      themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      desktopInspection: { _, _, _, _ in
        Issue.record("Pending installation should block inspection first")
        return try applyComponent("{}")
      },
      environmentInspection: { _, _, _, _ in
        Issue.record("Pending installation should block inspection first")
        return try applyComponent("{}")
      })
    for operation in [UnifiedSetupInspectionOperation.status, .doctor] {
      let result = try inspector.execute(
        operation: operation, context: full.context,
        consumerPaths: testConsumerPaths(), json: true)
      #expect(!result.succeeded && result.output.contains("recovery_required"))
    }
  }

}

private final class InstallationFixture: Sendable {
  let inventory: InventoryFixture
  let calls = Mutex(0)
  let installed = Mutex(false)

  init() throws {
    inventory = try InventoryFixture()
    try inventory.formula("orphan", tap: "homebrew/core")
  }

  var context: UnifiedSetupPlanContext { contextAt(inventory.root.appending(path: "state")) }
  func contextAt(_ state: URL) -> UnifiedSetupPlanContext {
    let root = inventory.root
    return .init(
      themesRoot: root, keybindingsResourcesRoot: root, desktopResourcesRoot: root,
      environmentResourcesRoot: root, profileURL: root.appending(path: "profile.toml"),
      profileRequired: false,
      machineProfileURL: root.appending(path: "machine.toml"), machineProfileRequired: false,
      stateRoot: state, homeDirectory: root.appending(path: "home"))
  }
  var ledger: SetupPackageAdoptionStore {
    .init(stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
  }
  var store: SetupPackageInstallationStore { .init(context: context) }
  var effects: HomebrewFormulaInstallEffects { effect() }
  func effect(version: String = "1") -> HomebrewFormulaInstallEffects {
    let names = ["jq", "libfoo"]
    let links = names.map {
      HomebrewFormulaInstallEffects.Link(
        path: "/opt/homebrew/opt/\($0)", target: "/opt/homebrew/Cellar/\($0)/\(version)")
    }
    return .init(
      components: names.map {
        .init(
          name: $0, version: version, sha256: String(repeating: "a", count: 64),
          dependencies: $0 == "jq" ? ["libfoo"] : [])
      },
      links: links, directories: [],
      footprint: links.map { .init(path: $0.path, device: nil, inode: nil, mode: nil) },
      dependentIssue: nil)
  }
  func install() throws {
    for name in ["jq", "libfoo"] { try inventory.formula(name, tap: "homebrew/core") }
    installed.withLock { $0 = true }
  }
  func observation() -> HomebrewPackageObservation {
    inventory.reader(formulae: installed.withLock { $0 } ? "jq\nlibfoo\norphan" : "orphan").read()
  }
  func runner(status: Int32 = 0, verified: [String] = ["jq", "libfoo"])
    -> SetupPackageInstallationCommandRunner
  {
    let unrelated: UnifiedSetupPlanCommandRunner.ComponentPlanner = { _, _ in
      Issue.record("Package installation must not plan unrelated providers")
      throw SetupPackageAdoptionError("unrelated provider planning")
    }
    return .init(
      planner: .init(
        capabilityIsAvailable: { _ in false },
        desktopPlanner: unrelated, environmentPlanner: unrelated,
        packageInventoryReader: { self.observation() }),
      provider: .init(
        prepare: { _ in self.effects },
        apply: { _, _, revalidate, _ in
          try revalidate()
          self.calls.withLock { $0 += 1 }
          try self.install()
          return .init(status: status, diagnostic: "test native outcome")
        }, verify: { _, _ in verified }))
  }
  struct Result {
    let json: JSONValue
    let succeeded: Bool
    var outcome: String? { json["outcome"]?.string }
    func approval() throws -> String { try #require(json["approval_digest"]?.string) }
  }
  func run(
    _ runner: SetupPackageInstallationCommandRunner, approval: String? = nil, recover: Bool = false
  ) async throws -> Result {
    let result = try await runner.execute(
      context: context, targets: recover ? [] : ["formula:jq"],
      approval: approval, recover: recover, json: true)
    return try .init(
      json: JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8)),
      succeeded: result.succeeded)
  }
}
