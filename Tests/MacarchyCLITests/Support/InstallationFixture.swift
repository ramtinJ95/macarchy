import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

final class InstallationFixture: Sendable {
  let inventory: InventoryFixture
  let calls = Mutex(0)
  let installed = Mutex(false)
  let target: HomebrewPackageIdentity
  var declaration: String {
    "\(target.kind == .formula ? "brew" : "cask") \"\(target.name)\"\n"
  }
  var brewfile: String {
    (target.name.contains("/") ? "tap \"vendor/tools\"\n" : "") + declaration
  }

  init(kind: HomebrewPackageIdentity.Kind = .formula, thirdParty: Bool = false) throws {
    target = .init(
      kind: kind, name: (thirdParty ? "vendor/tools/" : "") + (kind == .formula ? "jq" : "slack"))
    inventory = try InventoryFixture()
    try inventory.formula("orphan", tap: "homebrew/core")
    try inventory.write(
      thirdParty
        ? "schema_version = 1\n[packages]\nbaseline = 'personal'\nbrewfile = 'Brewfile'\n"
        : "schema_version = 1\n[packages]\nbaseline = 'standard'\n", at: context.profileURL)
    if thirdParty {
      try inventory.write(
        "tap \"unrelated/tap\"\n" + declaration, at: inventory.root.appending(path: "Brewfile"))
    }
  }

  var context: UnifiedSetupPlanContext {
    let root = inventory.root
    return .init(
      themesRoot: root, keybindingsResourcesRoot: root,
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
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
      try inventory.formula(target.token, tap: target.tap ?? "homebrew/core")
    } else {
      try inventory.cask(target.token, tap: target.tap ?? "homebrew/cask")
    }
    try inventory.formula("libfoo", tap: "homebrew/core")
    installed.withLock { $0 = true }
  }
  func observation() -> HomebrewPackageObservation {
    let present = installed.withLock { $0 }
    return inventory.reader(
      formulae: present
        ? (target.kind == .formula ? "\(target.token)\nlibfoo\norphan" : "libfoo\norphan")
        : "orphan",
      casks: present && target.kind == .cask ? target.token : ""
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
        desktopPlanner: unrelated,
        environmentPlanner: { context, profile, _ in try unrelated(context, profile) },
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
