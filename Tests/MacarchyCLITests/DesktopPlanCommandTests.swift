import Foundation
import Testing

@testable import MacarchyCLI

struct DesktopPlanCommandTests {
  private let runner = DesktopPlanCommandRunner()

  @Test
  func cleanDefaultPlansManagedYabaiWithoutMutation() throws {
    let fixture = try planFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let execution = try execute(fixture, json: true, profileRequired: false)
    let report = try jsonObject(execution.output)
    let provider = try #require(report["provider"] as? [String: Any])
    let actions = try #require(report["actions"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(report["desktop_provider"] as? String == "yabai-skhd")
    #expect(report["top_bar_provider"] as? String == "sketchybar")
    #expect(provider["status"] as? String == "install_required")
    #expect(
      actions.compactMap { $0["id"] as? String }
        == ["publish_yabai_generation", "install_yabai_entry", "restart_yabai_service"]
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
    #expect(actions.dropLast().last?["id"] as? String == "adopt_yabai_directory_symlink")
    #expect(actions.last?["id"] as? String == "restart_yabai_service")
  }

  @Test
  func unsafeDirectoryInventoryBlocksManagedButDisabledPreservesIt() throws {
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
    #expect(disabled.succeeded)
    #expect(disabledReport["outcome"] as? String == "no_change")
    #expect(disabledReport["rendered_yabairc"] == nil)
    #expect(provider["status"] as? String == "externally_managed")
    #expect((disabledReport["actions"] as? [Any])?.isEmpty == true)
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

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
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
