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
      report["daily_tools"] as? [String: String]
        == ["bat": "enabled", "btop": "enabled", "eza": "enabled", "yazi": "enabled"]
    )
    #expect(
      (report["rendered_artifacts"] as? [String: String])?.keys.sorted()
        == [
          "atuin/config.toml", "bat/config", "btop/btop.conf", "kitty/kitty.conf",
          "starship/behavior.toml", "yazi/theme.toml", "yazi/yazi.toml", "zsh/.zshrc",
        ]
    )
    #expect(
      (report["actions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        == [
          "publish_environment_generation", "configure_kitty", "configure_zsh",
          "configure_starship", "configure_atuin", "configure_bat", "configure_eza",
          "configure_btop", "configure_yazi",
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
    [tools]
    bat = false
    eza = false
    btop = false
    yazi = false
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
  func exactExternalDailyToolSeamsRemainUnowned() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let files: [(String, String)] = [
      (
        ".config/bat/config",
        try String(contentsOf: resourcesRoot.appending(path: "bat/config"), encoding: .utf8)
      ),
      (
        ".config/btop/btop.conf",
        try String(contentsOf: resourcesRoot.appending(path: "btop/btop.conf"), encoding: .utf8)
      ),
      (
        ".config/yazi/yazi.toml",
        try String(contentsOf: resourcesRoot.appending(path: "yazi/yazi.toml"), encoding: .utf8)
      ),
      (
        ".config/yazi/theme.toml",
        try String(contentsOf: resourcesRoot.appending(path: "yazi/theme.toml"), encoding: .utf8)
      ),
    ]
    for (path, contents) in files {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    let links = [
      (".config/bat/themes/Macarchy Current.tmTheme", "current/generated/bat.tmTheme"),
      (".config/eza/theme.yml", "current/generated/eza.yml"),
      (".config/btop/themes/macarchy-current.theme", "current/generated/btop.theme"),
      (
        ".config/yazi/flavors/macarchy-current.yazi/flavor.toml",
        "current/generated/yazi-flavor.toml"
      ),
      (
        ".config/yazi/flavors/macarchy-current.yazi/tmtheme.xml",
        "current/generated/yazi.tmTheme"
      ),
    ]
    for (path, destination) in links {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        at: url,
        withDestinationURL: state.appending(path: destination)
      )
    }

    let execution = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
    let report = try jsonObject(execution.output)
    let toolIDs = Set([
      "bat_configuration", "bat_theme", "btop_configuration", "btop_theme", "eza_theme",
      "yazi_configuration", "yazi_theme_selection", "yazi_flavor", "yazi_syntax",
    ])
    let entries = try #require(report["entries"] as? [[String: Any]]).filter {
      ($0["id"] as? String).map(toolIDs.contains) == true
    }

    #expect(execution.succeeded)
    #expect(entries.count == 9)
    #expect(
      entries.allSatisfy {
        $0["status"] as? String == "external"
          && $0["ownership"] as? String == "external_exact"
      }
    )
    #expect(report["adoption_evidence_digest"] == nil)
  }

  @Test
  func differingSeamBelowExternalProviderRootIsUnsupported() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let dotfiles = root.appending(path: "dotfiles-eza", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: ".config/eza"),
      withDestinationURL: dotfiles
    )

    let execution = try runner.execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: root.appending(path: "state"),
      homeDirectory: home,
      json: true
    )
    let report = try jsonObject(execution.output)
    let entries = try #require(report["entries"] as? [[String: Any]])

    #expect(!execution.succeeded)
    #expect(
      entries.contains {
        $0["id"] as? String == "eza_theme" && $0["status"] as? String == "unsupported"
      }
    )
  }

  @Test
  func malformedToolConfigurationsBlockProviderAdoption() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let configuration = home.appending(path: ".config/yazi/theme.toml")
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "[flavor\ndark = \"macarchy-current\"\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )

    let execution = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: root.appending(path: "state"),
      homeDirectory: home,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains("theme.toml"))

    try FileManager.default.removeItem(at: configuration)
    let btop = home.appending(path: ".config/btop/btop.conf")
    try FileManager.default.createDirectory(
      at: btop.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    color_theme = "first"
    color_theme = "second"
    """.write(to: btop, atomically: true, encoding: .utf8)
    let duplicateBtop = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: root.appending(path: "state"),
      homeDirectory: home,
      json: true
    )
    #expect(!duplicateBtop.succeeded)
    #expect(duplicateBtop.output.contains("duplicate btop key color_theme"))
  }

  @Test
  func ezaRequiresAnExternalConfigurationDirectoryWhenZshIsDisabled() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let profile = root.appending(path: "profile.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try """
    schema_version = 1
    [shell]
    provider = "disabled"
    """.write(to: profile, atomically: true, encoding: .utf8)

    let blocked = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
    let blockedEntries = try #require(
      try jsonObject(blocked.output)["entries"] as? [[String: Any]]
    )
    #expect(!blocked.succeeded)
    #expect(
      blockedEntries.contains {
        $0["id"] as? String == "eza_environment"
          && $0["status"] as? String == "unsupported"
      }
    )

    try "export EZA_CONFIG_DIR=\"$HOME/.config/eza\"\n".write(
      to: home.appending(path: ".zshrc"),
      atomically: true,
      encoding: .utf8
    )
    let ready = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
    let readyEntries = try #require(try jsonObject(ready.output)["entries"] as? [[String: Any]])
    #expect(ready.succeeded)
    #expect(
      readyEntries.contains {
        $0["id"] as? String == "eza_environment"
          && $0["status"] as? String == "external"
      }
    )
  }

  @Test
  func aggregateLifecycleRejectsLegacyToolOwnership() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let context = SetupOwnershipManager.Context(homeDirectory: home)
    try FileManager.default.createDirectory(
      at: context.stateRoot,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: context.batConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "--style=plain\n".write(
      to: context.batConfiguration,
      atomically: true,
      encoding: .utf8
    )
    var records = [SetupOwnershipRecord]()
    _ = try SetupOwnershipManager().setupBatSelector(
      context: context,
      dryRun: false,
      records: &records
    )

    let execution = try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: context.stateRoot,
      homeDirectory: home,
      json: true
    )

    #expect(!execution.succeeded)
    #expect(execution.output.contains(SetupOwnershipManager.batSelectorID))
    #expect(execution.output.contains("legacy setup ownership"))
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

  @Test
  func livePlanRequiresTheCanonicalThemeNeededByApply() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let execution = try EnvironmentPlanCommandRunner(
      prerequisites: .assumed,
      requiresActiveTheme: true
    ).execute(
      resourcesRoot: resourcesRoot,
      profileURL: root.appending(path: "missing-profile.toml"),
      profileRequired: false,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
    let report = try jsonObject(execution.output)

    #expect(!execution.succeeded)
    #expect(report["outcome"] as? String == "blocked")
    #expect(
      (report["diagnostics"] as? [[String: Any]])?.contains {
        $0["code"] as? String == "active_theme_required"
      } == true
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
