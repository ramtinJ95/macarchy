import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentNativeSeedTests {
  @Test(arguments: ["create", "symlink", "ancestor"])
  func reviewedParentCreationIsOneOrdinaryDirectory(operation: String) throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.root.appending(path: "new-user-directory")
    var seed = EnvironmentNativeSeed(
      provider: operation == "ancestor" ? .neovim : .zsh,
      destination: operation == "ancestor" ? fixture.home : parent.appending(path: "zshrc"),
      homeDirectory: fixture.home, stateRoot: fixture.state,
      resourcesRoot: repositoryRoot.appending(path: "Environment"), createParentDirectory: true)
    if operation == "ancestor" {
      #expect(throws: (any Error).self) { try seed.plan() }
      return
    }
    seed.createParentDirectory = false
    #expect(throws: (any Error).self) { try seed.plan() }
    seed.createParentDirectory = true
    let preview = try seed.plan()
    #expect(preview.parentDirectory == parent.path)
    #expect(!FileManager.default.fileExists(atPath: parent.path))
    if operation == "symlink" {
      try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.root)
      #expect(throws: (any Error).self) { try seed.seed(approval: preview.approval) }
      #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "zshrc").path))
      return
    }
    _ = try seed.seed(approval: preview.approval)
    let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(try String(contentsOf: seed.destination, encoding: .utf8) == preview.contents)
  }

  @Test(arguments: EnvironmentNativeSeed.Provider.allCases.filter { $0 != .neovim })
  func previewSeedConnectEditReapplyAndTeardown(_ provider: EnvironmentNativeSeed.Provider)
    async throws
  {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    if provider == .starship { try fixture.activateTheme() }
    let destination = fixture.root.appending(path: "personal-\(provider.rawValue).conf")
    let seed = EnvironmentNativeSeed(
      provider: provider, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
    let plan = try seed.plan()
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(throws: (any Error).self) { try seed.seed(approval: "stale") }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    _ = try seed.seed(approval: plan.approval)
    #expect(try String(contentsOf: destination, encoding: .utf8) == plan.contents)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: (any Error).self) { try seed.seed(approval: plan.approval) }
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
    try
      (original
      + "\n[\(provider.rawValue)]\n\(provider.profileKey) = \"\(destination.lastPathComponent)\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    let environmentPlan = try jsonObject(fixture.plan().output)
    let adoption = try #require(environmentPlan["adoption_evidence_digest"] as? String)
    let applied = try await fixture.apply(adopt: adoption)
    #expect(applied.succeeded, "\(applied.output)")
    if provider == .zsh || provider == .kitty {
      let defaultsPath = provider == .zsh ? "zsh/defaults.zsh" : "kitty/defaults.conf"
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.state.appending(path: "environment/current/\(defaultsPath)").path))
    }
    let edited: String
    switch provider {
    case .zsh: edited = plan.contents + "export PERSONAL=edited\n"
    case .kitty: edited = plan.contents + "font_size 19\n"
    case .atuin: edited = "inline_height = 17\n" + plan.contents
    case .starship: edited = "command_timeout = 1250\n" + plan.contents
    case .neovim: throw EnvironmentLifecycleError.blocked("directory provider has a separate test")
    }
    try edited.write(to: destination, atomically: true, encoding: .utf8)
    let repeated = try await fixture.apply(adopt: nil)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: destination, encoding: .utf8) == edited)
  }

  @Test
  func neovimStarterConnectsWithoutPluginRestoreAndPreservesEdits() async throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let destination = fixture.root.appending(path: "personal-neovim")
    let seed = EnvironmentNativeSeed(
      provider: .neovim, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
    let preview = try seed.plan()
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(throws: (any Error).self) { try seed.seed(approval: "stale") }
    _ = try seed.seed(approval: preview.approval)
    #expect(throws: (any Error).self) { try seed.seed(approval: preview.approval) }
    for path in EnvironmentNeovimMigration.themePaths {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: destination.appending(path: path).path)
          == fixture.state.appending(path: "environment/current/neovim/\(path)").path)
    }
    for path in ["lua", "lua/config", "lua/plugins"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: destination.appending(path: path).path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    let original = try String(contentsOf: fixture.profile, encoding: .utf8)
      .replacingOccurrences(
        of: "[editor]\nprovider = \"disabled\"", with: "[editor]\nprovider = \"neovim\"")
    try (original + "\n[neovim]\nnative_configuration = \"personal-neovim\"\n")
      .write(to: fixture.profile, atomically: true, encoding: .utf8)
    let report = try jsonObject(fixture.plan().output)
    let applied = try await fixture.apply(
      adopt: #require(report["adoption_evidence_digest"] as? String))
    #expect(applied.succeeded, "\(applied.output)")
    let lock = destination.appending(path: "lazy-lock.json")
    let edited = "{\"personal\":{\"commit\":\"kept\"}}\n"
    try edited.write(to: lock, atomically: true, encoding: .utf8)
    let repeated = try await fixture.apply(adopt: nil)
    #expect(repeated.succeeded, "\(repeated.output)")
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: lock, encoding: .utf8) == edited)
  }

  @Test
  func starshipRequiresActivePaletteBeforeSeeding() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let destination = fixture.root.appending(path: "personal-starship.toml")
    let seed = EnvironmentNativeSeed(
      provider: .starship, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state, resourcesRoot: repositoryRoot.appending(path: "Environment"))
    #expect(throws: (any Error).self) { try seed.plan() }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    try fixture.activateTheme()
    let preview = try seed.plan()
    #expect(preview.contents.contains("[palettes.macarchy_current]"))
    #expect(preview.message.contains("starship.native_configuration"))
  }

  @Test(arguments: ["file", "directory", "dangling-link"])
  func neverReplacesExistingDestinations(_ kind: String) throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let destination = fixture.root.appending(path: "starter")
    let seed = EnvironmentNativeSeed(
      provider: .zsh, destination: destination, homeDirectory: fixture.home,
      stateRoot: fixture.state)
    let preview = try seed.plan()
    switch kind {
    case "file": try Data("personal".utf8).write(to: destination)
    case "directory":
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    default:
      try FileManager.default.createSymbolicLink(
        atPath: destination.path, withDestinationPath: "missing")
    }
    let inspector = EnvironmentProviderInspector()
    let before = try kind == "directory" ? nil : inspector.capture(destination, directoryLink: nil)
    #expect(throws: (any Error).self) { try seed.seed(approval: preview.approval) }
    if let before {
      #expect(try inspector.capture(destination, directoryLink: nil) == before)
    } else {
      #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
  }

  @Test(arguments: [
    ".zshrc", ".config/kitty/personal.conf", ".config/macarchy/personal.zsh",
    ".config/nvim/personal.zsh", ".config/atuin/config.toml", ".config/starship.toml",
  ])
  func rejectsManagedDestinations(_ path: String) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let seed = EnvironmentNativeSeed(
      provider: .zsh, destination: fixture.home.appending(path: path),
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) { try seed.plan() }
  }

  @Test
  func rejectsAliasIntoManagedDestination() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let managed = fixture.home.appending(path: ".config/kitty")
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let alias = fixture.root.appending(path: "kitty-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
    let seed = EnvironmentNativeSeed(
      provider: .kitty, destination: alias.appending(path: "personal.conf"),
      homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(throws: (any Error).self) { try seed.plan() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).isEmpty)
  }

}
