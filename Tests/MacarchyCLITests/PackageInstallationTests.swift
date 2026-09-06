import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageInstallationTests {
  @Test(arguments: HomebrewPackageIdentity.Kind.allCases)
  func approvalBindsBrewfilePublishesOnlyNamedRootsAndRepeatDoesNothing(
    kind: HomebrewPackageIdentity.Kind
  ) async throws {
    let fixture = try InstallationFixture(kind: kind)
    defer { fixture.inventory.cleanup() }
    try fixture.inventory.write("schema_version = 1\n", at: fixture.context.profileURL)
    let personal = try Data(contentsOf: fixture.context.profileURL)
    let runner = fixture.runner()
    let preview = try await fixture.run(runner)
    #expect(preview.outcome == "preview")
    #expect(preview.json["brewfile"]?.string == fixture.brewfile)
    #expect(
      preview.json["native_effects"]?.array?.compactMap(\.string)
        == (kind == .cask ? [HomebrewBundleInstaller.caskEffects] : []))
    #expect(preview.json["effects"] == nil)
    #expect(
      preview.json["command"]?.array?.compactMap(\.string) == [
        "/opt/homebrew/bin/brew", "bundle", "install", "--no-upgrade", "--file",
        fixture.store.brewfileURL.path,
      ])
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
    #expect(try await fixture.run(runner, approval: "wrong").outcome == "blocked")
    #expect(fixture.calls.withLock { $0 } == 0)
    let complete = try await fixture.run(runner, approval: preview.approval())
    #expect(complete.outcome == "complete" && complete.succeeded)
    #expect(try fixture.ledger.read()?.entries.map(\.identity) == [fixture.target])
    #expect(try fixture.store.read()?.verifiedTargets == [fixture.target.key])
    #expect(try String(contentsOf: fixture.store.brewfileURL, encoding: .utf8) == fixture.brewfile)
    #expect(try Data(contentsOf: fixture.context.profileURL) == personal)
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.context.stateRoot).read() == nil)
    let bytes = try Data(contentsOf: fixture.ledger.url)
    #expect(try await fixture.run(runner).outcome == "no_change")
    #expect(try Data(contentsOf: fixture.ledger.url) == bytes)
    #expect(fixture.calls.withLock { $0 } == 1)
  }

  @Test
  func nativeRelatedPackageChangesAndUnrelatedReceiptGapsAreDelegated() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let base = fixture.runner()
    var planner = base.planner
    planner.packageInventoryReader = {
      let current = fixture.observation()
      return .init(
        packages: current.packages + [
          .init(
            kind: .cask, token: "zoom", identity: nil, versions: [],
            receiptPaths: [], issue: "Opaque native receipt"),
          .init(
            kind: .formula, token: "opaque", identity: nil, versions: [],
            receiptPaths: [], issue: "Opaque native receipt"),
        ], issues: [])
    }
    var runner = SetupPackageInstallationCommandRunner(planner: planner, provider: base.provider)
    let preview = try await fixture.run(runner)
    #expect(preview.outcome == "preview")
    #expect(preview.json["inventory_warnings"]?.array?.count == 2)
    runner.checkpoint = { point in
      if case .afterNativeOutcome = point {
        try fixture.inventory.formula("orphan", version: "2", tap: "homebrew/core")
      }
    }
    #expect(try await fixture.run(runner, approval: preview.approval()).outcome == "complete")
    #expect(try fixture.ledger.read()?.entries.map(\.identity.name) == ["jq"])
    #expect(fixture.observation().packages.contains { $0.token == "libfoo" })
  }

  @Test(
    arguments: ["profile", "target", "defaults", "late"], HomebrewPackageIdentity.Kind.allCases)
  func staleApprovalStopsBeforeNativeExecution(change: String, kind: HomebrewPackageIdentity.Kind)
    async throws
  {
    let fixture = try InstallationFixture(kind: kind)
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    if change == "defaults" {
      var planner = runner.planner
      planner.standardBrewfile = { _ in SetupBrewfile(packages: []) }
      runner = .init(planner: planner, provider: runner.provider)
    } else {
      runner.checkpoint = { point in
        let reached: Bool
        switch (change, point) {
        case ("late", .afterIntent), ("profile", .beforeRevalidation),
          ("target", .beforeRevalidation):
          reached = true
        default: reached = false
        }
        guard reached else { return }
        if change == "target" {
          try fixture.install()
        } else {
          try fixture.inventory.write("schema_version = 999\n", at: fixture.context.profileURL)
        }
      }
    }
    let result = try await fixture.run(runner, approval: preview.approval())
    #expect(!result.succeeded)
    #expect(fixture.calls.withLock { $0 } == 0)
    #expect(try fixture.ledger.read() == nil)
  }

  @Test(arguments: ["nonzero", "unknown", "missing"], HomebrewPackageIdentity.Kind.allCases)
  func partialNativeOutcomesNeverPublishOwnership(mode: String, kind: HomebrewPackageIdentity.Kind)
    async throws
  {
    let fixture = try InstallationFixture(kind: kind)
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner(status: mode == "nonzero" ? 1 : 0, install: mode != "missing")
    let preview = try await fixture.run(runner)
    if mode == "unknown" {
      runner.checkpoint = { point in
        if case .afterIntent = point {
          try fixture.install()
          throw SetupPackageAdoptionError("interrupted without a durable native outcome")
        }
      }
    }
    let result = try await fixture.run(runner, approval: preview.approval())
    #expect(result.outcome == (mode == "unknown" ? "recovery_required" : "partial"))
    if mode == "unknown" {
      #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "partial")
      #expect(fixture.calls.withLock { $0 } == 0)
    }
    #expect(try fixture.ledger.read() == nil)
    #expect(try fixture.store.read()?.phase == .partial)
  }

  @Test(arguments: [false, true], HomebrewPackageIdentity.Kind.allCases)
  func recoveryRequiresPersistedNativeSuccessAndDoesNotRerun(
    afterPublication: Bool, kind: HomebrewPackageIdentity.Kind
  ) async throws {
    let fixture = try InstallationFixture(kind: kind)
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
    #expect(throws: SetupPackageAdoptionError.self) { try fixture.store.requireResolved() }
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "complete")
    #expect(try await fixture.run(fixture.runner(), recover: true).outcome == "complete")
    #expect(try fixture.ledger.read()?.entries.count == 1)
    #expect(fixture.calls.withLock { $0 } == 1)
  }

  @Test(arguments: [1, 2, 4])
  func incompatibleAttemptIsPreservedAndNeverReplayed(version: Int) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let bytes = "{\"schema_version\":\(version)}"
    try fixture.inventory.write(bytes, at: fixture.store.url)
    let result = try await fixture.run(fixture.runner(), recover: true)
    #expect(result.outcome == "blocked")
    #expect(result.json["message"]?.string?.contains("cannot be replayed") == true)
    #expect(try String(contentsOf: fixture.store.url, encoding: .utf8) == bytes)
    #expect(fixture.calls.withLock { $0 } == 0)
    #expect(try fixture.ledger.read() == nil)
  }

  @Test
  func activeSessionBlocksRecoveryWithoutKillingOrRerunning() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    // A CI runner may inherit launchd's session 1. Own a real disposable
    // session instead of treating the surrounding terminal as an installer.
    var attributes: posix_spawnattr_t?
    try #require(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0)
    let executable = try #require(strdup("/bin/sleep"))
    defer { free(executable) }
    let duration = try #require(strdup("30"))
    defer { free(duration) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
    var pid: pid_t = 0
    try #require(posix_spawn(&pid, executable, nil, &attributes, &arguments, environ) == 0)
    let session = pid
    defer {
      _ = kill(session, SIGKILL)
      var status: Int32 = 0
      while waitpid(session, &status, 0) == -1, errno == EINTR {}
    }
    try #require(getsid(session) == session)
    let base = fixture.runner()
    let runner = SetupPackageInstallationCommandRunner(
      planner: base.planner,
      provider: .init(
        apply: { _, record in
          try record(session)
          throw SetupPackageAdoptionError("simulated live installer")
        }))
    let preview = try await fixture.run(runner)
    #expect(
      try await fixture.run(runner, approval: preview.approval()).outcome == "recovery_required")
    #expect(try await fixture.run(base, recover: true).outcome == "blocked")
    #expect(try fixture.store.read()?.phase == .running)
    #expect(try HomebrewPackageInstallProcess.sessionExists(session))
    #expect(fixture.calls.withLock { $0 } == 0)
  }

  @Test(arguments: [
    ["cask:undeclared"], ["cask:vendor/apps/slack"], ["formula:vendor/tap/jq"], ["formula:libfoo"],
  ])
  func unsupportedOrUndeclaredTargetsBlock(targets: [String]) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let result = try await fixture.runner().execute(
      context: fixture.context, targets: targets, approval: nil, json: true)
    #expect(!result.succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test(arguments: HomebrewPackageIdentity.Kind.allCases)
  func installedUnadoptedTargetRequiresSeparateAdoption(kind: HomebrewPackageIdentity.Kind)
    async throws
  {
    let fixture = try InstallationFixture(kind: kind)
    defer { fixture.inventory.cleanup() }
    try fixture.install()
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    #expect(fixture.calls.withLock { $0 } == 0)
    #expect(try fixture.ledger.read() == nil)
  }

  @Test
  func mixedKindsWithSameTokenKeepSeparateReceiptAuthority() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.inventory.cleanup() }
    let cask = HomebrewPackageIdentity(kind: .cask, name: "jq")
    let targets = [cask, fixture.target]
    var planner = fixture.runner().planner
    planner.standardBrewfile = { _ in SetupBrewfile(packages: targets) }
    planner.packageInventoryReader = {
      fixture.inventory.reader(
        formulae: fixture.installed.withLock { $0 } ? "jq\nlibfoo\norphan" : "orphan",
        casks: fixture.installed.withLock { $0 } ? "jq" : ""
      ).read()
    }
    let runner = SetupPackageInstallationCommandRunner(
      planner: planner,
      provider: .init(apply: { url, _ in
        #expect(
          try String(contentsOf: url, encoding: .utf8) == "cask \"jq\"\nbrew \"jq\"\n")
        fixture.calls.withLock { $0 += 1 }
        try fixture.inventory.cask("jq", tap: "homebrew/cask")
        try fixture.install()
        return .init(status: 0, diagnostic: "mixed installation")
      }))
    let preview = try await fixture.run(runner, targets: ["formula:jq", "cask:homebrew/cask/jq"])
    #expect(preview.outcome == "preview")
    let complete = try await fixture.run(
      runner, approval: preview.approval(), targets: targets.map(\.key))
    #expect(complete.outcome == "complete", "\(complete.json)")
    #expect(try fixture.store.read()?.verifiedTargets == ["cask:jq", "formula:jq"])
    #expect(try Set(fixture.ledger.read()?.entries.map(\.identity) ?? []) == Set(targets))
    #expect(try await fixture.run(runner, targets: targets.map(\.key)).outcome == "no_change")
    #expect(fixture.calls.withLock { $0 } == 1)
  }

  @Test(arguments: ["wrong-tap", "missing-receipt"])
  func nativeCaskSuccessRequiresExactReceiptIdentity(mode: String) async throws {
    let fixture = try InstallationFixture(kind: .cask)
    defer { fixture.inventory.cleanup() }
    var runner = fixture.runner()
    runner.checkpoint = { point in
      if case .afterNativeOutcome = point {
        if mode == "wrong-tap" {
          try fixture.inventory.cask("slack", tap: "vendor/apps")
        } else {
          try FileManager.default.removeItem(
            at: fixture.inventory.root.appending(
              path: "Caskroom/slack/.metadata/INSTALL_RECEIPT.json"))
        }
      }
    }
    let preview = try await fixture.run(runner)
    #expect(try await fixture.run(runner, approval: preview.approval()).outcome == "partial")
    #expect(try fixture.ledger.read() == nil)
    #expect(try await fixture.run(runner, recover: true).outcome == "partial")
    #expect(fixture.calls.withLock { $0 } == 1)
  }
}

final class InstallationFixture: Sendable {
  let inventory: InventoryFixture
  let calls = Mutex(0)
  let installed = Mutex(false)
  let target: HomebrewPackageIdentity
  var brewfile: String { target.kind == .formula ? "brew \"jq\"\n" : "cask \"slack\"\n" }

  init(kind: HomebrewPackageIdentity.Kind = .formula) throws {
    target = .init(kind: kind, name: kind == .formula ? "jq" : "slack")
    inventory = try InventoryFixture()
    try inventory.formula("orphan", tap: "homebrew/core")
  }

  var context: UnifiedSetupPlanContext {
    let root = inventory.root
    return .init(
      themesRoot: root, keybindingsResourcesRoot: root, desktopResourcesRoot: root,
      environmentResourcesRoot: root, profileURL: root.appending(path: "profile.toml"),
      profileRequired: false,
      machineProfileURL: root.appending(path: "machine.toml"), machineProfileRequired: false,
      stateRoot: root.appending(path: "state"), homeDirectory: root.appending(path: "home"))
  }
  var ledger: SetupPackageAdoptionStore {
    .init(stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
  }
  var store: SetupPackageInstallationStore { .init(context: context) }
  func install() throws {
    if target.kind == .formula {
      try inventory.formula(target.name, tap: "homebrew/core")
    } else {
      try inventory.cask(target.name, tap: "homebrew/cask")
    }
    try inventory.formula("libfoo", tap: "homebrew/core")
    installed.withLock { $0 = true }
  }
  func observation() -> HomebrewPackageObservation {
    let present = installed.withLock { $0 }
    return inventory.reader(
      formulae: present
        ? (target.kind == .formula ? "\(target.name)\nlibfoo\norphan" : "libfoo\norphan")
        : "orphan",
      casks: present && target.kind == .cask ? target.name : ""
    ).read()
  }
  func runner(status: Int32 = 0, install: Bool = true) -> SetupPackageInstallationCommandRunner {
    let unrelated: UnifiedSetupPlanCommandRunner.ComponentPlanner = { _, _ in
      Issue.record("Package installation must not plan unrelated providers")
      throw SetupPackageAdoptionError("unrelated provider planning")
    }
    return .init(
      planner: .init(
        capabilityIsAvailable: { _ in false },
        desktopPlanner: unrelated, environmentPlanner: unrelated,
        packageInventoryReader: { self.observation() },
        standardBrewfile: { _ in
          try SetupBrewfile.read(at: repositoryRoot.appending(path: "Environment/Brewfile"))
        }),
      provider: .init(apply: { brewfile, _ in
        #expect(try String(contentsOf: brewfile, encoding: .utf8) == self.brewfile)
        self.calls.withLock { $0 += 1 }
        if install { try self.install() }
        return .init(status: status, diagnostic: "test native outcome")
      }))
  }
  struct Result {
    let json: JSONValue
    let succeeded: Bool
    var outcome: String? { json["outcome"]?.string }
    func approval() throws -> String { try #require(json["approval_digest"]?.string) }
  }
  func run(
    _ runner: SetupPackageInstallationCommandRunner, approval: String? = nil, recover: Bool = false,
    targets: [String]? = nil
  ) async throws -> Result {
    let result = try await runner.execute(
      context: context, targets: recover ? [] : targets ?? [target.key],
      approval: approval, recover: recover, json: true)
    return try .init(
      json: JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8)),
      succeeded: result.succeeded)
  }
}
