import Foundation
import Testing

@testable import ThemeCore

struct EnvironmentConfigurationTests {
  private let composer = EnvironmentConfigurationComposer()

  @Test
  func packagedDefaultsComposeDeterministicTerminalSession() throws {
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: URL(filePath: "/fixtures/profile.toml")
    )
    let stateRoot = URL(filePath: "/fixtures/state")

    let first = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: stateRoot
    )
    let second = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: stateRoot
    )

    #expect(first == second)
    #expect(
      first.artifacts.map(\.path) == [
        "atuin/config.toml", "kitty/kitty.conf", "starship/behavior.toml", "zsh/.zshrc",
      ]
    )
    #expect(artifact("kitty/kitty.conf", in: first).contains("state/adapters/kitty.conf"))
    #expect(!artifact("kitty/kitty.conf", in: first).contains("allow_remote_control"))
    let zsh = artifact("zsh/.zshrc", in: first)
    let atuinInit = try #require(zsh.range(of: "atuin init zsh"))
    let starshipInit = try #require(zsh.range(of: "starship init zsh"))
    #expect(atuinInit.lowerBound < starshipInit.lowerBound)
    #expect(artifact("atuin/config.toml", in: first).contains("name = \"macarchy-current\""))
    #expect(first.renderedDigest.hasPrefix("sha256:"))
    #expect(first.inputDigest.hasPrefix("sha256:"))
  }

  @Test
  func providerInitCommandFailureStopsTheManagedShellMarker() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let atuin = bin.appending(path: "atuin")
    try "#!/bin/sh\nexit 17\n".write(to: atuin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: atuin.path)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: root.appending(path: "state")
    )
    try artifact("zsh/.zshrc", in: composition).write(
      to: home.appending(path: ".zshrc"),
      atomically: true,
      encoding: .utf8
    )
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = [
      "-c",
      "source .zshrc; startup=$?; print -r -- ${MACARCHY_MANAGED_SESSION-unset}; exit $startup",
    ]
    process.currentDirectoryURL = home
    process.environment = [
      "HOME": home.path,
      "PATH": "\(bin.path):/usr/bin:/bin",
      "ZDOTDIR": home.path,
    ]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
    #expect(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        == "unset\n")
  }

  @Test
  func nativeInputsAndStableOptionsProduceSelfContainedArtifacts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kitty = root.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kitty, withIntermediateDirectories: true)
    try "include bindings.conf\nmap cmd+k clear_terminal scroll active\n".write(
      to: kitty.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "map cmd+enter new_window\n".write(
      to: kitty.appending(path: "bindings.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "alias gs='git status'\n".write(
      to: root.appending(path: "zshrc"),
      atomically: true,
      encoding: .utf8
    )
    try "[directory]\nstyle = \"green\"\n".write(
      to: root.appending(path: "starship.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "filter_mode = \"global\"\n\n[daemon]\nenabled = true\nautostart = true\n".write(
      to: root.appending(path: "atuin.toml"),
      atomically: true,
      encoding: .utf8
    )
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [kitty]
      font_size = 15
      override = "kitty"
      [zsh]
      editor = "vim"
      hook = "zshrc"
      [starship]
      behavior = "starship.toml"
      [atuin]
      search_mode = "fulltext"
      enter_accept = false
      daemon = false
      configuration = "atuin.toml"
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: root.appending(path: "state")
    )

    #expect(
      composition.artifacts.map(\.path) == [
        "atuin/config.toml", "kitty/kitty.conf", "kitty/override/bindings.conf",
        "kitty/override/kitty.conf", "starship/behavior.toml", "zsh/.zshrc",
      ]
    )
    #expect(artifact("kitty/kitty.conf", in: composition).contains("font_size 15.0"))
    #expect(artifact("kitty/kitty.conf", in: composition).contains("include override/kitty.conf"))
    #expect(artifact("zsh/.zshrc", in: composition).contains("export EDITOR=\"vim\""))
    #expect(artifact("zsh/.zshrc", in: composition).hasSuffix("alias gs='git status'\n"))
    #expect(artifact("starship/behavior.toml", in: composition).contains("style = \"green\""))
    let atuin = artifact("atuin/config.toml", in: composition)
    #expect(atuin.contains("search_mode = \"fulltext\""))
    #expect(atuin.contains("enter_accept = false"))
    #expect(atuin.contains("enabled = false"))
    #expect(atuin.contains("autostart = false"))
    #expect(composition.zshHookDigest?.hasPrefix("sha256:") == true)
  }

  @Test
  func providerOwnedThemeAndUnsafeKittyIncludesFailClosed() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try "palette = \"personal\"\n".write(
      to: root.appending(path: "starship.toml"),
      atomically: true,
      encoding: .utf8
    )
    let starship = try PortableProfileLoader().decode(
      "schema_version = 1\n[starship]\nbehavior = \"starship.toml\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: starship, stateRoot: root)
    }

    try "[theme]\nname = \"personal\"\n".write(
      to: root.appending(path: "atuin.toml"),
      atomically: true,
      encoding: .utf8
    )
    let atuin = try PortableProfileLoader().decode(
      "schema_version = 1\n[atuin]\nconfiguration = \"atuin.toml\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: atuin, stateRoot: root)
    }

    let kittyDirectory = root.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kittyDirectory, withIntermediateDirectories: true)
    try "include ../outside.conf\n".write(
      to: kittyDirectory.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    let kitty = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\noverride = \"kitty\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: kitty, stateRoot: root)
    }
  }

  @Test
  func kittyOverridesRejectGeneratedIncludesAndSymbolicLinkRoots() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kittyDirectory = root.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kittyDirectory, withIntermediateDirectories: true)
    try "geninclude\t/bin/echo unsafe\n".write(
      to: kittyDirectory.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    let generatedInclude = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\noverride = \"kitty\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(
        resourcesRoot: resourcesRoot,
        profile: generatedInclude,
        stateRoot: root
      )
    }

    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "kitty-link"),
      withDestinationURL: kittyDirectory
    )
    let symbolicLink = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\noverride = \"kitty-link\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: symbolicLink, stateRoot: root)
    }
  }

  @Test
  func atuinOptionsRespectTableBoundariesAndDaemonRequirements() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let atuin = root.appending(path: "atuin.toml")
    try """
    filter_mode = "global"

    [daemon] # retained comment
    enabled = true

    [[unrelated]]
    enabled = true
    search_mode = "prefix"
    """.write(to: atuin, atomically: true, encoding: .utf8)
    let valid = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [atuin]
      search_mode = "fulltext"
      daemon = false
      configuration = "atuin.toml"
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: valid,
      stateRoot: root
    )
    let rendered = artifact("atuin/config.toml", in: composition)
    let rootSearchMode = try #require(rendered.range(of: "search_mode = \"fulltext\""))
    let daemonTable = try #require(rendered.range(of: "[daemon]"))
    #expect(rootSearchMode.lowerBound < daemonTable.lowerBound)
    #expect(rendered.contains("[daemon] # retained comment\nenabled = false"))
    #expect(rendered.contains("autostart = false"))
    #expect(rendered.contains("[[unrelated]]\nenabled = true\nsearch_mode = \"prefix\""))

    let incompatible = try PortableProfileLoader().decode(
      "schema_version = 1\n[atuin]\ndaemon = false\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: incompatible, stateRoot: root)
    }

    try "search_mode = \"daemon-fuzzy\"\n".write(
      to: atuin,
      atomically: true,
      encoding: .utf8
    )
    let omittedDaemon = try PortableProfileLoader().decode(
      "schema_version = 1\n[atuin]\nconfiguration = \"atuin.toml\"\n",
      source: root.appending(path: "profile.toml")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(
        resourcesRoot: resourcesRoot,
        profile: omittedDaemon,
        stateRoot: root
      )
    }
  }

  @Test
  func nativeInputReadRejectsRetargetedIntermediateSymbolicLink() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileDirectory = root.appending(path: "profile", directoryHint: .isDirectory)
    let inside = profileDirectory.appending(path: "inside", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "echo inside\n".write(
      to: inside.appending(path: "hook.zsh"),
      atomically: true,
      encoding: .utf8
    )
    try "echo outside\n".write(
      to: outside.appending(path: "hook.zsh"),
      atomically: true,
      encoding: .utf8
    )
    let link = profileDirectory.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nhook = \"linked/hook.zsh\"\n",
      source: profileDirectory.appending(path: "profile.toml")
    )
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
  }

  @Test
  func kittyOverrideReadRejectsRetargetedIntermediateSymbolicLink() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileDirectory = root.appending(path: "profile", directoryHint: .isDirectory)
    let inside = profileDirectory.appending(path: "inside", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "font_size 14\n".write(
      to: inside.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "allow_remote_control yes\n".write(
      to: outside.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    let link = profileDirectory.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\noverride = \"linked\"\n",
      source: profileDirectory.appending(path: "profile.toml")
    )
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
  }

  @Test
  func kittyOverrideEntryLimitAppliesAcrossNestedDirectories() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kitty = root.appending(path: "kitty", directoryHint: .isDirectory)
    let nested = kitty.appending(path: "a", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 0..<126 {
      try "".write(
        to: nested.appending(path: "\(index).conf"),
        atomically: true,
        encoding: .utf8
      )
    }
    try "".write(
      to: kitty.appending(path: "kitty.conf"),
      atomically: true,
      encoding: .utf8
    )
    try "".write(
      to: kitty.appending(path: "z.conf"),
      atomically: true,
      encoding: .utf8
    )
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\noverride = \"kitty\"\n",
      source: root.appending(path: "profile.toml")
    )

    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
  }

  private var resourcesRoot: URL {
    repositoryRoot.appending(path: "Environment", directoryHint: .isDirectory)
  }

  private func artifact(_ path: String, in composition: EnvironmentComposition) -> String {
    composition.artifacts.first { $0.path == path }!.contents
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-environment-configuration-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
