import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageAdditionTests {
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
    #expect(preview.json["preview"]?["edit"]?["before"]?.string == original)
    #expect(preview.json["preview"]?["installation"]?["brewfile"]?.string == "brew \"jq\"\n")
    #expect(preview.json["preview"]?["adoption"]?.array?.count == 1)
    #expect(preview.json["preview"]?["installation"]?["ledger"] == nil)
    #expect(preview.json["preview"]?["edit"]?["snapshot"] == nil)
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

  @Test
  func installedPackageUsesAdoptionWithoutNativePreflightOrUpgrade() async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    let runner = SetupPackageAdditionCommandRunner(
      planner: fixture.base.runner().planner,
      provider: .init(
        preflight: { throw SetupPackageAdoptionError("must not preflight") },
        apply: { _, _ in throw SetupPackageAdoptionError("must not install") }))
    let preview = try await fixture.run(runner, targets: ["formula:orphan"])
    #expect(preview.outcome == "preview")
    #expect(
      try await fixture.run(runner, targets: ["formula:orphan"], approval: preview.approval())
        .outcome == "complete")
  }

  @Test(arguments: ["bytes", "same-bytes-inode", "profile", "mode", "receipt", "late", "wrong"])
  func staleApprovalDoesNotEditOrInstall(change: String) async throws {
    let fixture = try AdditionFixture()
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

  @Test(arguments: ["native", "after-save"])
  func failureRetainsIntentAndRetryAdoptsOrInstallsOnlyPendingTargets(failure: String) async throws
  {
    let fixture = try AdditionFixture()
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
    #expect(try fixture.contents() == "# personal\nbrew \"jq\"\n")
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
    "missing-profile", "missing-wiring", "missing-fragment", "unsupported", "selected-exclusion",
    "machine-exclusion", "shared", "hard-link", "residue", "cask", "tap", "preflight",
  ])
  func unsupportedInputsStopWithoutSaving(mode: String) async throws {
    let fixture = try AdditionFixture()
    defer { fixture.base.inventory.cleanup() }
    var targets = ["formula:jq"]
    var runner = fixture.runner()
    switch mode {
    case "missing-profile": try FileManager.default.removeItem(at: fixture.base.context.profileURL)
    case "missing-wiring":
      try fixture.base.inventory.write("schema_version = 1\n", at: fixture.base.context.profileURL)
    case "missing-fragment": try FileManager.default.removeItem(at: fixture.fragment)
    case "unsupported": try fixture.write("brew ENV['PACKAGE']\n")
    case "selected-exclusion":
      try fixture.base.inventory.write(
        AdditionFixture.profile + "exclude_formulae = [\"jq\"]\n",
        at: fixture.base.context.profileURL)
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
    case "cask": targets = ["cask:slack"]
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
    #expect(preview.json["preview"]?["edit"]?["path"]?.string == fragment.standardizedFileURL.path)
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
}

private struct AdditionFixture: Sendable {
  let base: InstallationFixture
  static let profile =
    "schema_version = 1\n[packages]\nbaseline = \"personal\"\nbrewfile = \"Brewfile\"\n"
  var fragment: URL { base.inventory.root.appending(path: "Brewfile") }

  init() throws {
    base = try InstallationFixture()
    try base.inventory.write(Self.profile, at: base.context.profileURL)
    try write("# personal\n")
  }
  func write(_ text: String) throws { try base.inventory.write(text, at: fragment) }
  func contents() throws -> String { try String(contentsOf: fragment, encoding: .utf8) }
  func runner(status: Int32 = 0) -> SetupPackageAdditionCommandRunner {
    let native = base.runner(status: status)
    return .init(
      planner: native.planner,
      provider: .init(apply: { url, record in
        #expect(try self.contents().contains("brew \"jq\""))
        return try native.provider.apply(url, record)
      }))
  }
  func run(
    _ runner: SetupPackageAdditionCommandRunner, targets: [String] = ["formula:jq"],
    machineOnly: Bool = false, approval: String? = nil
  ) async throws -> InstallationFixture.Result {
    let result = try await runner.execute(
      context: base.context, targets: targets,
      machineOnly: machineOnly, approval: approval, json: true)
    return try .init(
      json: JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8)),
      succeeded: result.succeeded)
  }
}
