import Foundation
import Testing

@testable import ThemeCore

struct EnvironmentConfigurationTests {
  private let composer = EnvironmentConfigurationComposer()

  @Test
  func tuicrPresetIsClosedTypedAndDisabledByDefault() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let defaults = try PortableProfileLoader().decode("schema_version = 1\n", source: source)
    let selected = try PortableProfileLoader().decode(
      "schema_version = 1\n[presets]\ntuicr = true\n",
      source: source
    )

    #expect(!defaults.environment.presets.tuicr)
    #expect(selected.environment.presets.tuicr)
    #expect(throws: (any Error).self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[presets]\ntuicr = \"yes\"\n",
        source: source
      )
    }
    #expect(throws: (any Error).self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[presets]\nunknown = true\n",
        source: source
      )
    }
  }

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
        "atuin/config.toml", "bat/config", "btop/btop.conf", "kitty/kitty.conf",
        "neovim/colors/macarchy-imported.lua", "neovim/init.lua", "neovim/lazy-lock.json",
        "neovim/lazyvim.json",
        "neovim/lua/config/autocmds.lua", "neovim/lua/config/keymaps.lua",
        "neovim/lua/config/lazy.lua", "neovim/lua/config/macarchy-theme.lua",
        "neovim/lua/config/options.lua", "neovim/lua/macarchy/current.lua",
        "neovim/lua/plugins/colorscheme.lua",
        "starship/behavior.toml", "yazi/theme.toml", "yazi/yazi.toml", "zsh/.zshrc",
      ]
    )
    #expect(try artifact("kitty/kitty.conf", in: first).contains("state/adapters/kitty.conf"))
    #expect(try !artifact("kitty/kitty.conf", in: first).contains("allow_remote_control"))
    let zsh = try artifact("zsh/.zshrc", in: first)
    #expect(zsh.contains("export EZA_CONFIG_DIR=\"$HOME/.config/eza\""))
    #expect(zsh.contains("function y()"))
    let atuinInit = try #require(zsh.range(of: "atuin init zsh"))
    let starshipInit = try #require(zsh.range(of: "starship init zsh"))
    #expect(atuinInit.lowerBound < starshipInit.lowerBound)
    #expect(try artifact("atuin/config.toml", in: first).contains("name = \"macarchy-current\""))
    #expect(first.renderedDigest.hasPrefix("sha256:"))
    #expect(first.inputDigest.hasPrefix("sha256:"))
  }

  @Test
  func packagedNeovimOverlayRendersTheEscapedConcreteStateRoot() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appending(
      path: "state \"quoted\" \\ root",
      directoryHint: .isDirectory
    )
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: stateRoot
    )
    let loader = try artifact("neovim/lua/macarchy/current.lua", in: composition)
    let watcher = try artifact("neovim/lua/config/macarchy-theme.lua", in: composition)

    #expect(
      loader.contains(NeovimAdapter.managedThemeLoaderDirective(root: stateRoot))
    )
    #expect(
      watcher.contains(NeovimAdapter.managedWatcherRootDirective(root: stateRoot))
    )
    #expect(!loader.contains("__MACARCHY_STATE_ROOT_LUA__"))
    #expect(!watcher.contains("__MACARCHY_STATE_ROOT_LUA__"))
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
      composition.artifacts.filter { $0.path.hasPrefix("kitty/override/") }.map(\.path) == [
        "kitty/override/bindings.conf", "kitty/override/kitty.conf",
      ]
    )
    #expect(
      try artifact("kitty/override/bindings.conf", in: composition)
        == "map cmd+enter new_window\n"
    )
    #expect(try artifact("kitty/kitty.conf", in: composition).contains("font_size 15.0"))
    #expect(
      try artifact("kitty/kitty.conf", in: composition).contains("include override/kitty.conf")
    )
    #expect(try artifact("zsh/.zshrc", in: composition).contains("export EDITOR=\"vim\""))
    #expect(try artifact("zsh/.zshrc", in: composition).hasSuffix("alias gs='git status'\n"))
    #expect(try artifact("starship/behavior.toml", in: composition).contains("style = \"green\""))
    let atuin = try artifact("atuin/config.toml", in: composition)
    #expect(atuin.contains("search_mode = \"fulltext\""))
    #expect(atuin.contains("enter_accept = false"))
    #expect(atuin.contains("enabled = false"))
    #expect(atuin.contains("autostart = false"))
    #expect(composition.zshHookDigest?.hasPrefix("sha256:") == true)
  }

  @Test
  func dailyToolOptOutsAndSparseOptionsChangeOnlyOwnedBehavior() throws {
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [tools]
      bat = false
      eza = false
      [btop]
      vim_keys = false
      [yazi]
      show_hidden = false
      """,
      source: URL(filePath: "/fixtures/profile.toml")
    )

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: URL(filePath: "/fixtures/state")
    )

    #expect(!composition.artifacts.contains { $0.path == "bat/config" })
    #expect(try artifact("btop/btop.conf", in: composition).contains("vim_keys = False"))
    #expect(try artifact("yazi/yazi.toml", in: composition).contains("show_hidden = false"))
    let zsh = try artifact("zsh/.zshrc", in: composition)
    #expect(!zsh.contains("EZA_CONFIG_DIR"))
    #expect(!zsh.contains("alias ls='eza"))
    #expect(zsh.contains("function y()"))
  }

  @Test
  func fullNativeNeovimConfigurationPreservesFilesOutsideReservedThemePaths() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let neovim = root.appending(path: "nvim", directoryHint: .isDirectory)
    let custom = neovim.appending(path: "lua/custom", directoryHint: .isDirectory)
    let spell = neovim.appending(path: "spell", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: spell, withIntermediateDirectories: true)
    try "require(\"custom.settings\")\n".write(
      to: neovim.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "vim.o.number = true\n".write(
      to: custom.appending(path: "settings.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "local lazy = require('lazy')\nlazy.setup({ spec = { { import='plugins' } } })\n".write(
      to: custom.appending(path: "lazy.lua"),
      atomically: true,
      encoding: .utf8
    )
    try
      "{\"personal-plugin\":{\"branch\":\"main\",\"commit\":\"0123456789012345678901234567890123456789\"}}\n"
      .write(
        to: neovim.appending(path: "lazy-lock.json"),
        atomically: true,
        encoding: .utf8
      )
    let binary = Data([0, 255, 1, 254])
    try binary.write(to: spell.appending(path: "personal.spl"))
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [terminal]
      provider = "disabled"
      [shell]
      provider = "disabled"
      [editor]
      provider = "neovim"
      [neovim]
      configuration = "nvim"
      [tools]
      bat = false
      eza = false
      btop = false
      yazi = false
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: root.appending(path: "state")
    )

    #expect(composition.neovimConfigurationURL == neovim)
    #expect(try artifact("neovim/init.lua", in: composition) == "require(\"custom.settings\")\n")
    #expect(
      try artifact("neovim/lua/config/macarchy-theme.lua", in: composition).contains(
        NeovimAdapter.backgroundAwareWatcherDirective
      ))
    let binaryArtifact = try #require(
      composition.artifacts.first { $0.path == "neovim/spell/personal.spl" }
    )
    #expect(binaryArtifact.data == binary)
    #expect(binaryArtifact.textContents == nil)
    let lockData = try #require(
      composition.artifacts.first { $0.path == "neovim/lazy-lock.json" }?.data
    )
    let lock = try #require(
      JSONSerialization.jsonObject(with: lockData) as? [String: Any]
    )
    #expect(lock["personal-plugin"] != nil)
    #expect(
      Set(["aether", "catppuccin", "kanagawa.nvim", "tokyonight.nvim"]).isSubset(
        of: Set(lock.keys)
      ))
    #expect(try Data(contentsOf: spell.appending(path: "personal.spl")) == binary)
  }

  @Test
  func completeADR0027ThemeSeamMigratesAtomically() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (neovim, profile) = try legacyNeovimConfiguration(in: root)

    let composition = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: root.appending(path: "state")
    )
    for relativePath in [
      "colors/macarchy-imported.lua",
      "lua/plugins/colorscheme.lua",
    ] {
      let generated = try #require(
        composition.artifacts.first { $0.path == "neovim/\(relativePath)" }
      )
      #expect(
        generated.data
          == (try Data(contentsOf: resourcesRoot.appending(path: "neovim/theme/\(relativePath)")))
      )
    }
    #expect(
      try artifact("neovim/lua/config/macarchy-theme.lua", in: composition).contains(
        NeovimAdapter.managedWatcherRootDirective(root: root.appending(path: "state"))
      )
    )
    #expect(
      composition.artifacts.contains { $0.path == "neovim/lua/macarchy/current.lua" }
    )
    #expect(FileManager.default.fileExists(atPath: neovim.path))
  }

  @Test
  func partialADR0027ThemeSeamConflicts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (neovim, profile) = try legacyNeovimConfiguration(in: root)
    try FileManager.default.removeItem(
      at: neovim.appending(path: "colors/macarchy-imported.lua")
    )

    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(
        resourcesRoot: resourcesRoot,
        profile: profile,
        stateRoot: root.appending(path: "state")
      )
    }
  }

  @Test
  func fullNativeNeovimConfigurationRejectsLinksAndThemePathConflicts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let neovim = root.appending(path: "nvim", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: neovim, withIntermediateDirectories: true)
    try "".write(
      to: neovim.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "require(\"lazy\").setup({ spec = { { import = \"plugins\" } } })\n".write(
      to: neovim.appending(path: "lazy.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "{}\n".write(
      to: neovim.appending(path: "lazy-lock.json"),
      atomically: true,
      encoding: .utf8
    )
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[neovim]\nconfiguration = \"nvim\"\n",
      source: root.appending(path: "profile.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: neovim.appending(path: "linked.lua"),
      withDestinationURL: root.appending(path: "outside.lua")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }

    try FileManager.default.removeItem(at: neovim.appending(path: "linked.lua"))
    let macarchy = neovim.appending(path: "lua/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macarchy, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: macarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(path: "unexpected.lua")
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
    try FileManager.default.removeItem(at: macarchy.appending(path: "current.lua"))
    let reserved = neovim.appending(path: "lua/plugins", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
    try "return {}\n".write(
      to: reserved.appending(path: "colorscheme.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(throws: EnvironmentConfigurationError.self) {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
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
    let rendered = try artifact("atuin/config.toml", in: composition)
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

  private func artifact(_ path: String, in composition: EnvironmentComposition) throws -> String {
    let artifact = try #require(composition.artifacts.first { $0.path == path })
    return try #require(artifact.textContents)
  }

  private func legacyNeovimConfiguration(
    in root: URL
  ) throws -> (directory: URL, profile: PortableProfile) {
    let fixture = repositoryRoot.appending(
      path: "Tests/Fixtures/NeovimLegacyADR0027",
      directoryHint: .isDirectory
    )
    let neovim = root.appending(path: "nvim", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: fixture, to: neovim)
    try "return {}\n".write(
      to: neovim.appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "{}\n".write(
      to: neovim.appending(path: "lazy-lock.json"),
      atomically: true,
      encoding: .utf8
    )
    let macarchy = neovim.appending(path: "lua/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macarchy, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: macarchy.appending(path: "current.lua"),
      withDestinationURL: root.appending(
        path: "home/.config/macarchy/current/generated/neovim.lua"
      )
    )
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[neovim]\nconfiguration = \"nvim\"\n",
      source: root.appending(path: "profile.toml")
    )
    return (neovim, profile)
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
