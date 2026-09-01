import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct DesktopPlanCommandTests {
  private let runner = DesktopPlanCommandRunner()

  @Test
  func cleanDefaultPlansManagedYabaiWithoutMutation() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let provider = try #require(report["provider"] as? [String: Any])
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let sketchyBarProvider = try #require(sketchyBar["provider"] as? [String: Any])
    let actions = try #require(report["actions"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(report["desktop_provider"] as? String == "yabai-skhd")
    #expect(report["top_bar_provider"] as? String == "sketchybar")
    #expect(provider["status"] as? String == "install_required")
    #expect(sketchyBarProvider["status"] as? String == "install_required")
    #expect(sketchyBar["space_module"] as? String == "dynamic_yabai")
    #expect(
      (sketchyBar["theme_palette"] as? [String: Any])?["status"] as? String
        == "unavailable"
    )
    #expect(
      (sketchyBar["rendered_artifacts"] as? [String: String])?.keys.sorted()
        == ["plugins/clock.sh", "plugins/space-indexes.sh", "sketchybarrc"]
    )
    #expect(
      actions.compactMap { $0["id"] as? String }
        == [
          "publish_yabai_generation", "install_yabai_entry", "restart_yabai_service",
          "activate_sketchybar_theme_palette", "publish_sketchybar_generation",
          "install_sketchybar_entry", "reload_sketchybar_service",
        ]
    )
    #expect((report["rendered_yabairc"] as? String)?.contains("layout bsp") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config").path))
  }

  @Test
  func boundedDirectorySymlinkRequiresExplicitAdoption() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let dotfiles = fixture.root.appending(path: "dotfiles-yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try "existing\n".write(
      to: dotfiles.appending(path: "yabairc"),
      atomically: true,
      encoding: .utf8
    )
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: configuration.appending(path: "yabai", directoryHint: .isDirectory),
      withDestinationURL: dotfiles
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let provider = try #require(report["provider"] as? [String: Any])
    let actions = try #require(report["actions"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(provider["status"] as? String == "adoption_required")
    #expect(provider["ownership"] as? String == "directory_symlink")
    #expect(provider["source"] as? String == dotfiles.appending(path: "yabairc").path)
    #expect((provider["adoption_evidence_digest"] as? String)?.hasPrefix("sha256:") == true)
    #expect(
      actions.compactMap { $0["id"] as? String }.contains("adopt_yabai_directory_symlink")
    )
    #expect(actions.compactMap { $0["id"] as? String }.contains("restart_yabai_service"))
  }

  @Test
  func disabledDesktopPreservesExternalYabaiAndPlansTheStandaloneBar() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let dotfiles = fixture.root.appending(path: "dotfiles-yabai", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try "existing\n".write(
      to: dotfiles.appending(path: "yabairc"),
      atomically: true,
      encoding: .utf8
    )
    try "personal\n".write(
      to: dotfiles.appending(path: "extra.sh"),
      atomically: true,
      encoding: .utf8
    )
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: configuration.appending(path: "yabai", directoryHint: .isDirectory),
      withDestinationURL: dotfiles
    )

    let blocked = try execute(fixture, json: true, profileRequired: false)
    let blockedReport = try jsonObject(blocked.output)
    #expect(!blocked.succeeded)
    #expect(blockedReport["outcome"] as? String == "blocked")
    #expect((blockedReport["actions"] as? [Any])?.isEmpty == true)

    try """
    schema_version = 1
    [desktop]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let disabled = try execute(fixture, json: true, profileRequired: true)
    let disabledReport = try jsonObject(disabled.output)
    let provider = try #require(disabledReport["provider"] as? [String: Any])
    let sketchyBar = try #require(disabledReport["sketchybar"] as? [String: Any])
    #expect(disabled.succeeded)
    #expect(disabledReport["outcome"] as? String == "ready")
    #expect(disabledReport["rendered_yabairc"] == nil)
    #expect(provider["status"] as? String == "externally_managed")
    #expect(
      sketchyBar["space_module"] as? String
        == "disabled_without_supported_desktop"
    )
    #expect(
      (disabledReport["actions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        == [
          "activate_sketchybar_theme_palette", "publish_sketchybar_generation",
          "install_sketchybar_entry", "reload_sketchybar_service",
        ]
    )
  }

  @Test
  func sketchyBarDirectorySymlinkRequiresExplicitAdoptionWithoutReadingNestedCode() throws {
    let fixture = try planFixture()
    let dotfiles = fixture.root.appending(path: "dotfiles-sketchybar", directoryHint: .isDirectory)
    let nested = dotfiles.appending(path: "items", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: nested.path
      )
      try? FileManager.default.removeItem(at: fixture.root)
    }
    try FileManager.default.createDirectory(
      at: nested,
      withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(
      to: dotfiles.appending(path: "sketchybarrc"),
      atomically: true,
      encoding: .utf8
    )
    try "uninspected nested code\n".write(
      to: dotfiles.appending(path: "items/personal.sh"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: configuration.appending(path: "sketchybar", directoryHint: .isDirectory),
      withDestinationURL: dotfiles
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])
    let actionIDs = try #require(report["actions"] as? [[String: Any]])
      .compactMap { $0["id"] as? String }

    #expect(execution.succeeded)
    #expect(provider["status"] as? String == "adoption_required")
    #expect(provider["ownership"] as? String == "directory_symlink")
    #expect(provider["source"] as? String == dotfiles.appending(path: "sketchybarrc").path)
    #expect((provider["adoption_evidence_digest"] as? String)?.hasPrefix("sha256:") == true)
    #expect(actionIDs.contains("adopt_sketchybar_directory_symlink"))
  }

  @Test
  func disabledTopBarPreservesExternalConfigurationAndPlansNoBarActions() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try "external\n".write(
      to: configuration.appending(path: "sketchybarrc"),
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])
    let actionIDs = try #require(report["actions"] as? [[String: Any]])
      .compactMap { $0["id"] as? String }

    #expect(execution.succeeded)
    #expect(provider["status"] as? String == "externally_managed")
    #expect(sketchyBar["rendered_artifacts"] == nil)
    #expect(!actionIDs.contains { $0.contains("sketchybar") })
  }

  @Test
  func managedSketchyBarLinkWithoutOwnershipBlocksExplicitly() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: configuration.appending(path: "sketchybarrc").path,
      withDestinationPath: SketchyBarProviderPlanInspector.managedTarget(
        homeDirectory: fixture.home,
        stateRoot: fixture.home.appending(
          path: ".config/macarchy",
          directoryHint: .isDirectory
        )
      )
    )
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])

    #expect(!execution.succeeded)
    #expect(provider["status"] as? String == "blocked")
    #expect(provider["ownership"] as? String == "managed_target_without_ownership")
    #expect((report["actions"] as? [Any])?.isEmpty == true)
  }

  @Test
  func ownedSketchyBarEntryWithGenerationDriftBlocksExplicitly() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = fixture.home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    _ = try SketchyBarProviderTransaction(
      homeDirectory: fixture.home,
      stateRoot: state,
      lifecycle: sketchyBarLifecycle,
      coreRuntime: sketchyBarCoreRuntime
    ).convergeLocked(
      composition: try sketchyBarComposition(fixture, stateRoot: state),
      adoptionEvidenceDigest: nil
    )
    let current = state.appending(path: "desktop/sketchybar/current")
    try FileManager.default.removeItem(at: current)
    try FileManager.default.createSymbolicLink(
      atPath: current.path,
      withDestinationPath: "generations/s-00000000-0000-0000-0000-000000000000"
    )

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])

    #expect(!execution.succeeded)
    #expect(provider["status"] as? String == "blocked")
    #expect(provider["ownership"] as? String == "generation_drift")
  }

  @Test
  func ownedSketchyBarEntryRejectsARecordForAnotherPublicPath() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = fixture.home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    _ = try SketchyBarProviderTransaction(
      homeDirectory: fixture.home,
      stateRoot: state,
      lifecycle: sketchyBarLifecycle,
      coreRuntime: sketchyBarCoreRuntime
    ).convergeLocked(
      composition: try sketchyBarComposition(fixture, stateRoot: state),
      adoptionEvidenceDigest: nil
    )
    let ownershipURL = state.appending(path: "desktop/sketchybar/ownership.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: ownershipURL)) as? [String: Any]
    )
    var original = try #require(json["original"] as? [String: Any])
    original["public_path"] = "/tmp/not-this-provider"
    json["original"] = original
    try JSONSerialization.data(withJSONObject: json).write(to: ownershipURL, options: .atomic)

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])

    #expect(!execution.succeeded)
    #expect(provider["status"] as? String == "blocked")
    #expect(provider["ownership"] as? String == "ownership_drift")
  }

  @Test
  func disabledTopBarStillReportsPendingRecovery() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = fixture.home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    let transaction = SketchyBarProviderTransaction(
      homeDirectory: fixture.home,
      stateRoot: state,
      lifecycle: sketchyBarLifecycle,
      coreRuntime: sketchyBarCoreRuntime,
      faultInjector: { checkpoint in
        if checkpoint == .generationPublished { throw SketchyBarInterruptionError.injected }
      }
    )
    #expect(throws: SketchyBarInterruptionError.self) {
      try transaction.convergeLocked(
        composition: try sketchyBarComposition(fixture, stateRoot: state),
        adoptionEvidenceDigest: nil
      )
    }
    try """
    schema_version = 1
    [top_bar]
    provider = "disabled"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(provider["status"] as? String == "recovery_required")
    #expect(diagnostics.contains { $0["code"] as? String == "sketchybar_provider_blocked" })
  }

  @Test
  func multiplyLinkedManagedSketchyBarEntryIsNeverClassifiedAsManaged() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(
      path: ".config/sketchybar",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    let entry = configuration.appending(path: "sketchybarrc")
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: SketchyBarProviderPlanInspector.managedTarget(
        homeDirectory: fixture.home,
        stateRoot: fixture.home.appending(
          path: ".config/macarchy",
          directoryHint: .isDirectory
        )
      )
    )
    let alias = configuration.appending(path: "sketchybarrc-alias")
    let linked = entry.path.withCString { source in
      alias.path.withCString { destination in
        Darwin.linkat(AT_FDCWD, source, AT_FDCWD, destination, 0)
      }
    }
    #expect(linked == 0)

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let sketchyBar = try #require(report["sketchybar"] as? [String: Any])
    let provider = try #require(sketchyBar["provider"] as? [String: Any])

    #expect(!execution.succeeded)
    #expect(provider["status"] as? String == "blocked")
    #expect(provider["ownership"] as? String == "uninspectable")
    var aliasMetadata = stat()
    #expect(lstat(alias.path, &aliasMetadata) == 0)
    #expect(aliasMetadata.st_nlink == 2)
  }

  @Test
  func invalidProfileBlocksWithoutReadingOrExecutingHook() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try """
    schema_version = 1
    [desktop]
    provider = "shell:/tmp/provider"
    """.write(to: fixture.profile, atomically: true, encoding: .utf8)

    let execution = try execute(fixture, json: true, profileRequired: true)
    let report = try jsonObject(execution.output)
    let diagnostics = try #require(report["diagnostics"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect((report["actions"] as? [Any])?.isEmpty == true)
    #expect(diagnostics.map { $0["code"] as? String } == ["profile_invalid"])
  }

  @Test
  func humanPlanIncludesExactBytesAndNoChangeNotice() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let execution = try execute(fixture, json: false, profileRequired: false)

    #expect(execution.succeeded)
    #expect(execution.output.contains("Macarchy desktop plan [ready]:"))
    #expect(execution.output.contains("--- begin exact bytes ---"))
    #expect(execution.output.hasSuffix("No changes made."))
  }

  private func execute(
    _ fixture: PlanFixture,
    json: Bool,
    profileRequired: Bool
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Desktop", directoryHint: .isDirectory),
      profileURL: fixture.profile,
      profileRequired: profileRequired,
      stateRoot: fixture.home.appending(
        path: ".config/macarchy",
        directoryHint: .isDirectory
      ),
      homeDirectory: fixture.home,
      json: json
    )
  }

  private func planFixture() throws -> PlanFixture {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-desktop-plan-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return PlanFixture(
      root: root,
      home: home,
      profile: home.appending(path: "profile.toml")
    )
  }

  private func sketchyBarComposition(
    _ fixture: PlanFixture,
    stateRoot: URL
  ) throws -> SketchyBarComposition {
    let profile = try PortableProfileLoader().load(at: fixture.profile, required: false)
    return try SketchyBarConfigurationComposer().compose(
      defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml"),
      profile: profile,
      stateRoot: stateRoot
    )
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private var sketchyBarLifecycle: SketchyBarLifecycleController {
    let runtime = SketchyBarRuntimeInspection(
      status: .running,
      message: "running",
      processID: 123,
      executablePath: "/opt/homebrew/Cellar/sketchybar/test/bin/sketchybar",
      serviceLabel: SketchyBarHomebrewService.serviceLabel
    )
    return SketchyBarLifecycleController(
      inspect: { runtime },
      preflight: { false },
      reload: { _ in runtime },
      start: { runtime },
      stop: {}
    )
  }

  private var sketchyBarCoreRuntime: SketchyBarCoreRuntimeController {
    let runtime = SketchyBarCoreRuntimeInspection(
      status: .converged,
      message: "converged",
      themeGenerationID: "g-00000000-0000-0000-0000-000000000000",
      barColor: "0xf01e1e2e",
      items: ["macarchy.clock", "macarchy.space.1", "macarchy.theme.ready"],
      spaceIndices: [1],
      clockLabelPresent: true
    )
    return SketchyBarCoreRuntimeController(
      inspect: { _ in runtime },
      settle: { _ in runtime }
    )
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct PlanFixture {
  let root: URL
  let home: URL
  let profile: URL
}
