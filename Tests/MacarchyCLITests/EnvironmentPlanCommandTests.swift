import Foundation
import Testing

@testable import MacarchyCLI

struct EnvironmentPlanCommandTests {
  private let runner = EnvironmentPlanCommandRunner()

  @Test
  func absentProfilePlansCompleteDefaultSessionWithoutMutation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appending(path: "missing-profile.toml")
    let state = root.appending(path: "state", directoryHint: .isDirectory)

    let execution = try runner.execute(
      resourcesRoot: resourcesRoot,
      profileURL: profile,
      profileRequired: false,
      stateRoot: state,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect(report["operation"] as? String == "environment_plan")
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(report["terminal_provider"] as? String == "kitty")
    #expect(report["shell_provider"] as? String == "zsh")
    #expect(report["prompt_provider"] as? String == "starship")
    #expect(report["history_provider"] as? String == "atuin")
    #expect(
      (report["rendered_artifacts"] as? [String: String])?.keys.sorted()
        == ["atuin/config.toml", "kitty/kitty.conf", "starship/behavior.toml", "zsh/.zshrc"]
    )
    #expect(
      (report["actions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        == [
          "publish_environment_generation", "configure_kitty", "configure_zsh",
          "configure_starship", "configure_atuin",
        ]
    )
    #expect(!FileManager.default.fileExists(atPath: state.path))
  }

  @Test
  func disabledSessionHasNoArtifactsSourcesOrActions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appending(path: "profile.toml")
    try """
    schema_version = 1
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    """.write(to: profile, atomically: true, encoding: .utf8)

    let execution = try runner.execute(
      resourcesRoot: resourcesRoot,
      profileURL: profile,
      profileRequired: true,
      stateRoot: root.appending(path: "state"),
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(execution.succeeded)
    #expect((report["rendered_artifacts"] as? [String: String])?.isEmpty == true)
    #expect((report["actions"] as? [Any])?.isEmpty == true)
    #expect(report["starship_behavior"] == nil)
    #expect(report["atuin_configuration"] == nil)
  }

  @Test
  func invalidNativeBehaviorBlocksBeforeActionsOrMutation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try "palette = \"personal\"\n".write(
      to: root.appending(path: "starship.toml"),
      atomically: true,
      encoding: .utf8
    )
    let profile = root.appending(path: "profile.toml")
    try "schema_version = 1\n[starship]\nbehavior = \"starship.toml\"\n".write(
      to: profile,
      atomically: true,
      encoding: .utf8
    )
    let state = root.appending(path: "state")

    let execution = try runner.execute(
      resourcesRoot: resourcesRoot,
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect((report["actions"] as? [Any])?.isEmpty == true)
    #expect(
      (report["diagnostics"] as? [[String: Any]])?.first?["code"] as? String
        == "environment_configuration_invalid"
    )
    #expect(!FileManager.default.fileExists(atPath: state.path))
  }

  private var resourcesRoot: URL {
    repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory)
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-plan-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
