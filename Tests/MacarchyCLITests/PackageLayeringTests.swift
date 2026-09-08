import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageLayeringTests {
  @Test(arguments: [false, true])
  func machineChangesOnlyItsNamedPackages(emptyMachineExclusions: Bool) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(
      portable: """
        [packages]
        brewfile = "Brewfile"
        exclude_formulae = ["jq"]
        exclude_casks = ["spotify"]
        """,
      machine: """
        [packages]
        brewfile = "Brewfile"
        exclude_casks = \(emptyMachineExclusions ? "[]" : "[\"docker\"]")
        """)
    try fixture.write("brew \"hello\"\n", layer: "portable")
    try fixture.write("brew \"jq\"\n", layer: "machine")
    let runner = fixture.planner()
    let report = try runner.packageInventory(
      context: fixture.context, adoptionState: .available(nil))
    let names = Set(report.proposed.map(\.identity.key))
    #expect(
      names.contains("formula:hello") && names.contains("formula:jq")
        && names.contains("formula:git"))
    #expect(!names.contains("cask:spotify"))
    #expect(names.contains("cask:docker") == emptyMachineExclusions)
    #expect(report.exclusions.first { $0.identity.name == "spotify" }?.source.layer == "portable")
    #expect(
      report.proposed.first { $0.identity.name == "hello" }?.personalDeclarations.first?.layer
        == "portable")
    #expect(
      report.proposed.first { $0.identity.name == "jq" }?.personalDeclarations.first?.layer
        == "machine")
    #expect(report.proposed.first { $0.identity.name == "jq" }?.standardDeclaration == nil)
    #expect(
      try SetupBrewfile.parse(report.effectiveBrewfile).packages == report.proposed.map(\.identity))
    #expect(
      try renderJSON(
        runner.packageInventory(context: fixture.context, adoptionState: .available(nil)))
        == renderJSON(report))
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test(arguments: [false, true])
  func personalBaselineKeepsProviderRequirementsWithoutLoadingStock(emptyFragment: Bool) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(portable: "[packages]\nbaseline = \"personal\"\nbrewfile = \"Brewfile\"\n")
    try fixture.write(
      emptyFragment ? "" : "brew \"hello\"\ntap \"vendor/tools\"\n", layer: "portable")
    var planner = fixture.planner()
    planner.standardBrewfile = { _ in
      Issue.record("Personal mode must not consult stock defaults")
      throw SetupPackageAdoptionError("unavailable stock")
    }
    let report = try planner.packageInventory(
      context: fixture.context, adoptionState: .available(nil))
    #expect(report.baseline == .personal)
    #expect(report.proposed.contains { $0.identity.key == "formula:hello" } == !emptyFragment)
    #expect(
      report.proposed.contains { $0.identity.key == "formula:bat" && !$0.requirements.isEmpty })
    #expect(
      !report.proposed.contains { ["jq", "git", "spotify", "docker"].contains($0.identity.name) })
    #expect(report.proposed.allSatisfy { $0.standardDeclaration == nil })
    #expect(report.taps.map(\.name) == (emptyFragment ? [] : ["vendor/tools"]))
    #expect(report.effectiveBrewfile.contains("tap \"vendor/tools\"") == !emptyFragment)
  }

  @Test
  func effectiveBoundIncludesProviderRequirements() throws {
    let names = (0..<1024).map { HomebrewPackageIdentity(kind: .formula, name: "tool-\($0)") }
    let requirement = SetupCapability(
      id: "bat", category: .requiredAdapter, status: .present,
      requirement: "bat", remediation: .formula("bat"))
    _ = try SetupPackageDeclarations.compile(
      standard: SetupBrewfile(packages: Array(names.dropLast())), profile: .defaults,
      requirements: [requirement])
    #expect(throws: SetupPackageAdoptionError.self) {
      try SetupPackageDeclarations.compile(
        standard: SetupBrewfile(packages: names), profile: .defaults, requirements: [requirement])
    }
  }

  @Test(arguments: ["contradiction", "ruby", "missing", "no_manifest", "duplicate_exclusion"])
  func invalidLowerInputCannotBeHiddenByMachineIntent(mode: String) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    let portable: String
    switch mode {
    case "no_manifest": portable = "[packages]\nbaseline = \"personal\"\n"
    case "duplicate_exclusion":
      portable = "[packages]\nexclude_formulae = [\"jq\", \"homebrew/core/jq\"]\n"
    default:
      portable =
        "[packages]\nbrewfile = \"Brewfile\"\n"
        + (mode == "contradiction" ? "exclude_formulae = [\"hello\"]\n" : "")
    }
    try fixture.profiles(
      portable: portable, machine: "[packages]\nexclude_formulae = [\"hello\"]\n")
    if mode != "missing" {
      try fixture.write(
        mode == "ruby"
          ? "system 'touch \(fixture.inventory.root.path)/executed'\n" : "brew \"hello\"\n",
        layer: "portable")
    }
    #expect(throws: SetupPackageAdoptionError.self) {
      try fixture.planner().packageInventory(
        context: fixture.context, adoptionState: .available(nil))
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.inventory.root.appending(path: "executed").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
  }

  @Test(arguments: [false, true])
  func requirementsAreCheckedAfterPerPackageOverlay(machineRestoresBat: Bool) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(
      portable: "[packages]\nexclude_formulae = [\"bat\", \"not-in-stock\"]\n",
      machine: machineRestoresBat ? "[packages]\nbrewfile = \"Brewfile\"\n" : "")
    if machineRestoresBat {
      try fixture.write("brew \"bat\"\n", layer: "machine")
      let report = try fixture.planner().packageInventory(
        context: fixture.context, adoptionState: .available(nil))
      #expect(report.proposed.contains { $0.identity.name == "bat" })
      #expect(report.exclusions.map(\.identity.name) == ["not-in-stock"])
    } else {
      // The same prepare path gates normal setup apply, before any provider work.
      let preparation = try fixture.planner().prepare(context: fixture.context)
      #expect(!preparation.succeeded)
      #expect(
        preparation.report.diagnostics.first?.message.contains("excludes required formula:bat")
          == true)
    }
  }

  @Test(arguments: ["zsh-autosuggestions", "zsh-syntax-highlighting", "fzf", "zoxide"])
  func shellIntegrationExclusionsBlockBeforeProviderMutation(package: String) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(portable: "[packages]\nexclude_formulae = [\"\(package)\"]\n")
    let preparation = try fixture.planner().prepare(context: fixture.context)
    #expect(!preparation.succeeded)
    #expect(
      preparation.report.diagnostics.contains {
        $0.message.contains("excludes required formula:\(package)")
      })
    #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))

    try fixture.profiles(
      portable: """
        [shell]
        provider = "disabled"
        [packages]
        exclude_formulae = ["\(package)"]
        """)
    let inventory = try fixture.planner().packageInventory(
      context: fixture.context, adoptionState: .available(nil))
    #expect(!inventory.proposed.contains { $0.identity.name == package })
  }

  @Test
  func shellPackagesExplainTheirSelectionOrigin() throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(portable: "[shell]\nprovider = \"zsh\"\n")
    let inventory = try fixture.planner().packageInventory(
      context: fixture.context, adoptionState: .available(nil))
    for name in ["zsh-autosuggestions", "zsh-syntax-highlighting", "fzf", "zoxide"] {
      let package = try #require(inventory.proposed.first { $0.identity.name == name })
      #expect(package.requirements.count == 1)
      #expect(package.requirements.first?.selectionField == "shell.provider")
      #expect(package.requirements.first?.layer == "portable")
    }
  }

  @Test(arguments: [
    "", "[terminal]\nprovider = \"disabled\"\n", "[kitty]\nfont_family = \"monospace\"\n",
  ])
  func kittyDefaultFontExclusionRequiresOptOut(override: String) throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(
      portable: override + "[packages]\nexclude_casks = [\"font-meslo-lg-nerd-font\"]\n")
    if override.isEmpty {
      let preparation = try fixture.planner().prepare(context: fixture.context)
      #expect(!preparation.succeeded)
      #expect(
        preparation.report.diagnostics.contains {
          $0.message.contains("excludes required cask:font-meslo-lg-nerd-font")
        })
      #expect(!FileManager.default.fileExists(atPath: fixture.context.stateRoot.path))
    } else {
      let inventory = try fixture.planner().packageInventory(
        context: fixture.context, adoptionState: .available(nil))
      #expect(!inventory.proposed.contains { $0.identity.name == "font-meslo-lg-nerd-font" })
    }
  }

  @Test(arguments: [false, true])
  func personalIntentFeedsNamedInstallationAndAdoption(alreadyInstalled: Bool) async throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(portable: "[packages]\nbaseline = \"personal\"\nbrewfile = \"Brewfile\"\n")
    try fixture.write("brew \"hello\"\n", layer: "portable")
    if alreadyInstalled { try fixture.install() }
    let personal = try Data(contentsOf: fixture.brewfile("portable"))
    let profile = try Data(contentsOf: fixture.context.profileURL)
    let preview = try await fixture.execute(adoption: alreadyInstalled)
    #expect(preview["outcome"]?.string == "preview")
    let approval = try #require(preview["approval_digest"]?.string)
    let applied = try await fixture.execute(adoption: alreadyInstalled, approval: approval)
    #expect(applied["outcome"]?.string == (alreadyInstalled ? "adopted" : "complete"))
    let ledger = try #require(try fixture.ledger.read())
    #expect(ledger.entries.map(\.identity.key) == ["formula:hello"])
    #expect(
      ledger.entries.first?.declarations.first?.sourcePath == fixture.brewfile("portable").path)
    #expect(try await fixture.execute(adoption: alreadyInstalled)["outcome"]?.string == "no_change")
    #expect(fixture.nativeCalls.withLock { $0 } == (alreadyInstalled ? 0 : 1))
    #expect(try Data(contentsOf: fixture.brewfile("portable")) == personal)
    #expect(try Data(contentsOf: fixture.context.profileURL) == profile)
  }

  @Test
  func changedFragmentBlocksUnifiedApplyBeforeProviderMutation() async throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try fixture.writeMachineProfile(
      "schema_version = 1\n[packages]\nbaseline = \"personal\"\nbrewfile = \"Brewfile\"\n")
    let fragment = fixture.state.appending(path: "Brewfile")
    try "brew \"hello\"\n".write(to: fragment, atomically: true, encoding: .utf8)
    let runner = fixture.runner(
      available: { _ in true },
      plannedStages: [.desktop, .environment],
      writePlan: { _ in
        try "brew \"different\"\n".write(to: fragment, atomically: true, encoding: .utf8)
      },
      theme: { _, _ in
        Issue.record("Stale package intent must block theme mutation")
        return try applyComponent("{}")
      },
      desktop: { _, _, _, _, _ in
        Issue.record("Stale package intent must block desktop mutation")
        return try applyComponent("{}")
      },
      environment: { _, _, _, _, _ in
        Issue.record("Stale package intent must block environment mutation")
        return try applyComponent("{}")
      })
    let result = try await runner.execute(
      context: fixture.context, consumerPaths: testConsumerPaths(),
      packageApproval: runner.planner.prepare(context: fixture.context).report.packageInstallation?
        .approvalDigest,
      json: true)
    let report = try jsonObject(result.output)
    #expect(!result.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(report["mutated"] as? Bool == false)
    #expect(
      report["message"] as? String
        == "The unified setup plan changed before mutation; review it and retry.")
  }

  @Test(arguments: [false, true])
  func changedFragmentOrMachineExclusionInvalidatesApproval(machineExcludes: Bool) async throws {
    let fixture = try PackageLayeringFixture()
    defer { fixture.inventory.cleanup() }
    try fixture.profiles(portable: "[packages]\nbrewfile = \"Brewfile\"\n")
    try fixture.write("brew \"hello\"\n", layer: "portable")
    let preview = try await fixture.execute(adoption: false)
    let approval = try #require(preview["approval_digest"]?.string)
    if machineExcludes {
      try fixture.inventory.write(
        "schema_version = 1\n[packages]\nexclude_formulae = [\"hello\"]\n",
        at: fixture.context.machineProfileURL)
    } else {
      try fixture.write("brew \"different\"\n", layer: "portable")
    }
    #expect(
      try await fixture.execute(adoption: false, approval: approval)["outcome"]?.string == "blocked"
    )
    #expect(fixture.nativeCalls.withLock { $0 } == 0)
    #expect(try fixture.ledger.read() == nil)
  }
}

private final class PackageLayeringFixture: Sendable {
  let inventory: InventoryFixture
  let installed = Mutex(false)
  let nativeCalls = Mutex(0)

  init() throws { inventory = try InventoryFixture() }

  var context: UnifiedSetupPlanContext {
    let root = inventory.root
    return .init(
      themesRoot: repositoryRoot.appending(path: "Themes"), keybindingsResourcesRoot: root,
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: root,
      profileURL: root.appending(path: "portable/profile.toml"), profileRequired: true,
      machineProfileURL: root.appending(path: "machine/profile.toml"), machineProfileRequired: true,
      stateRoot: root.appending(path: "state"), homeDirectory: root.appending(path: "home"))
  }
  var ledger: SetupPackageAdoptionStore {
    .init(stateRoot: context.stateRoot, homeDirectory: context.homeDirectory)
  }
  func brewfile(_ layer: String) -> URL { inventory.root.appending(path: "\(layer)/Brewfile") }
  func write(_ source: String, layer: String) throws {
    try inventory.write(source, at: brewfile(layer))
  }
  func profiles(portable: String, machine: String = "") throws {
    try inventory.write("schema_version = 1\n" + portable, at: context.profileURL)
    try inventory.write("schema_version = 1\n" + machine, at: context.machineProfileURL)
  }
  func install() throws {
    try inventory.formula("hello", tap: "homebrew/core")
    installed.withLock { $0 = true }
  }
  func planner() -> UnifiedSetupPlanCommandRunner {
    let unrelated: UnifiedSetupPlanCommandRunner.ComponentPlanner = { _, _ in
      Issue.record("This check must finish before unrelated provider planning")
      throw SetupPackageAdoptionError("unrelated provider planning")
    }
    return .init(
      capabilityIsAvailable: { _ in false }, desktopPlanner: unrelated,
      environmentPlanner: { context, profile, _ in try unrelated(context, profile) },
      packageInventoryReader: {
        self.inventory.reader(formulae: self.installed.withLock { $0 } ? "hello" : "").read()
      },
      standardBrewfile: { _ in
        try SetupBrewfile.parse("brew \"jq\"\nbrew \"git\"\ncask \"spotify\"\ncask \"docker\"\n")
      })
  }
  func execute(adoption: Bool, approval: String? = nil) async throws -> JSONValue {
    let result: (output: String, succeeded: Bool)
    if adoption {
      result = try await SetupPackageAdoptionCommandRunner(planner: planner()).execute(
        context: context, targets: ["formula:hello"], approval: approval, json: true)
    } else {
      let provider = HomebrewBundleInstaller(apply: { file, _ in
        #expect(try String(contentsOf: file, encoding: .utf8) == "brew \"hello\"\n")
        self.nativeCalls.withLock { $0 += 1 }
        try self.install()
        return .init(status: 0, diagnostic: "fixture native success")
      })
      result = try await SetupPackageInstallationCommandRunner(
        planner: planner(), provider: provider
      ).execute(
        context: context, targets: ["formula:hello"], approval: approval, json: true)
    }
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8))
  }
}
