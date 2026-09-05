import Foundation
import Testing

@testable import ThemeCore

struct KeybindingProfileTests {
  private let loader = KeybindingProfileLoader()

  @Test
  func absentDefaultIsEmptyButAbsentExplicitProfileFails() throws {
    let missing = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-missing-profile-\(UUID().uuidString).toml"
    )

    #expect(try loader.load(at: missing, required: false) == .empty)
    #expect(throws: KeybindingProfileError.self) {
      _ = try loader.load(at: missing, required: true)
    }
  }

  @Test
  func relativeInputsResolveBesideTheResolvedProfileSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    let exposedDirectory = root.appending(
      path: "home/.config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exposedDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appending(path: "profile.toml")
    try """
    schema_version = 1
    [keybindings]
    override = "personal.skhdrc"
    metadata = "personal-metadata.toml"
    disabled = ["alt-k"]
    """.write(to: source, atomically: true, encoding: .utf8)
    let exposed = exposedDirectory.appending(path: "profile.toml")
    try FileManager.default.createSymbolicLink(at: exposed, withDestinationURL: source)

    let profile = try loader.load(at: exposed, required: true)

    #expect(profile.sourceURL == exposed.standardizedFileURL)
    #expect(profile.overrideURL == sourceDirectory.appending(path: "personal.skhdrc"))
    #expect(profile.metadataURL == sourceDirectory.appending(path: "personal-metadata.toml"))
    #expect(profile.disabledIdentities == ["alt-k"])
  }

  @Test
  func sharedPortableProfileAcceptsTypedDesktopAndTopBarSelections() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let text = """
      schema_version = 1
      [keybindings]
      disabled = ["alt-k"]
      [desktop]
      provider = "yabai-skhd"
      [yabai]
      layout = "stack"
      window_gap = 9
      [top_bar]
      provider = "disabled"
      [sketchybar]
      left = ["clock", "spaces"]
      right = ["volume"]
      hook = "sketchybar.sh"
      """

    let portable = try PortableProfileLoader().decode(text, source: source)
    let keybindings = try loader.decode(text, source: source)

    #expect(portable.desktop.provider == .yabaiSkhd)
    #expect(portable.desktop.yabai.layout == "stack")
    #expect(portable.desktop.yabai.windowGap == 9)
    #expect(portable.topBar == .disabled)
    #expect(portable.sketchyBar.left == [.clock, .spaces])
    #expect(portable.sketchyBar.right == [.volume])
    #expect(portable.sketchyBar.hookURL == URL(filePath: "/fixtures/sketchybar.sh"))
    #expect(keybindings.disabledIdentities == ["alt-k"])
  }

  @Test
  func sharedPortableProfileAcceptsTypedTerminalSessionIntent() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let text = """
      schema_version = 1
      [terminal]
      provider = "kitty"
      [kitty]
      font_family = "MesloLGS NF"
      font_size = 14
      background_opacity = 0.92
      background_blur = 24
      override = "kitty"
      [shell]
      provider = "zsh"
      [zsh]
      editor = "nvim"
      hook = "zshrc"
      [prompt]
      provider = "starship"
      [starship]
      behavior = "starship.toml"
      [history]
      provider = "atuin"
      [atuin]
      search_mode = "daemon-fuzzy"
      keymap_mode = "vim-insert"
      enter_accept = true
      daemon = true
      configuration = "atuin.toml"
      [editor]
      provider = "neovim"
      [neovim]
      configuration = "nvim"
      [tools]
      bat = false
      eza = true
      btop = true
      yazi = true
      [btop]
      vim_keys = false
      [yazi]
      show_hidden = false
      """

    let environment = try PortableProfileLoader().decode(text, source: source).environment

    #expect(environment.terminal == .kitty)
    #expect(environment.shell == .zsh)
    #expect(environment.prompt == .starship)
    #expect(environment.history == .atuin)
    #expect(environment.editor == .neovim)
    #expect(environment.kitty.fontFamily == "MesloLGS NF")
    #expect(environment.kitty.fontSize == 14)
    #expect(environment.kitty.backgroundOpacity == 0.92)
    #expect(environment.kitty.backgroundBlur == 24)
    #expect(environment.kitty.overrideDirectoryURL == URL(filePath: "/fixtures/kitty"))
    #expect(environment.zsh.editor == "nvim")
    #expect(environment.zsh.hookURL == URL(filePath: "/fixtures/zshrc"))
    #expect(environment.starship.behaviorURL == URL(filePath: "/fixtures/starship.toml"))
    #expect(environment.atuin.searchMode == "daemon-fuzzy")
    #expect(environment.atuin.keymapMode == "vim-insert")
    #expect(environment.atuin.enterAccept == true)
    #expect(environment.atuin.daemon == true)
    #expect(environment.atuin.configurationURL == URL(filePath: "/fixtures/atuin.toml"))
    #expect(
      environment.neovim.configurationDirectoryURL == URL(filePath: "/fixtures/nvim")
    )
    #expect(environment.tools.bat == false)
    #expect(environment.tools.eza == true)
    #expect(environment.tools.btop == true)
    #expect(environment.tools.yazi == true)
    #expect(environment.btop.vimKeys == false)
    #expect(environment.yazi.showHidden == false)
  }

  @Test
  func environmentInputsCannotEscapeThroughAnIntermediateSymbolicLink() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileDirectory = root.appending(path: "profile", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "echo outside\n".write(
      to: outside.appending(path: "hook.zsh"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: profileDirectory.appending(path: "linked"),
      withDestinationURL: outside
    )

    #expect(throws: KeybindingProfileError.self) {
      _ = try PortableProfileLoader().decode(
        "schema_version = 1\n[zsh]\nhook = \"linked/hook.zsh\"\n",
        source: profileDirectory.appending(path: "profile.toml")
      )
    }
  }

  @Test
  func terminalSessionDefaultsAndShellDisablementAreTyped() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let defaults = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: source
    ).environment
    #expect(defaults.terminal == .kitty)
    #expect(defaults.shell == .zsh)
    #expect(defaults.prompt == .starship)
    #expect(defaults.history == .atuin)
    #expect(defaults.editor == .neovim)
    #expect(defaults.tools.bat)
    #expect(defaults.tools.eza)
    #expect(defaults.tools.btop)
    #expect(defaults.tools.yazi)

    let disabled = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [shell]
      provider = "disabled"
      """,
      source: source
    ).environment
    #expect(disabled.shell == .disabled)
    #expect(disabled.prompt == .disabled)
    #expect(disabled.history == .disabled)
  }

  @Test
  func disabledDailyToolsCannotRetainToolSpecificIntent() {
    let source = URL(filePath: "/fixtures/profile.toml")
    for text in [
      "schema_version = 1\n[tools]\nbtop = false\n[btop]\nvim_keys = true\n",
      "schema_version = 1\n[tools]\nyazi = false\n[yazi]\nshow_hidden = true\n",
    ] {
      #expect(throws: KeybindingProfileError.self) {
        _ = try PortableProfileLoader().decode(text, source: source)
      }
    }
  }

  @Test
  func rejectsUnknownProvidersAndUnsafeYabaiControls() {
    let source = URL(filePath: "/fixtures/profile.toml")
    let invalid: [(String, String)] = [
      (
        "schema_version = 1\n[desktop]\nprovider = \"arbitrary-command\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[yabai]\nsplit_ratio = 1.0\n",
        "must be between 0.1 and 0.9"
      ),
      (
        "schema_version = 1\n[yabai]\nhook = \"/tmp/yabairc\"\n",
        "must be a relative path"
      ),
      (
        "schema_version = 1\n[top_bar]\nprovider = \"custom\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[sketchybar]\nleft = [\"clock\", \"clock\"]\n",
        "module must be unique"
      ),
      (
        "schema_version = 1\n[sketchybar]\nright = [\"weather\"]\n",
        "weather"
      ),
      (
        "schema_version = 1\n[sketchybar]\nhook = \"/tmp/sketchybar.sh\"\n",
        "must be a relative path"
      ),
      (
        "schema_version = 1\n[terminal]\nprovider = \"wezterm\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[terminal]\nprovider = \"disabled\"\n[kitty]\nfont_size = 14\n",
        "cannot customize a disabled terminal"
      ),
      (
        "schema_version = 1\n[shell]\nprovider = \"disabled\"\n[zsh]\neditor = \"nvim\"\n",
        "requires shell.provider"
      ),
      (
        "schema_version = 1\n[shell]\nprovider = \"disabled\"\n[prompt]\nprovider = \"starship\"\n",
        "requires shell.provider"
      ),
      (
        "schema_version = 1\n[shell]\nprovider = \"disabled\"\n[history]\nprovider = \"atuin\"\n",
        "requires shell.provider"
      ),
      (
        "schema_version = 1\n[prompt]\nprovider = \"disabled\"\n[starship]\nbehavior = \"starship.toml\"\n",
        "cannot customize a disabled prompt"
      ),
      (
        "schema_version = 1\n[history]\nprovider = \"disabled\"\n[atuin]\ndaemon = false\n",
        "cannot customize a disabled history"
      ),
      (
        "schema_version = 1\n[editor]\nprovider = \"zed\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[editor]\nprovider = \"disabled\"\n[neovim]\nconfiguration = \"nvim\"\n",
        "cannot customize a disabled editor"
      ),
      (
        "schema_version = 1\n[kitty]\nbackground_opacity = -0.1\n",
        "must be between 0 and 1"
      ),
      (
        "schema_version = 1\n[kitty]\nfont_family = \"Menlo\\nallow_remote_control yes\"\n",
        "must be a single-line value"
      ),
      (
        "schema_version = 1\n[zsh]\neditor = \"/usr/bin/vim\"\n",
        "must be an ASCII command name"
      ),
      (
        "schema_version = 1\n[atuin]\nsearch_mode = \"skim\"\n",
        "must be fuzzy, prefix, fulltext, or daemon-fuzzy"
      ),
    ]

    for (document, expected) in invalid {
      do {
        _ = try PortableProfileLoader().decode(document, source: source)
        Issue.record("Expected invalid profile: \(expected)")
      } catch {
        #expect(String(describing: error).contains(expected))
      }
    }
  }

  @Test
  func rejectsUnknownFieldsUnsafePathsAndInvalidDisabledIdentities() {
    let source = URL(filePath: "/fixtures/profile.toml")
    let invalid: [(String, String)] = [
      (
        "schema_version = 1\n[keybindings]\ncommand = \"open Calculator\"\n",
        "unknown key 'keybindings.command'"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"/tmp/skhdrc\"\n",
        "must be a relative path"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"../skhdrc\"\n",
        "must stay beside the profile"
      ),
      (
        "schema_version = 1\n[keybindings]\ndisabled = [\"shift+alt-j\"]\n",
        "is not a normalized skhd chord"
      ),
      (
        "schema_version = 1\n[keybindings]\ndisabled = [\"alt-j\", \"alt-j\"]\n",
        "must be unique"
      ),
    ]

    for (document, expected) in invalid {
      do {
        _ = try loader.decode(document, source: source)
        Issue.record("Expected invalid profile: \(expected)")
      } catch {
        #expect(String(describing: error).contains(expected))
      }
    }
  }

  @Test
  func machineProfileOverlaysFieldsAndResolvesItsPathsBesideItself() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portableDirectory = root.appending(path: "portable", directoryHint: .isDirectory)
    let machineDirectory = root.appending(path: "machine", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: portableDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: machineDirectory,
      withIntermediateDirectories: true
    )
    let portable = portableDirectory.appending(path: "profile.toml")
    let machine = machineDirectory.appending(path: "machine.toml")
    try """
    schema_version = 1
    [keybindings]
    override = "portable.skhdrc"
    disabled = ["alt-k"]
    [kitty]
    font_family = "Portable Font"
    font_size = 13
    [zsh]
    hook = "portable.zsh"
    [tools]
    bat = false
    """.write(to: portable, atomically: true, encoding: .utf8)
    try """
    schema_version = 1
    [keybindings]
    disabled = []
    [kitty]
    font_size = 15
    override = "kitty"
    [zsh]
    editor = "nvim"
    [tools]
    bat = true
    """.write(to: machine, atomically: true, encoding: .utf8)

    let layered = try PortableProfileLoader().load(
      portableAt: portable,
      portableRequired: true,
      machineAt: machine,
      machineRequired: true
    )
    let profile = layered.profile

    #expect(profile.keybindings.disabledIdentities.isEmpty)
    #expect(
      profile.keybindings.overrideURL == portableDirectory.appending(path: "portable.skhdrc")
    )
    #expect(profile.environment.kitty.fontFamily == "Portable Font")
    #expect(profile.environment.kitty.fontSize == 15)
    #expect(
      profile.environment.kitty.overrideDirectoryURL
        == machineDirectory.appending(path: "kitty")
    )
    #expect(profile.environment.zsh.hookURL == portableDirectory.appending(path: "portable.zsh"))
    #expect(profile.environment.zsh.editor == "nvim")
    #expect(profile.environment.tools.bat)
    #expect(layered.layers.map(\.present) == [true, true])
    #expect(layered.fieldOrigins["kitty.font_family"] == .portable)
    #expect(layered.fieldOrigins["kitty.font_size"] == .machine)
    #expect(layered.fieldOrigins["keybindings.disabled"] == .machine)
  }

  @Test
  func layeredProfileRejectsAnEffectiveCrossLayerContradiction() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    try "schema_version = 1\n[kitty]\nfont_size = 13\n".write(
      to: portable,
      atomically: true,
      encoding: .utf8
    )
    try "schema_version = 1\n[terminal]\nprovider = \"disabled\"\n".write(
      to: machine,
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: KeybindingProfileError.self) {
      _ = try PortableProfileLoader().load(
        portableAt: portable,
        portableRequired: true,
        machineAt: machine,
        machineRequired: true
      )
    }
  }

  @Test
  func machineReenablingShellRestoresUndeclaredPromptAndHistoryDefaults() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    try "schema_version = 1\n[shell]\nprovider = \"disabled\"\n".write(
      to: portable,
      atomically: true,
      encoding: .utf8
    )
    try "schema_version = 1\n[shell]\nprovider = \"zsh\"\n".write(
      to: machine,
      atomically: true,
      encoding: .utf8
    )

    let layered = try PortableProfileLoader().load(
      portableAt: portable,
      portableRequired: true,
      machineAt: machine,
      machineRequired: true
    )

    #expect(layered.profile.environment.shell == .zsh)
    #expect(layered.profile.environment.prompt == .starship)
    #expect(layered.profile.environment.history == .atuin)
    #expect(layered.profile.keybindings.sourceURL == portable)
  }

  @Test
  func absentOptionalLayersUseDefaultsButAnExplicitMissingMachineProfileFails() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    let layered = try PortableProfileLoader().load(
      portableAt: portable,
      portableRequired: false,
      machineAt: machine,
      machineRequired: false
    )

    #expect(layered.profile == .defaults)
    #expect(layered.layers.map(\.present) == [false, false])
    #expect(layered.fieldOrigins.isEmpty)
    #expect(throws: KeybindingProfileError.self) {
      _ = try PortableProfileLoader().load(
        portableAt: portable,
        portableRequired: false,
        machineAt: machine,
        machineRequired: true
      )
    }
  }

  @Test
  func machineReenablingShellPreservesDeclaredPromptAndHistoryDisablement() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    try """
    schema_version = 1
    [shell]
    provider = "disabled"
    [prompt]
    provider = "disabled"
    [history]
    provider = "disabled"
    """.write(to: portable, atomically: true, encoding: .utf8)
    try "schema_version = 1\n[shell]\nprovider = \"zsh\"\n".write(
      to: machine, atomically: true, encoding: .utf8
    )

    let layered = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true,
      machineAt: machine, machineRequired: true
    )

    #expect(layered.profile.environment.shell == .zsh)
    #expect(layered.profile.environment.prompt == .disabled)
    #expect(layered.profile.environment.history == .disabled)
    #expect(layered.fieldOrigins["shell.provider"] == .machine)
    #expect(layered.fieldOrigins["prompt.provider"] == .portable)
    #expect(layered.fieldOrigins["history.provider"] == .portable)
  }

  @Test(arguments: [false, true])
  func layeredBarReplacesArraysAndKeepsHookRootWithItsDeclaringSource(
    machineDeclaresHook: Bool
  ) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machineDirectory = root.appending(path: "machine", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: machineDirectory, withIntermediateDirectories: true
    )
    let machineSource = machineDirectory.appending(path: "machine.toml")
    let machine = root.appending(path: "machine.toml")
    try FileManager.default.createSymbolicLink(at: machine, withDestinationURL: machineSource)
    try """
    schema_version = 1
    [sketchybar]
    left = ["spaces", "clock"]
    center = ["volume"]
    right = []
    hook = "portable.sh"
    """.write(to: portable, atomically: true, encoding: .utf8)
    let machineText = """
      schema_version = 1
      [sketchybar]
      left = []
      right = ["clock", "spaces"]
      """ + (machineDeclaresHook ? "\nhook = \"machine.sh\"\n" : "\n")
    try machineText.write(to: machineSource, atomically: true, encoding: .utf8)

    let layered = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true,
      machineAt: machine, machineRequired: true
    )
    let bar = layered.profile.sketchyBar
    let hookRoot = machineDeclaresHook ? machineDirectory : root
    #expect(bar.left == [])
    #expect(bar.center == [.volume])
    #expect(bar.right == [.clock, .spaces])
    #expect(bar.hookRootURL == hookRoot)
    #expect(
      bar.hookURL == hookRoot.appending(path: machineDeclaresHook ? "machine.sh" : "portable.sh"))
    #expect(layered.profile.sourceURL == machine)
    #expect(layered.profile.keybindings.sourceURL == portable)
    #expect(layered.fieldOrigins["sketchybar.left"] == .machine)
    #expect(layered.fieldOrigins["sketchybar.center"] == .portable)
    #expect(layered.fieldOrigins["sketchybar.hook"] == (machineDeclaresHook ? .machine : .portable))
    #expect(layered.fieldOrigins["prompt.provider"] == nil)
    #expect(layered.fieldOrigins["history.provider"] == nil)
  }

  @Test(arguments: [false, true])
  func layeredValidationKeepsIndependentLayerAndCrossRoleErrorOrder(
    invalidPortable: Bool
  ) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    let portableText =
      "schema_version = 1\n[kitty]\n[zsh]\n"
      + (invalidPortable ? "[terminal]\nprovider = \"disabled\"\n" : "")
    try portableText.write(to: portable, atomically: true, encoding: .utf8)
    try """
    schema_version = 1
    [terminal]
    provider = "disabled"
    [shell]
    provider = "disabled"
    """.write(to: machine, atomically: true, encoding: .utf8)

    do {
      _ = try PortableProfileLoader().load(
        portableAt: portable, portableRequired: true,
        machineAt: machine, machineRequired: true
      )
      Issue.record("Expected the terminal contradiction before the shell contradiction")
    } catch {
      let source = invalidPortable ? portable : machine
      #expect(
        String(describing: error)
          == "\(source.path): invalid Macarchy profile: [kitty] cannot customize a disabled terminal provider"
      )
    }
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-profile-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
