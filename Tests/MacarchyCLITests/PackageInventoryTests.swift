import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageInventoryTests {
  @Test
  func localListsAndReceiptsEstablishKindTapAndVersionsWithoutMutation() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    try fixture.formula("bat", version: "1", tap: "homebrew/core")
    try fixture.formula("bat", version: "2", tap: "homebrew/core")
    try fixture.formula("yabai", tap: "asmvik/formulae")
    try fixture.cask("bat", tap: "vendor/apps")
    let calls = Mutex([ProcessRequest]())
    let reader = fixture.reader(formulae: "yabai\nbat", casks: "bat") { request in
      calls.withLock { $0.append(request) }
    }
    let before = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
    let observation = reader.read()

    #expect(observation.status == "available")
    #expect(
      observation.packages.compactMap { $0.identity?.key } == [
        "formula:bat", "formula:asmvik/formulae/yabai", "cask:vendor/apps/bat",
      ])
    #expect(observation.packages[0].versions == ["1", "2"])
    #expect(
      try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == before)
    let requests = calls.withLock { $0 }
    #expect(requests.count == 2)
    for kind in ["formula", "cask"] {
      #expect(
        requests.contains(
          ProcessRequest(
            executableURL: fixture.root.appending(path: "bin/brew"),
            arguments: ["list", "--\(kind)", "-1"],
            timeout: 10,
            environmentOverrides: [
              "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "LC_ALL": "C",
            ]
          )
        )
      )
    }
  }

  @Test
  func receiptFilesAloneAreNotAnInventoryAndExecutablesDoNotProveOwnership() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    try fixture.formula("atuin", tap: "homebrew/core")
    let executable = fixture.root.appending(path: ".atuin/bin/atuin")
    try fixture.write("#!/bin/sh\n", at: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let capability = try #require(
      DependencyProfile.personal(homeDirectory: fixture.root).capabilities.first {
        $0.id == "atuin"
      }
    )
    #expect(capability.isAvailable())
    let observation = fixture.reader().read()
    #expect(observation.packages.isEmpty)
    let report = inventory(
      [
        SetupCapability(
          id: capability.id, category: capability.category, status: .present,
          requirement: capability.requirement, remediation: capability.remediation
        )
      ], observation: observation)
    let atuin = try #require(report.proposed.first { $0.identity.name == "atuin" })
    #expect(atuin.homebrewStatus == "missing")
    #expect(atuin.externallySatisfiedCapabilities == ["atuin"])
  }

  @Test
  func malformedMissingAndConflictingReceiptsStayUnresolved() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    try fixture.formula("bat", version: "1", tap: "homebrew/core")
    try fixture.formula("bat", version: "2", tap: "vendor/tap")
    try fixture.write(
      "{broken", at: fixture.root.appending(path: "Cellar/eza/1/INSTALL_RECEIPT.json"))
    try FileManager.default.createDirectory(
      at: fixture.root.appending(path: "Cellar/atuin/1"), withIntermediateDirectories: true
    )
    try fixture.cask("kitty", tap: "homebrew/cask")
    try fixture.write(
      "{}", at: fixture.root.appending(path: "Caskroom/kitty/.metadata/INSTALL_RECEIPT.json"))
    let observation = fixture.reader(formulae: "bat\neza\natuin", casks: "kitty").read()
    #expect(observation.status == "incomplete")
    #expect(observation.packages.allSatisfy { $0.identity == nil && $0.issue != nil })
    #expect(observation.packages.first { $0.token == "bat" }?.issue?.contains("Ambiguous") == true)
    let report = inventory([capability("bat", .formula("bat"))], observation: observation)
    let bat = try #require(report.proposed.first { $0.identity.name == "bat" })
    #expect(bat.homebrewStatus == "unknown")
    #expect(bat.externallySatisfiedCapabilities.isEmpty)
    #expect(report.unresolvedInstallations.count == 4)
  }

  @Test
  func renamedTapIsNotSilentlyEquatedAndSymlinkedRacksAreUnsupported() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    try fixture.formula("yabai", tap: "koekeishiya/formulae")
    try fixture.formula("bat", tap: "homebrew/core")
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appending(path: "Cellar/eza"),
      withDestinationURL: fixture.root.appending(path: "Cellar/bat")
    )
    let observation = fixture.reader(formulae: "yabai\neza").read()
    let report = inventory(
      [
        capability("yabai", .formula("asmvik/formulae/yabai")),
        capability("eza", .formula("eza")),
      ], observation: observation)
    #expect(
      report.proposed.first { $0.identity.token == "yabai" }?.homebrewStatus
        == "different_recorded_identity")
    #expect(report.outsideProposedRequirements[0].identity?.name == "koekeishiya/formulae/yabai")
    #expect(report.proposed.first { $0.identity.token == "eza" }?.homebrewStatus == "unknown")
  }

  @Test
  func invalidListingNeverBecomesAnEmptySuccessfulInventory() throws {
    for output in [
      "bat\nbat", "../bat", "Warning: incomplete list", "bat\n",
      String(repeating: "b", count: 32_769),
    ] {
      let fixture = try InventoryFixture()
      defer { fixture.cleanup() }
      let observation = fixture.reader(formulae: output).read()
      #expect(observation.status == "unavailable")
      let report = inventory([capability("bat", .formula("bat"))], observation: observation)
      #expect(report.proposed.allSatisfy { $0.homebrewStatus == "unknown" })
      #expect(!report.observation.issues.isEmpty)
    }
  }

  @Test
  func unavailableFailedAndTimedOutHomebrewAreExplicit() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let absent = HomebrewPackageInventoryReader(
      prefix: fixture.root,
      processRunner: ProcessRunner { _ in
        Issue.record("Absent Homebrew must not execute")
        return ProcessResult(terminationStatus: 0, output: "")
      },
      executableIsAvailable: { false }
    )
    #expect(absent.read().status == "unavailable")
    for timedOut in [false, true] {
      let reader = HomebrewPackageInventoryReader(
        prefix: fixture.root,
        processRunner: ProcessRunner { request in
          if timedOut { throw ProcessRunnerError.timedOut(request.executableURL, 10) }
          return ProcessResult(terminationStatus: 1, output: "failed")
        },
        executableIsAvailable: { true }
      )
      let observation = reader.read()
      #expect(observation.status == "unavailable")
      #expect(observation.issues.count == 2)
    }
  }

  @Test
  func duplicatesRetainProvenanceAndOfficialKindsRemainDistinct() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    try fixture.formula("bat", tap: "homebrew/core")
    try fixture.formula("unrelated", tap: "homebrew/core")
    let capabilities = [
      capability("bat", .formula("bat")),
      capability("eza", .formula("homebrew/core/bat"), status: .missing),
      capability("codex", .cask("homebrew/cask/bat")),
      capability("pi", .external("Install via npm.")),
    ]
    let layers = [
      SetupProfileLayerReport(
        kind: "portable", path: "/dotfiles/profile.toml", status: "loaded",
        declaredFields: ["tools.bat"]),
      SetupProfileLayerReport(
        kind: "machine", path: "/state/machine.toml", status: "loaded",
        declaredFields: ["tools.eza"]),
    ]
    let observation = fixture.reader(formulae: "unrelated\nbat").read()
    let report = SetupPackageInventory(
      capabilities: capabilities, fieldOrigins: ["tools.bat": "portable", "tools.eza": "machine"],
      layers: layers, observation: observation
    )
    let formula = try #require(report.proposed.first { $0.identity.key == "formula:bat" })
    #expect(report.proposed.contains { $0.identity.key == "cask:bat" })
    #expect(formula.requirements.map(\.capabilityID) == ["bat", "eza"])
    #expect(formula.requirements.map(\.layer) == ["portable", "machine"])
    #expect(
      formula.requirements.map(\.sourcePath) == ["/dotfiles/profile.toml", "/state/machine.toml"])
    #expect(formula.homebrewStatus == "installed")
    #expect(formula.externallySatisfiedCapabilities.isEmpty)
    #expect(report.nonHomebrewRequirements.map(\.capabilityID) == ["pi"])
    #expect(report.outsideProposedRequirements.compactMap { $0.identity?.name } == ["unrelated"])
    let reordered = SetupPackageInventory(
      capabilities: capabilities.reversed(),
      fieldOrigins: ["tools.eza": "machine", "tools.bat": "portable"],
      layers: layers, observation: observation
    )
    #expect(try renderJSON(report) == renderJSON(reordered))
    #expect(report.humanOutput == reordered.humanOutput)
  }

  @Test
  func defaultPreviewContainsTheApprovedSetWithoutExpandingApply() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    var planner = fixture.planner(available: { _ in false })
    planner.packageInventoryReader = { HomebrewPackageObservation(packages: [], issues: []) }
    let prepared = try planner.prepare(context: fixture.context).report
    let report = planner.inspectedReport(prepared, context: fixture.context)
    let packages = try #require(report.packageInventory)
    let expectedFormulae = Set([
      "asmvik/formulae/skhd", "asmvik/formulae/yabai", "atuin", "azure-cli", "bat", "btop",
      "cmake", "eza", "fd", "felixkratz/formulae/sketchybar", "fzf", "gh", "git", "go",
      "hashicorp/tap/terraform", "helm", "herdr", "hugo", "ifstat", "jq", "kind",
      "kubernetes-cli", "lazydocker", "lazygit", "lua", "mosh", "neovim", "node", "ollama",
      "pkgconf", "poppler", "resvg", "ripgrep", "rustup", "sevenzip", "starship", "stow",
      "switchaudio-osx", "tmux", "tree-sitter", "tree-sitter-cli", "unar", "uv", "wget",
      "yazi", "zig", "zoxide",
    ])
    let expectedCasks = Set([
      "anki", "cursor", "docker", "flameshot", "font-blex-mono-nerd-font",
      "font-meslo-lg-nerd-font", "font-sketchybar-app-font", "font-symbols-only-nerd-font",
      "google-chrome", "kitty", "slack", "spotify", "tailscale", "zen", "zoom",
    ])
    #expect(
      Set(packages.proposed.filter { $0.identity.kind == .formula }.map(\.identity.name))
        == expectedFormulae)
    #expect(
      Set(packages.proposed.filter { $0.identity.kind == .cask }.map(\.identity.name))
        == expectedCasks)
    #expect(packages.proposed.count == 62)
    #expect(packages.proposed.filter { $0.standardDeclaration != nil }.count == 51)
    #expect(packages.proposed.allSatisfy { $0.homebrewStatus == "missing" })
    #expect(packages.proposed.map(\.identity.key) == packages.proposed.map(\.identity.key).sorted())
    for name in ["herdr", "slack", "spotify"] {
      let package = try #require(packages.proposed.first { $0.identity.name == name })
      #expect(package.requirements.isEmpty)
      #expect(!report.capabilities.contains { $0.id == name })
    }
    let terraform = try #require(packages.proposed.first { $0.identity.token == "terraform" })
    guard case .external(let instruction, let formula) = terraform.standardDeclaration?.remediation
    else {
      Issue.record("Terraform must retain the manual third-party trust boundary")
      return
    }
    #expect(formula == "hashicorp/tap/terraform")
    #expect(instruction.contains("brew trust --formula hashicorp/tap/terraform"))
    #expect(packages.humanOutput.contains("Apply does not yet provision the standard baseline"))
    #expect(
      Set(report.packages.formulae)
        == Set(["atuin", "bat", "btop", "eza", "neovim", "starship", "yazi"]))
    #expect(report.packages.casks == ["kitty"])
  }

  @Test
  func standardPackagesRetainIndependentPresetProvenanceAndObservation() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try """
    schema_version = 1
    [presets]
    herdr = true
    spicetify = true
    """.write(to: fixture.context.profileURL, atomically: true, encoding: .utf8)
    try fixture.writeMachineProfile("schema_version = 1\n[presets]\nslack = true\n")
    var planner = fixture.planner()
    planner.packageInventoryReader = {
      HomebrewPackageObservation(
        packages: [
          HomebrewInstalledPackage(
            kind: .formula, token: "git",
            identity: HomebrewPackageIdentity(kind: .formula, name: "git"),
            versions: ["1"], receiptPaths: [], issue: nil)
        ], issues: [])
    }
    let report = planner.inspectedReport(
      try planner.prepare(context: fixture.context).report, context: fixture.context)
    let packages = try #require(report.packageInventory)
    #expect(packages.proposed.count == 63)  // Only spicetify-cli adds a package.
    for (name, field, layer, source) in [
      ("herdr", "presets.herdr", "portable", fixture.context.profileURL.path),
      ("spotify", "presets.spicetify", "portable", fixture.context.profileURL.path),
      ("slack", "presets.slack", "machine", fixture.context.machineProfileURL.path),
    ] {
      let package = try #require(packages.proposed.first { $0.identity.name == name })
      #expect(package.standardDeclaration != nil)
      #expect(package.requirements.count == 1)
      #expect(package.requirements[0].selectionField == field)
      #expect(package.requirements[0].layer == layer)
      #expect(package.requirements[0].sourcePath == source)
      #expect(package.externallySatisfiedCapabilities == [name])
    }
    let git = try #require(packages.proposed.first { $0.identity.name == "git" })
    #expect(git.homebrewStatus == "installed")
    #expect(git.requirements.isEmpty)
    #expect(packages.outsideProposedRequirements.isEmpty)
  }

  @Test
  func providerOptOutsAndManualTrustUseTheExistingDependencySelection() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    [tools]
    bat = false
    [presets]
    pi = true
    """.write(to: fixture.context.profileURL, atomically: true, encoding: .utf8)
    let planner = fixture.planner()
    let preparation = try planner.prepare(context: fixture.context)
    let report = planner.inspectedReport(preparation.report, context: fixture.context)
    let packages = try #require(report.packageInventory)
    #expect(!packages.proposed.contains { ["bat", "sketchybar"].contains($0.identity.token) })
    #expect(packages.proposed.count == 60)
    #expect(packages.proposed.filter { $0.standardDeclaration != nil }.count == 51)
    let yabai = try #require(packages.proposed.first { $0.identity.token == "yabai" })
    #expect(yabai.identity.name == "asmvik/formulae/yabai")
    #expect(yabai.requirements[0].selectionField == "desktop.provider")
    #expect(packages.nonHomebrewRequirements.contains { $0.capabilityID == "pi" })
    #expect(packages.humanOutput.contains("Manual/trust boundary: Run: brew trust"))
  }

  @Test
  func planAndStatusExposeInventoryButApplyPreparationDoesNotInspectIt() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    var planner = fixture.planner()
    planner.packageInventoryReader = {
      calls.withLock { $0 += 1 }
      return .unavailable("test inventory unavailable")
    }
    let preparation = try planner.prepare(context: fixture.context)
    #expect(calls.withLock { $0 } == 0)
    #expect(preparation.report.packageInventory == nil)
    let plan = try planner.execute(context: fixture.context, json: true)
    let planJSON = try JSONDecoder().decode(JSONValue.self, from: Data(plan.output.utf8))
    #expect(planJSON["package_inventory"]?["observation"]?["status"]?.string == "unavailable")
    #expect(planJSON["package_inventory"]?["observation"]?["issues"]?.array?.count == 1)
    let proposed = try #require(planJSON["package_inventory"]?["proposed"]?.array)
    #expect(proposed.count == 62)
    #expect(proposed.allSatisfy { $0["homebrew_status"]?.string == "unknown" })
    #expect(
      planJSON["package_inventory"]?["provisioning"]?.string
        == "preview_only_existing_apply_unchanged")
    let inspection = UnifiedSetupInspectionCommandRunner(
      planner: planner, themeInspection: UnifiedSetupThemeLifecycleStatus.inspect,
      desktopInspection: { _, _, _, _ in try applyComponent("{}") },
      environmentInspection: { _, _, _, _ in try applyComponent("{}") }
    )
    let status = try inspection.execute(
      operation: .status, context: fixture.context, consumerPaths: testConsumerPaths(), json: false
    )
    #expect(status.succeeded)
    #expect(status.output.contains("Package inventory [unavailable"))
    #expect(status.output.contains("test inventory unavailable"))
    let statusJSON = try inspection.execute(
      operation: .status, context: fixture.context, consumerPaths: testConsumerPaths(), json: true
    )
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(statusJSON.output.utf8))
    #expect(
      try renderJSON(decoded["plan"]?["package_inventory"])
        == renderJSON(planJSON["package_inventory"]))
    #expect(calls.withLock { $0 } == 3)
  }

  private func capability(
    _ id: String, _ remediation: DependencyRemediation, status: SetupCapability.Status = .present
  ) -> SetupCapability {
    SetupCapability(
      id: id, category: .requiredAdapter, status: status, requirement: id, remediation: remediation)
  }

  private func inventory(
    _ capabilities: [SetupCapability], observation: HomebrewPackageObservation
  ) -> SetupPackageInventory {
    SetupPackageInventory(
      capabilities: capabilities, fieldOrigins: [:], layers: [], observation: observation)
  }
}

struct InventoryFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-package-inventory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }

  func write(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func formula(_ token: String, version: String = "1", tap: String) throws {
    try write(
      #"{"homebrew_version":"6.0.18","source":{"tap":"\#(tap)"}}"#,
      at: root.appending(path: "Cellar/\(token)/\(version)/INSTALL_RECEIPT.json")
    )
  }

  func cask(_ token: String, tap: String) throws {
    let metadata = root.appending(path: "Caskroom/\(token)/.metadata")
    try write(
      #"{"homebrew_version":"6.0.18","source":{"tap":"\#(tap)","version":"1"}} "#,
      at: metadata.appending(path: "INSTALL_RECEIPT.json")
    )
    try FileManager.default.createDirectory(
      at: metadata.appending(path: "1"), withIntermediateDirectories: true)
  }

  func reader(
    formulae: String = "", casks: String = "",
    record: @escaping @Sendable (ProcessRequest) -> Void = { _ in }
  ) -> HomebrewPackageInventoryReader {
    HomebrewPackageInventoryReader(
      prefix: root,
      processRunner: ProcessRunner { request in
        record(request)
        return ProcessResult(
          terminationStatus: 0, output: request.arguments[1] == "--formula" ? formulae : casks)
      },
      executableIsAvailable: { true }
    )
  }
}
