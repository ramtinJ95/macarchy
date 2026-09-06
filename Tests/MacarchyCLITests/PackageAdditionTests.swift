import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageAdditionTests {
  @Test
  func recoveryCLIParsesWithoutTargets() throws {
    let command = try Macarchy.Setup.AddPackages.parse(["--recover", "--json"])
    #expect(command.targets.isEmpty)
    #expect(command.recover)
  }

  @Test
  func previewsWithoutWritesThenSavesBeforeMixedInstallAndAdoption() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let original = "# My packages\n\nbrew 'unrelated' # keep this"
    try fixture.write(original)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640], ofItemAtPath: fixture.fragment.path)
    let profile = try Data(contentsOf: fixture.base.context.profileURL)
    let runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:jq", "formula:orphan"])
    #expect(preview.outcome == "preview")
    #expect(preview.json["preview"]?["edits"]?.array?.first?["before"]?.string == original)
    #expect(preview.json["preview"]?["installation"]?["brewfile"]?.string == "brew \"jq\"\n")
    #expect(preview.json["preview"]?["adoption"]?.array?.count == 1)
    #expect(preview.json["preview"]?["installation"]?["ledger"] == nil)
    #expect(preview.json["preview"]?["edits"]?.array?.first?["snapshot"] == nil)
    #expect(try fixture.contents() == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.base.context.stateRoot.path))
    let complete = try await fixture.run(
      runner, targets: ["formula:jq", "formula:orphan"], approval: preview.approval())
    #expect(complete.outcome == "complete", "\(complete.json["stages"] ?? .null)")
    #expect(try fixture.contents() == original + "\nbrew \"jq\"\nbrew \"orphan\"\n")
    #expect(try BoundedRegularFile.read(at: fixture.fragment).permissions == 0o640)
    #expect(try Data(contentsOf: fixture.base.context.profileURL) == profile)
    #expect(
      try Set(fixture.base.ledger.read()?.entries.map(\.identity.name) ?? []) == ["jq", "orphan"])
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.base.context.stateRoot).read() == nil)
    let ledger = try Data(contentsOf: fixture.base.ledger.url)
    #expect(
      try await fixture.run(runner, targets: ["formula:jq", "formula:orphan"]).outcome
        == "no_change")
    #expect(try Data(contentsOf: fixture.base.ledger.url) == ledger)
    #expect(fixture.base.calls.withLock { $0 } == 1)
  }

  @Test(arguments: HomebrewPackageIdentity.Kind.allCases)
  func installedPackageUsesAdoptionWithoutNativePreflightOrUpgrade(
    kind: HomebrewPackageIdentity.Kind
  ) async throws {
    let fixture = try AdditionFixture(kind: kind)
    defer { fixture.base.inventory.cleanup() }
    try fixture.base.install()
    let runner = SetupPackageAdditionCommandRunner(
      planner: fixture.base.runner().planner,
      provider: .init(
        preflight: { throw SetupPackageAdoptionError("must not preflight") },
        apply: { _, _ in throw SetupPackageAdoptionError("must not install") }))
    let preview = try await fixture.run(runner)
    #expect(preview.outcome == "preview")
    #expect(preview.json["preview"]?["installation"] == nil)
    #expect(
      try await fixture.run(runner, approval: preview.approval()).outcome == "complete")
    #expect(try fixture.base.ledger.read()?.entries.map(\.identity) == [fixture.base.target])
    #expect(try await fixture.run(runner).outcome == "no_change")
  }

  @Test(
    arguments: ["bytes", "same-bytes-inode", "profile", "mode", "receipt", "late", "wrong"]
      .map { ($0, HomebrewPackageIdentity.Kind.formula) }
      + [("receipt", .cask), ("late", .cask)])
  func staleApprovalDoesNotEditOrInstall(change: String, kind: HomebrewPackageIdentity.Kind)
    async throws
  {
    let fixture = try AdditionFixture(kind: kind)
    defer { fixture.base.inventory.cleanup() }
    var runner = fixture.runner()
    let preview = try await fixture.run(runner)
    switch change {
    case "bytes": try fixture.write("# edited\n")
    case "same-bytes-inode": try fixture.write(fixture.contents())
    case "profile":
      try fixture.base.inventory.write(
        AdditionFixture.profile + "\n# edited\n", at: fixture.base.context.profileURL)
    case "mode":
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400], ofItemAtPath: fixture.fragment.path)
    case "receipt": try fixture.base.install()
    case "late":
      runner.checkpoint = { point in
        if case .beforeRevalidation = point { try fixture.write("# concurrent edit\n") }
      }
    default: break
    }
    let before = try fixture.contents()
    let result = try await fixture.run(
      runner, approval: change == "wrong" ? "wrong" : preview.approval())
    #expect(result.outcome == "blocked")
    #expect(try fixture.contents() == (change == "late" ? "# concurrent edit\n" : before))
    #expect(fixture.base.calls.withLock { $0 } == 0)
    #expect(try fixture.base.ledger.read() == nil)
  }

  @Test(arguments: ["native", "after-save"], HomebrewPackageIdentity.Kind.allCases)
  func failureRetainsIntentAndRetryAdoptsOrInstallsOnlyPendingTargets(
    failure: String, kind: HomebrewPackageIdentity.Kind
  ) async throws {
    let fixture = try AdditionFixture(kind: kind)
    defer { fixture.base.inventory.cleanup() }
    var runner = fixture.runner(status: failure == "native" ? 1 : 0)
    if failure == "after-save" {
      runner.checkpoint = { point in
        if case .afterSave = point { throw SetupPackageAdoptionError("interruption") }
      }
    }
    let preview = try await fixture.run(runner)
    let pending = try await fixture.run(runner, approval: preview.approval())
    #expect(pending.outcome == "pending")
    #expect(pending.json["intent"]?.string == "saved")
    #expect(try fixture.contents() == "# personal\n" + fixture.base.brewfile)
    #expect(try fixture.base.ledger.read() == nil)
    let next = try await fixture.run(fixture.runner())
    #expect(next.outcome == "preview")
    #expect(
      try await fixture.run(fixture.runner(), approval: next.approval()).outcome == "complete")
    #expect(fixture.base.calls.withLock { $0 } == 1)
  }

  @Test
  func nativeChangesToReviewedInstalledCandidateRequireFreshAdoptionApproval() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let base = fixture.runner()
    let runner = SetupPackageAdditionCommandRunner(
      planner: base.planner,
      provider: .init(apply: { url, record in
        let result = try base.provider.apply(url, record)
        try fixture.base.inventory.formula("orphan", version: "2", tap: "homebrew/core")
        return result
      }))
    let preview = try await fixture.run(runner, targets: ["formula:jq", "formula:orphan"])
    let result = try await fixture.run(
      runner, targets: ["formula:jq", "formula:orphan"], approval: preview.approval())
    #expect(result.outcome == "pending")
    #expect(try fixture.base.ledger.read()?.entries.map(\.identity.name) == ["jq"])
    #expect(try fixture.contents().contains("brew \"orphan\""))
  }

  @Test
  func lostPriorHistoryCannotExpandTheReviewedAdoptionSet() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let initial = try await fixture.run(fixture.runner(), targets: ["formula:orphan"])
    try #require(
      try await fixture.run(
        fixture.runner(), targets: ["formula:orphan"], approval: initial.approval()
      ).outcome == "complete")
    try fixture.base.install()
    var runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:jq", "formula:orphan"])
    #expect(
      preview.json["preview"]?["already_adopted"]?.array?.compactMap(\.string) == ["formula:orphan"]
    )
    runner.checkpoint = { point in
      if case .afterSave = point { try FileManager.default.removeItem(at: fixture.base.ledger.url) }
    }
    let result = try await fixture.run(
      runner, targets: ["formula:jq", "formula:orphan"], approval: preview.approval())
    #expect(result.outcome == "pending")
    #expect(try fixture.base.ledger.read() == nil)
    #expect(fixture.base.calls.withLock { $0 } == 0)
  }

  @Test(arguments: [
    "unsupported", "machine-exclusion", "shared", "hard-link", "residue", "cask-tap", "tap",
    "preflight",
  ])
  func unsupportedInputsStopWithoutSaving(mode: String) async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    var targets = ["formula:jq"]
    var runner = fixture.runner()
    switch mode {
    case "unsupported": try fixture.write("brew ENV['PACKAGE']\n")
    case "machine-exclusion":
      try fixture.base.inventory.write(
        "schema_version = 1\n[packages]\nexclude_formulae = [\"jq\"]\n",
        at: fixture.base.context.machineProfileURL)
    case "shared":
      try fixture.base.inventory.write(
        AdditionFixture.profile, at: fixture.base.context.machineProfileURL)
    case "hard-link":
      try FileManager.default.linkItem(
        at: fixture.fragment, to: fixture.fragment.appendingPathExtension("linked"))
    case "residue":
      try fixture.base.inventory.write(
        "retained",
        at: fixture.fragment.deletingLastPathComponent().appending(
          path: ".Brewfile.macarchy-add-packages"))
    case "cask-tap": targets = ["cask:vendor/apps/slack"]
    case "tap": targets = ["formula:vendor/tap/jq"]
    case "preflight":
      runner = .init(
        planner: runner.planner,
        provider: .init(
          preflight: { throw SetupPackageAdoptionError("blocked runtime") },
          apply: runner.provider.apply))
    default: break
    }
    let before = try? Data(contentsOf: fixture.fragment)
    let result = try await fixture.run(runner, targets: targets)
    #expect(result.outcome == "blocked")
    #expect((try? Data(contentsOf: fixture.fragment)) == before)
    #expect(fixture.base.calls.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.base.context.stateRoot.path))
  }

  @Test
  func explicitMachineTargetOverridesPortableExclusionWithoutEditingPortableFiles() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let portable = AdditionFixture.profile + "exclude_formulae = [\"orphan\"]\n"
    try fixture.base.inventory.write(portable, at: fixture.base.context.profileURL)
    try fixture.base.inventory.write(
      "schema_version = 1\n[packages]\nbrewfile = \"MachineBrewfile\"\n",
      at: fixture.base.context.machineProfileURL)
    let machine = fixture.fragment.deletingLastPathComponent().appending(path: "MachineBrewfile")
    try fixture.base.inventory.write("# machine\n", at: machine)
    let runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:orphan"], machineOnly: true)
    #expect(preview.json["preview"]?["layer"]?.string == "machine")
    #expect(
      try await fixture.run(
        runner, targets: ["formula:orphan"], machineOnly: true, approval: preview.approval()
      ).outcome == "complete")
    #expect(try fixture.contents() == "# personal\n")
    #expect(try String(contentsOf: fixture.base.context.profileURL, encoding: .utf8) == portable)
    #expect(try String(contentsOf: machine, encoding: .utf8) == "# machine\nbrew \"orphan\"\n")
  }

  @Test
  func symlinkedProfileStillEditsBesideItsResolvedSource() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let root = fixture.base.inventory.root.appending(path: "dotfiles")
    let source = root.appending(path: "profile.toml")
    try fixture.base.inventory.write(AdditionFixture.profile, at: source)
    let fragment = root.appending(path: "Brewfile")
    try fixture.base.inventory.write("# resolved\n", at: fragment)
    try FileManager.default.removeItem(at: fixture.base.context.profileURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.base.context.profileURL, withDestinationURL: source)
    let runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:orphan"])
    #expect(
      preview.json["preview"]?["edits"]?.array?.first?["path"]?.string
        == fragment.standardizedFileURL.path)
    #expect(
      try await fixture.run(runner, targets: ["formula:orphan"], approval: preview.approval())
        .outcome == "complete")
    #expect(try fixture.contents() == "# personal\n")
    #expect(try String(contentsOf: fragment, encoding: .utf8) == "# resolved\nbrew \"orphan\"\n")
  }

  @Test
  func interruptedSwapRetainsBothFilesAndBlocksTheNextPackageAction() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let edit = try SetupPackageInputEdit.prepare(
      url: fixture.fragment.resolvingSymlinksInPath(), targets: [.init(kind: .formula, name: "jq")])
    #expect(throws: SetupPackageAdoptionError.self) {
      try edit.publish(
        using: .init(faultInjector: { point in
          if case .replacementSwapped = point { throw SetupPackageAdoptionError("interrupted") }
        }))
    }
    #expect(try fixture.contents() == edit.after)
    #expect(
      try String(
        contentsOf: edit.url.deletingLastPathComponent().appending(path: edit.replacementName),
        encoding: .utf8) == edit.before)
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    #expect(fixture.base.calls.withLock { $0 } == 0)
  }

  @Test(
    arguments: ["missing-profile", "missing-wiring", "missing-fragment", "machine"]
      .map { ($0, HomebrewPackageIdentity.Kind.formula) }
      + [("missing-wiring", .cask), ("machine", .cask)])
  func createsAndWiresOnlySelectedInputs(mode: String, kind: HomebrewPackageIdentity.Kind)
    async throws
  {
    let fixture = try AdditionFixture(kind: kind)
    defer { fixture.base.inventory.cleanup() }
    let machine = mode == "machine"
    let context = fixture.base.context
    let source = machine ? context.machineProfileURL : context.profileURL
    let portable = try Data(contentsOf: context.profileURL)
    switch mode {
    case "missing-profile": try FileManager.default.removeItem(at: source)
    case "missing-wiring":
      try fixture.base.inventory.write("# retain\nschema_version = 1\n", at: source)
    case "missing-fragment": try FileManager.default.removeItem(at: fixture.fragment)
    default: break
    }
    let fragment =
      mode == "missing-fragment"
      ? fixture.fragment
      : source.deletingLastPathComponent().appending(path: source.lastPathComponent + ".Brewfile")
    let native = fixture.base.runner()
    let runner = SetupPackageAdditionCommandRunner(
      planner: native.planner,
      provider: .init(apply: { url, record in
        // The real loader/compiler must see BOTH saved files before native work.
        let inventory = try native.planner.packageInventory(
          context: context, adoptionState: .available(nil))
        #expect(inventory.proposed.contains { $0.identity == fixture.base.target })
        #expect(try String(contentsOf: fragment, encoding: .utf8) == fixture.base.brewfile)
        return try native.provider.apply(url, record)
      }))
    let before = try? Data(contentsOf: source)
    let preview = try await fixture.run(runner, machineOnly: machine)
    #expect(preview.outcome == "preview", "\(preview.json)")
    #expect(preview.json["preview"]?["edits"]?.array?.count == 2)
    #expect((try? Data(contentsOf: source)) == before)
    #expect(!FileManager.default.fileExists(atPath: fragment.path))
    #expect(!FileManager.default.fileExists(atPath: context.stateRoot.path))
    let result = try await fixture.run(
      runner, machineOnly: machine, approval: preview.approval())
    #expect(result.outcome == "complete", "\(result.json)")
    #expect(try BoundedRegularFile.read(at: fragment).permissions == 0o600)
    if machine { #expect(try Data(contentsOf: context.profileURL) == portable) }
    if mode == "missing-wiring" {
      #expect(
        try String(contentsOf: source, encoding: .utf8).hasPrefix("# retain\nschema_version = 1\n"))
    }
    #expect(try await fixture.run(runner, machineOnly: machine).outcome == "no_change")
    #expect(fixture.base.calls.withLock { $0 } == 1)
  }

  @Test(arguments: [false, true])
  func removesOnlyNamedSelectedExclusionsAndPreservesText(machine: Bool) async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let source = machine ? fixture.base.context.machineProfileURL : fixture.base.context.profileURL
    let original = """
      # unrelated header
      schema_version = 1
      [packages] # intent
      baseline = 'personal'
      brewfile = "Brewfile"
      exclude_formulae = [
        'other', # keep
        "j\\u0071", # restore jq
        'orphan' # restore orphan
      ] # keep trailing comment
      exclude_casks = ['slack']
      [tools]
      bat = false # unrelated setting

      """
    if machine {
      try fixture.base.inventory.write("schema_version = 1\n", at: fixture.base.context.profileURL)
    }
    try fixture.base.inventory.write(original, at: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let preview = try await fixture.run(
      fixture.runner(), targets: ["formula:jq", "formula:orphan"], machineOnly: machine)
    #expect(preview.outcome == "preview", "\(preview.json)")
    let expected = original.replacingOccurrences(of: #""j\u0071","#, with: "")
      .replacingOccurrences(of: "'orphan'", with: "")
    #expect(preview.json["preview"]?["edits"]?.array?.last?["after"]?.string == expected)
    let complete = try await fixture.run(
      fixture.runner(), targets: ["formula:jq", "formula:orphan"], machineOnly: machine,
      approval: preview.approval())
    #expect(complete.outcome == "complete", "\(complete.json)")
    #expect(try String(contentsOf: source, encoding: .utf8) == expected)
    #expect(try BoundedRegularFile.read(at: source).permissions == 0o640)
  }

  @Test(
    arguments: ["none", "before", "after", "same-bytes", "residue"]
      .map { ($0, HomebrewPackageIdentity.Kind.formula) } + [("none", .cask)])
  func interruptedTwoFileSaveRequiresExplicitRecoveryAndBlocksEveryDrift(
    drift: String, kind: HomebrewPackageIdentity.Kind
  ) async throws {
    let fixture = try AdditionFixture(kind: kind)
    defer { fixture.base.inventory.cleanup() }
    let context = fixture.base.context
    let field = kind == .formula ? "exclude_formulae" : "exclude_casks"
    let profile = AdditionFixture.profile + "\(field) = ['\(fixture.base.target.name)'] # restore\n"
    try fixture.base.inventory.write(profile, at: context.profileURL)
    var runner = fixture.runner()
    runner.checkpoint = { point in
      if case .afterInput(0) = point {
        throw SetupPackageAdoptionError("interrupted between files")
      }
    }
    let preview = try await fixture.run(runner)
    let interrupted = try await fixture.run(runner, approval: preview.approval())
    #expect(interrupted.outcome == "blocked")
    #expect(interrupted.json["intent"]?.string == "publication_unverified")
    #expect(try fixture.contents().contains(fixture.base.brewfile))
    #expect(try String(contentsOf: context.profileURL, encoding: .utf8) == profile)
    #expect(try await fixture.run(fixture.runner()).outcome == "blocked")
    switch drift {
    case "before": try fixture.base.inventory.write(profile + "# editor\n", at: context.profileURL)
    case "after": try fixture.write("# external edit\n")
    case "same-bytes": try fixture.write(fixture.contents())
    case "residue":
      try fixture.base.inventory.write(
        "unknown",
        at: fixture.fragment.deletingLastPathComponent()
          .appending(path: ".Brewfile.macarchy-add-packages"))
    default: break
    }
    let fragmentBeforeRecovery = try fixture.contents()
    let profileBeforeRecovery = try Data(contentsOf: context.profileURL)
    let recovery = try await fixture.run(fixture.runner(), targets: [], recover: true)
    #expect(recovery.outcome == (drift == "none" ? "recovered" : "blocked"), "\(recovery.json)")
    #expect(fixture.base.calls.withLock { $0 } == 0)
    #expect(try fixture.base.ledger.read() == nil)
    #expect(try fixture.contents() == fragmentBeforeRecovery)
    if drift == "none" {
      let next = try await fixture.run(fixture.runner())
      #expect(next.outcome == "preview")
      #expect(
        try await fixture.run(fixture.runner(), approval: preview.approval()).outcome == "blocked")
      #expect(
        try await fixture.run(fixture.runner(), approval: next.approval()).outcome == "complete")
    } else {
      #expect(try Data(contentsOf: context.profileURL) == profileBeforeRecovery)
      #expect(try SetupPackageInputPublicationStore(context: context).read()?.complete == false)
    }
  }

  @Test
  func newlyCreatedInputIsRecoverableWithoutStartingPackages() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let context = fixture.base.context
    try fixture.base.inventory.write("schema_version = 1\n", at: context.profileURL)
    var runner = fixture.runner()
    runner.checkpoint = { point in
      if case .afterInput(0) = point { throw SetupPackageAdoptionError("interrupted") }
    }
    let preview = try await fixture.run(runner, targets: ["formula:orphan"])
    #expect(
      try await fixture.run(runner, targets: ["formula:orphan"], approval: preview.approval())
        .outcome == "blocked")
    #expect(try await fixture.run(runner, targets: [], recover: true).outcome == "recovered")
    #expect(try fixture.base.ledger.read() == nil)
    #expect(fixture.base.calls.withLock { $0 } == 0)
    #expect(try await fixture.run(runner, targets: [], recover: true).outcome == "no_change")
  }

  @Test
  func completedPublicationAllowsAnotherProfileAndAbsentParentDirectories() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let runner = fixture.runner()
    let preview = try await fixture.run(runner, targets: ["formula:orphan"])
    #expect(
      try await fixture.run(
        runner, targets: ["formula:orphan"], approval: preview.approval()
      ).outcome == "complete")
    let context = fixture.context(
      profile: fixture.base.inventory.root.appending(path: "new/inputs/profile.toml"))
    let next = try await fixture.run(runner, targets: ["formula:orphan"], context: context)
    #expect(next.outcome == "preview", "\(next.json)")
    #expect(
      !FileManager.default.fileExists(atPath: context.profileURL.deletingLastPathComponent().path))
    #expect(
      try await fixture.run(
        runner, targets: ["formula:orphan"], approval: next.approval(),
        context: context
      ).outcome == "complete")
    #expect(try String(contentsOf: context.profileURL, encoding: .utf8).contains("brewfile = "))
    #expect(fixture.base.calls.withLock { $0 } == 0)
  }

  @Test
  func identicalProfilePathsBlockInsteadOfTrapping() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let result = try await fixture.run(
      fixture.runner(), context: fixture.context(profile: fixture.base.context.machineProfileURL))
    #expect(result.outcome == "blocked")
    #expect(!FileManager.default.fileExists(atPath: fixture.base.context.stateRoot.path))
  }

  @Test(arguments: [false, true])
  func caskExclusionsSaveBeforeMixedInstallAndFormulaAdoption(machine: Bool) async throws {
    let fixture = try AdditionFixture(kind: .cask)
    defer { fixture.base.inventory.cleanup() }
    let context = fixture.base.context
    let source = machine ? context.machineProfileURL : context.profileURL
    let original =
      AdditionFixture.profile + """
        exclude_formulae = ['slack', 'orphan'] # same token, different kind
        exclude_casks = ['other', 'homebrew/cask/slack'] # restore only slack

        """
    if machine {
      try fixture.base.inventory.write("schema_version = 1\n", at: context.profileURL)
    }
    try fixture.base.inventory.write(original, at: source)
    let expected = original.replacingOccurrences(of: ", 'orphan'", with: ", ")
      .replacingOccurrences(of: "'homebrew/cask/slack'", with: "")
    let native = fixture.runner()
    let runner = SetupPackageAdditionCommandRunner(
      planner: native.planner,
      provider: .init(apply: { url, record in
        #expect(try String(contentsOf: source, encoding: .utf8) == expected)
        return try native.provider.apply(url, record)
      }))
    let targets = ["cask:homebrew/cask/slack", "formula:orphan"]
    let preview = try await fixture.run(runner, targets: targets, machineOnly: machine)
    #expect(preview.outcome == "preview", "\(preview.json)")
    #expect(
      preview.json["preview"]?["installation"]?["native_effects"]?.array?.compactMap(\.string)
        == [HomebrewBundleInstaller.caskEffects])
    #expect(preview.json["preview"]?["installation"]?["brewfile"]?.string == "cask \"slack\"\n")
    #expect(try String(contentsOf: source, encoding: .utf8) == original)
    #expect(
      try await fixture.run(
        runner, targets: targets, machineOnly: machine, approval: preview.approval()
      ).outcome == "complete")
    #expect(
      try Set(fixture.base.ledger.read()?.entries.map(\.identity.key) ?? []) == [
        "cask:slack", "formula:orphan",
      ])
    #expect(
      try await fixture.run(runner, targets: targets, machineOnly: machine).outcome == "no_change")
    #expect(fixture.base.calls.withLock { $0 } == 1)
  }

  @Test
  func higherPriorityCaskExclusionBlocksPortableAdditionWithoutEdits() async throws {
    let fixture = try AdditionFixture(kind: .cask)
    defer { fixture.base.inventory.cleanup() }
    try fixture.base.inventory.write(
      "schema_version = 1\n[packages]\nexclude_casks = ['homebrew/cask/slack']\n",
      at: fixture.base.context.machineProfileURL)
    let before = try fixture.contents()
    let result = try await fixture.run(fixture.runner())
    #expect(result.outcome == "blocked")
    #expect(result.json["message"]?.string?.contains("Machine intent defeats") == true)
    #expect(try fixture.contents() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.base.context.stateRoot.path))
    #expect(fixture.base.calls.withLock { $0 } == 0)
  }

  @Test
  func unrecordedPostSaveIdentityRequiresManualInspection() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    var runner = fixture.runner()
    runner.checkpoint = { point in
      if case .afterInput(0) = point { throw SetupPackageAdoptionError("interrupted") }
    }
    let preview = try await fixture.run(runner)
    #expect(try await fixture.run(runner, approval: preview.approval()).outcome == "blocked")
    let store = SetupPackageInputPublicationStore(context: fixture.base.context)
    var record = try #require(try store.read())
    // Reproduce the narrow crash window: the source was saved but the durable
    // record is still its pre-save version. Matching text is not inode evidence.
    record.entries[0].savedSnapshot = nil
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    try encoder.encode(record).write(to: store.url)
    #expect(try await fixture.run(runner, targets: [], recover: true).outcome == "blocked")
    #expect(fixture.base.calls.withLock { $0 } == 0)
    #expect(try fixture.contents().contains("brew \"jq\""))
    #expect(try store.read()?.complete == false)
  }
}

private struct AdditionFixture: Sendable {
  let base: InstallationFixture
  static let profile =
    "schema_version = 1\n[packages]\nbaseline = \"personal\"\nbrewfile = \"Brewfile\"\n"
  var fragment: URL { base.inventory.root.appending(path: "Brewfile") }

  init(kind: HomebrewPackageIdentity.Kind = .formula) throws {
    base = try InstallationFixture(kind: kind)
    try base.inventory.write(Self.profile, at: base.context.profileURL)
    try write("# personal\n")
  }
  func write(_ text: String) throws { try base.inventory.write(text, at: fragment) }
  func contents() throws -> String { try String(contentsOf: fragment, encoding: .utf8) }
  func context(profile: URL) -> UnifiedSetupPlanContext {
    let original = base.context
    return .init(
      themesRoot: original.themesRoot, keybindingsResourcesRoot: original.keybindingsResourcesRoot,
      desktopResourcesRoot: original.desktopResourcesRoot,
      environmentResourcesRoot: original.environmentResourcesRoot,
      profileURL: profile, profileRequired: true,
      machineProfileURL: original.machineProfileURL, machineProfileRequired: false,
      stateRoot: original.stateRoot, homeDirectory: original.homeDirectory)
  }
  func runner(status: Int32 = 0) -> SetupPackageAdditionCommandRunner {
    let native = base.runner(status: status)
    return .init(
      planner: native.planner,
      provider: .init(apply: { url, record in
        #expect(try self.contents().contains(self.base.brewfile))
        return try native.provider.apply(url, record)
      }))
  }
  func run(
    _ runner: SetupPackageAdditionCommandRunner, targets: [String]? = nil,
    machineOnly: Bool = false, approval: String? = nil, recover: Bool = false,
    context: UnifiedSetupPlanContext? = nil
  ) async throws -> InstallationFixture.Result {
    let result = try await runner.execute(
      context: context ?? base.context, targets: targets ?? [base.target.key],
      machineOnly: machineOnly, approval: approval, recover: recover, json: true)
    return try .init(
      json: JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8)),
      succeeded: result.succeeded)
  }
}
