import Foundation
import Testing

@testable import ThemeCore

struct EnvironmentConfigurationTests {
  private let composer = EnvironmentConfigurationComposer()

  @Test(arguments: ["relative", "absolute", "linked"])
  func explicitNativeSourcesMayLeaveTheProfileDirectory(kind: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileRoot = root.appending(path: "macarchy")
    let userRoot = root.appending(path: "macarchy-user")
    try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: profileRoot.appending(path: "user"), withDestinationURL: userRoot)
    let path = kind == "absolute" ? userRoot.path : kind == "linked" ? "user" : "../macarchy-user"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let quoted = String(decoding: try encoder.encode(path), as: UTF8.self)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nconfiguration = \(quoted)\n[kitty]\nconfiguration = \(quoted)\n"
        + "[atuin]\nnative_configuration = \(quoted)\n[starship]\nnative_configuration = \(quoted)\n"
        + "[neovim]\nnative_configuration = \(quoted)\n",
      source: profileRoot.appending(path: "profile.toml"))
    for source in [
      profile.environment.zsh.configurationURL, profile.environment.kitty.configurationURL,
      profile.environment.atuin.nativeConfigurationURL,
      profile.environment.starship.nativeConfigurationURL,
      profile.environment.neovim.nativeConfigurationDirectoryURL,
    ] {
      #expect(source?.resolvingSymlinksInPath().path == userRoot.path)
    }
  }

  @Test(arguments: [
    "[zsh]\nhook", "[kitty]\noverride", "[atuin]\nconfiguration",
    "[starship]\nbehavior", "[neovim]\nconfiguration",
  ])
  func copiedInputsStillCannotLeaveTheProfileDirectory(field: String) throws {
    #expect(throws: (any Error).self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n\(field) = \"../outside\"\n",
        source: URL(filePath: "/tmp/macarchy/profile.toml"))
    }
  }

  @Test(arguments: [false, true])
  func liveSourcesResolveBesideTheirDeclaringProfileAndRetainLayerOrigins(
    machineOverridesSources: Bool
  ) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portableDirectory = root.appending(path: "portable")
    let machineDirectory = root.appending(path: "machine")
    for directory in [portableDirectory, machineDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: directory.appending(path: "nvim"), withIntermediateDirectories: true)
      try "-- native Lua\n".write(
        to: directory.appending(path: "nvim/init.lua"), atomically: true, encoding: .utf8)
      try "export PERSONAL=present\n".write(
        to: directory.appending(path: "personal.zsh"), atomically: true, encoding: .utf8)
      try "font_size 17\n".write(
        to: directory.appending(path: "kitty.conf"), atomically: true, encoding: .utf8)
      try "[theme]\nname = \"macarchy-current\"\n".write(
        to: directory.appending(path: "atuin.toml"), atomically: true, encoding: .utf8)
      try
        ("palette = \"macarchy_current\"\n"
        + StarshipAdapter.render(package: AdapterContractTests().catppuccinPackage())).write(
          to: directory.appending(path: "starship.toml"), atomically: true, encoding: .utf8)
    }
    let portable = portableDirectory.appending(path: "profile.toml")
    let machine = machineDirectory.appending(path: "profile.toml")
    try """
    schema_version = 1
    [zsh]
    configuration = "personal.zsh"
    [kitty]
    configuration = "kitty.conf"
    [atuin]
    native_configuration = "atuin.toml"
    [starship]
    native_configuration = "starship.toml"
    [neovim]
    native_configuration = "nvim"
    """.write(to: portable, atomically: true, encoding: .utf8)
    let sources =
      machineOverridesSources
      ? "[zsh]\nconfiguration = \"personal.zsh\"\n[kitty]\nconfiguration = \"kitty.conf\"\n[atuin]\nnative_configuration = \"atuin.toml\"\n"
      : "[zsh]\neditor = \"vi\"\n[kitty]\nfont_size = 19\n"
    try
      ("schema_version = 1\n" + sources
      + (machineOverridesSources
        ? "[starship]\nnative_configuration = \"starship.toml\"\n[neovim]\nnative_configuration = \"nvim\"\n"
        : ""))
      .write(
        to: machine, atomically: true, encoding: .utf8)
    let layered = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true, machineAt: machine, machineRequired: true)
    let directory = machineOverridesSources ? machineDirectory : portableDirectory
    let origin: PortableProfileLayerKind = machineOverridesSources ? .machine : .portable
    #expect(
      layered.profile.environment.zsh.configurationURL == directory.appending(path: "personal.zsh"))
    #expect(
      layered.profile.environment.kitty.configurationURL == directory.appending(path: "kitty.conf"))
    #expect(layered.fieldOrigins["zsh.configuration"] == origin)
    #expect(layered.fieldOrigins["kitty.configuration"] == origin)
    #expect(
      layered.profile.environment.atuin.nativeConfigurationURL
        == directory.appending(path: "atuin.toml"))
    #expect(layered.fieldOrigins["atuin.native_configuration"] == origin)
    #expect(
      layered.profile.environment.starship.nativeConfigurationURL
        == directory.appending(path: "starship.toml"))
    #expect(layered.fieldOrigins["starship.native_configuration"] == origin)
    #expect(
      layered.profile.environment.neovim.nativeConfigurationDirectoryURL?.path
        == directory.appending(path: "nvim").path)
    #expect(layered.fieldOrigins["neovim.native_configuration"] == origin)
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot, profile: layered.profile, stateRoot: root)
    #expect(composition.atuinConfigurationURL == directory.appending(path: "atuin.toml"))
    #expect(composition.starshipBehaviorURL == directory.appending(path: "starship.toml"))
    #expect(composition.neovimConfigurationURL?.path == directory.appending(path: "nvim").path)
    #expect(!composition.artifacts.contains { $0.path == "neovim/init.lua" })
    #expect(!composition.artifacts.contains { $0.path == "neovim/lazy-lock.json" })
    #expect(
      try artifact("zsh/.zshrc", in: composition).contains(
        directory.appending(path: "personal.zsh").path))
    #expect(
      try artifact("kitty/kitty.conf", in: composition).contains(
        directory.appending(path: "kitty.conf").path))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_KITTY_CONFIG"] == "1"))
  func installedKittyLoadsLiveIncludesAndTrailingTheme() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "personal kitty.conf")
    let nested = root.appending(path: "nested.conf")
    try "font_size 17\nforeground #112233\n".write(to: nested, atomically: true, encoding: .utf8)
    try "include nested.conf\n".write(to: source, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\nconfiguration = \"personal kitty.conf\"\n",
      source: root.appending(path: "profile.toml"))
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    let wrapper = root.appending(path: "entry.conf")
    try artifact("kitty/kitty.conf", in: composition).write(
      to: wrapper, atomically: true, encoding: .utf8)
    let bridge = root.appending(path: "state/adapters/kitty.conf")
    try FileManager.default.createDirectory(
      at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "foreground #abcdef\n".write(to: bridge, atomically: true, encoding: .utf8)
    let script = root.appending(path: "verify.py")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let path = String(data: try encoder.encode(wrapper.path), encoding: .utf8)!
    try """
    from kitty.config import load_config
    errors = []
    options = load_config(\(path), accumulate_bad_lines=errors)
    assert not errors, errors
    assert options.font_size == 17, options.font_size
    assert int(options.foreground) == 0xabcdef, options.foreground
    # Complete user configuration does not silently inherit Macarchy's 0.95 opacity.
    assert options.background_opacity == 1.0, options.background_opacity
    """.write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(filePath: "/opt/homebrew/bin/kitty")
    let scriptPath = String(data: try encoder.encode(script.path), encoding: .utf8)!
    process.arguments = ["+runpy", "import runpy; runpy.run_path(\(scriptPath))"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @Test
  func liveKittyConfigurationSeparatesDefaultsBehaviorAndTrailingTheme() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "personal kitty.conf")
    try "font_size 14\n".write(to: source, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\nconfiguration = \"personal kitty.conf\"\n",
      source: root.appending(path: "profile.toml"))
    let first = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    let wrapper = try artifact("kitty/kitty.conf", in: first)
    #expect(wrapper == "include \(source.path)\n\ninclude \(root.path)/state/adapters/kitty.conf\n")
    #expect(try artifact("kitty/defaults.conf", in: first).contains("map ctrl+g>c new_tab"))
    try "font_size 17\n".write(to: source, atomically: true, encoding: .utf8)
    let second = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    #expect(first.inputDigest == second.inputDigest)
    #expect(first.renderedDigest == second.renderedDigest)
  }

  @Test(arguments: ["missing.conf", "$PERSONAL.conf", "conflicting.conf"])
  func liveKittyConfigurationRejectsInvalidConnections(name: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    if name != "missing.conf" {
      try "font_size 14\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }
    let extra = name == "conflicting.conf" ? "override = \"legacy\"\n" : ""
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[kitty]\nconfiguration = \"\(name)\"\n" + extra,
      source: root.appending(path: "profile.toml"))
    #expect(throws: EnvironmentConfigurationError.self) {
      try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    }
  }

  @Test
  func completePersonalZshOwnsInitializationPathsAndPrivateRuntimeInputs() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "personal.zsh")
    try #"""
    export PATH="$HOME/.bun/bin:$HOME/bin:$PATH"
    alias personal='print preserved'
    eval "$(starship init zsh)"
    eval "$(atuin init zsh)"
    source "$HOME/private.env"
    """#.write(to: source, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nconfiguration = \"personal.zsh\"\n",
      source: root.appending(path: "profile.toml"))
    // The private runtime file does not even exist during composition.
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root.appending(path: "state"))
    for directory in ["bin", ".bun/bin"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: directory), withIntermediateDirectories: true)
    }
    let scripts = [
      "bin/starship": "#!/bin/sh\nprintf '%s\\n' '(( STARSHIP_COUNT += 1 ))'\n",
      "bin/atuin": "#!/bin/sh\nprintf '%s\\n' '(( ATUIN_COUNT += 1 ))'\n",
      ".bun/bin/bunx": "#!/bin/sh\nexit 0\n",
    ]
    for (path, script) in scripts {
      let url = root.appending(path: path)
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    try "export PRIVATE_RUNTIME=fixture-only\n".write(
      to: root.appending(path: "private.env"), atomically: true, encoding: .utf8)
    #expect(
      composition.artifacts.allSatisfy { !($0.textContents?.contains("fixture-only") ?? false) })
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = [
      "-f", "-c",
      try artifact("zsh/.zshrc", in: composition)
        + #"""

        print -r -- "$STARSHIP_COUNT:$ATUIN_COUNT:$MACARCHY_MANAGED_SESSION:$PRIVATE_RUNTIME"
        command -v bunx
        alias personal
        """#,
    ]
    process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "\(text)")
    #expect(text.contains("1:1:1:fixture-only"))
    #expect(text.contains(root.appending(path: ".bun/bin/bunx").path))
    #expect(text.contains("print preserved"))
  }

  @Test
  func liveZshConfigurationPreservesEditsOutsideGenerationIdentity() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "personal.zsh")
    try "export PERSONAL=before\n".write(to: source, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nconfiguration = \"personal.zsh\"\n",
      source: root.appending(path: "profile.toml")
    )
    let first = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    let wrapper = try artifact("zsh/.zshrc", in: first)
    #expect(wrapper.contains("source '\(source.path)' || return 1"))
    #expect(wrapper.contains("MACARCHY_ZSH_DEFAULTS="))
    #expect(!wrapper.contains("starship init"))
    #expect(try artifact("zsh/defaults.zsh", in: first).contains("starship init zsh"))
    try "export PERSONAL=after\n".write(to: source, atomically: true, encoding: .utf8)
    let second = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
    #expect(first.renderedDigest == second.renderedDigest)
    #expect(first.inputDigest == second.inputDigest)
    #expect(try String(contentsOf: source, encoding: .utf8) == "export PERSONAL=after\n")
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-f", "-c", wrapper + "\nprint -r -- $PERSONAL"]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "after\n")
  }

  @Test
  func liveZshConfigurationRejectsMissingSourcesAndLegacyHookCombination() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nconfiguration = \"missing.zsh\"\n",
      source: root.appending(path: "profile.toml"))
    #expect(throws: EnvironmentConfigurationError.self) {
      try composer.compose(resourcesRoot: resourcesRoot, profile: missing, stateRoot: root)
    }

    let source = root.appending(path: "personal.zsh")
    try "export PERSONAL=kept\n".write(to: source, atomically: true, encoding: .utf8)
    try "# legacy hook\n".write(
      to: root.appending(path: "hook.zsh"), atomically: true, encoding: .utf8)
    let conflicting = try PortableProfileLoader().decode(
      "schema_version = 1\n[zsh]\nconfiguration = \"personal.zsh\"\nhook = \"hook.zsh\"\n",
      source: root.appending(path: "profile.toml"))
    do {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: conflicting, stateRoot: root)
      Issue.record("Expected native configuration and legacy hook conflict")
    } catch EnvironmentConfigurationError.invalid(let url, let message) {
      #expect(url == source)
      #expect(message == "zsh.configuration and zsh.hook are mutually exclusive")
    }
  }

  @Test
  func optionalPresetsAreClosedTypedAndDisabledByDefault() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let defaults = try PortableProfileLoader().decode("schema_version = 1\n", source: source)
    let selected = try PortableProfileLoader().decode(
      "schema_version = 1\n[presets]\ncodex = true\nherdr = true\npi = true\nslack = true\nspicetify = true\ntuicr = true\n",
      source: source
    )

    #expect(!defaults.environment.presets.codex)
    #expect(!defaults.environment.presets.herdr)
    #expect(!defaults.environment.presets.pi)
    #expect(!defaults.environment.presets.slack)
    #expect(!defaults.environment.presets.spicetify)
    #expect(!defaults.environment.presets.tuicr)
    #expect(selected.environment.presets.codex)
    #expect(selected.environment.presets.herdr)
    #expect(selected.environment.presets.pi)
    #expect(selected.environment.presets.slack)
    #expect(selected.environment.presets.spicetify)
    #expect(selected.environment.presets.tuicr)
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
        "atuin/config.toml", "bat/config", "borders/bordersrc", "btop/btop.conf",
        "kitty/kitty.conf",
        "neovim/colors/macarchy-imported.lua", "neovim/init.lua", "neovim/lazy-lock.json",
        "neovim/lazyvim.json",
        "neovim/lua/config/autocmds.lua", "neovim/lua/config/keymaps.lua",
        "neovim/lua/config/lazy.lua", "neovim/lua/config/macarchy-theme.lua",
        "neovim/lua/config/markdown-preview.lua",
        "neovim/lua/config/options.lua", "neovim/lua/macarchy/current.lua",
        "neovim/lua/plugins/colorscheme.lua", "neovim/lua/plugins/editor.lua",
        "starship/behavior.toml", "yazi/theme.toml", "yazi/yazi.toml", "zsh/.zshrc",
      ]
    )
    #expect(try artifact("kitty/kitty.conf", in: first).contains("state/adapters/kitty.conf"))
    let kitty = try artifact("kitty/kitty.conf", in: first)
    #expect(kitty.contains("allow_remote_control no\n"))
    #expect(kitty.contains("font_family postscript_name=MesloLGSNF-Regular\n"))
    #expect(kitty.contains("font_size 11.0\n"))
    #expect(kitty.contains("shell_integration no-cursor\n"))
    #expect(kitty.contains("cursor_trail 5\n"))
    #expect(kitty.contains("cursor_stop_blinking_after 0\n"))
    #expect(kitty.contains("map ctrl+g>| launch --location=vsplit --cwd=current\n"))
    #expect(kitty.contains("map --mode resize esc pop_keyboard_mode\n"))
    #expect(kitty.contains("map ctrl+g>s combine : new_tab : set_tab_title main"))
    #expect(!kitty.contains("include bindings.conf"))
    #expect(
      try artifact("kitty/kitty.conf", in: first).contains(
        "hide_window_decorations titlebar-only\n"))
    #expect(!kitty.contains("hide_window_decorations titlebar-and-corners\n"))
    let zsh = try artifact("zsh/.zshrc", in: first)
    #expect(zsh.contains("export EZA_CONFIG_DIR=\"$HOME/.config/eza\""))
    #expect(zsh.contains("function y()"))
    #expect(zsh.contains("setopt SHARE_HISTORY"))
    #expect(zsh.contains("bindkey '^y' autosuggest-accept || return 1"))
    #expect(zsh.contains("/opt/homebrew/bin/zoxide init zsh"))
    let fzf = try #require(zsh.range(of: "source /opt/homebrew/opt/fzf/shell/key-bindings.zsh"))
    let history = try #require(zsh.range(of: "atuin init zsh"))
    let highlighting = try #require(
      zsh.range(of: "source /opt/homebrew/share/zsh-syntax-highlighting"))
    #expect(fzf.lowerBound < history.lowerBound)
    #expect(history.lowerBound < highlighting.lowerBound)
    #expect(zsh.contains("alias gc='git commit --verbose'"))
    #expect(zsh.contains("alias n='nvim'"))
    #expect(!zsh.contains("/Users/ramtin"))
    let keymaps = try artifact("neovim/lua/config/keymaps.lua", in: first)
    #expect(keymaps.contains("\"<leader>y\""))
    #expect(keymaps.contains("\"<C-d>zz\""))
    let starship = try artifact("starship/behavior.toml", in: first)
    #expect(starship.contains("$ahead_behind$stashed"))
    #expect(starship.contains("stashed = \"≡\""))
    #expect(!starship.contains("](218)"))
    let atuinInit = try #require(zsh.range(of: "atuin init zsh"))
    let starshipInit = try #require(zsh.range(of: "starship init zsh"))
    #expect(atuinInit.lowerBound < starshipInit.lowerBound)
    #expect(try artifact("atuin/config.toml", in: first).contains("name = \"macarchy-current\""))
    #expect(try artifact("atuin/config.toml", in: first).contains("keymap_mode = \"vim-insert\""))
    #expect(first.renderedDigest.hasPrefix("sha256:"))
    #expect(first.inputDigest.hasPrefix("sha256:"))
  }

  @Test
  func packagedEditorIncludesPersonalExtrasAndPinsWithoutPrivateState() throws {
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n", source: URL(filePath: "/fixtures/profile.toml"))
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: URL(filePath: "/fixtures/state"))
    let extras = try #require(
      JSONSerialization.jsonObject(
        with: Data(try artifact("neovim/lazyvim.json", in: composition).utf8))
        as? [String: Any])
    #expect(
      extras["extras"] as? [String]
        == [
          "coding.mini-surround", "editor.telescope", "lang.clangd", "lang.docker", "lang.go",
          "lang.helm", "lang.json", "lang.markdown", "lang.python", "lang.sql", "lang.terraform",
          "lang.toml", "lang.yaml",
        ].map { "lazyvim.plugins.extras.\($0)" })
    #expect((extras["news"] as? [String: String])?.isEmpty == true)
    let lock = try #require(
      JSONSerialization.jsonObject(
        with: Data(try artifact("neovim/lazy-lock.json", in: composition).utf8))
        as? [String: [String: String]])
    for plugin in [
      "SchemaStore.nvim", "clangd_extensions.nvim", "helm-ls.nvim", "markdown-preview.nvim",
      "mini.surround", "no-neck-pain.nvim", "render-markdown.nvim", "telescope-fzf-native.nvim",
      "telescope-terraform-doc.nvim", "telescope-terraform.nvim", "telescope.nvim",
      "venv-selector.nvim", "vim-dadbod", "vim-dadbod-completion", "vim-dadbod-ui", "vimwiki",
    ] {
      let pin = try #require(lock[plugin]?["commit"])
      #expect(pin.count == 40 && pin.allSatisfy(\.isHexDigit))
    }
    let editor = try artifact("neovim/lua/plugins/editor.lua", in: composition)
    #expect(editor.contains("inlay_hints = { enabled = false }"))
    #expect(editor.contains("progress = { enabled = false }"))
    #expect(editor.contains("<cmd>NoNeckPain<cr>"))
    #expect(editor.contains("<cmd>MarkdownPreviewToggle<cr>"))
    #expect(editor.contains("vim.fn.expand(\"~/vimwiki/\")"))
    #expect(!editor.contains("mkdp_highlight_css"))
    #expect(editor.contains("require(\"config.markdown-preview\").setup()"))
    let preview = try artifact("neovim/lua/config/markdown-preview.lua", in: composition)
    #expect(preview.contains("nvim_get_hl"))
    #expect(preview.contains("\"ColorScheme\""))
    #expect(preview.contains("reload the Markdown preview page"))
    #expect(!preview.contains("catppuccin"))
    for item in composition.artifacts where item.path.hasPrefix("neovim/") {
      let value = String(decoding: item.data, as: UTF8.self)
      #expect(!value.contains("/Users/ramtin"))
      #expect(!value.contains("tuido"))
      #expect(!value.contains("intric-infrastructure"))
    }
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

  @Test(arguments: [0, 17])
  func externalAtuinInitializesWithoutAnInheritedPersonalPath(exitStatus: Int) throws {
    let root = try temporaryDirectory().appending(path: "home with spaces")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let atuinBin = root.appending(path: ".atuin/bin")
    let bin = root.appending(path: "bin")
    for directory in [atuinBin, bin] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let executables = [
      (
        atuinBin.appending(path: "atuin"),
        "#!/bin/sh\necho \"export ATUIN_INITIALIZED=1\"\nexit \(exitStatus)\n"
      ),
      (bin.appending(path: "starship"), "#!/bin/sh\necho \"export STARSHIP_INITIALIZED=1\"\n"),
      (bin.appending(path: "atuin"), "#!/bin/sh\nexit 99\n"),
    ]
    for (url, contents) in executables {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n", source: root.appending(path: "profile.toml"))
    let composition = try composer.compose(
      resourcesRoot: resourcesRoot, profile: profile, stateRoot: root.appending(path: "state"))
    try artifact("zsh/.zshrc", in: composition).write(
      to: root.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = [
      "-c",
      "source .zshrc; startup=$?; print -r -- ${ATUIN_INITIALIZED-0}:${STARSHIP_INITIALIZED-0}:${MACARCHY_MANAGED_SESSION-0}; exit $startup",
    ]
    process.currentDirectoryURL = root
    process.environment = [
      "HOME": root.path, "ZDOTDIR": root.path, "PATH": "\(bin.path):/usr/bin:/bin",
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    #expect((process.terminationStatus == 0) == (exitStatus == 0))
    #expect(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        == (exitStatus == 0 ? "1:1:1\n" : "0:0:0\n"))
  }

  @Test
  func nativeInputsAndStableOptionsProduceSelfContainedArtifacts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let kitty = root.appending(path: "kitty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: kitty, withIntermediateDirectories: true)
    try
      "hide_window_decorations titlebar-and-corners\ninclude bindings.conf\nmap cmd+k clear_terminal scroll active\n"
      .write(
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
    #expect(
      try artifact("kitty/override/kitty.conf", in: composition)
        .contains("hide_window_decorations titlebar-and-corners\n"))
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
    let packagedLock = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: resourcesRoot.appending(path: "neovim/default/lazy-lock.json"))
      ) as? [String: Any]
    )
    var staleLock = lock
    for plugin in ["aether", "catppuccin", "kanagawa.nvim", "tokyonight.nvim"] {
      #expect(lock[plugin] as? [String: String] == packagedLock[plugin] as? [String: String])
      staleLock[plugin] = ["branch": "personal", "commit": "stale"]
    }
    #expect(
      lockData
        == (try JSONSerialization.data(
          withJSONObject: lock,
          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) + Data([0x0A])
    )
    let staleData = try JSONSerialization.data(withJSONObject: staleLock)
    let lockURL = neovim.appending(path: "lazy-lock.json")
    try staleData.write(to: lockURL)
    let repinned = try composer.compose(
      resourcesRoot: resourcesRoot,
      profile: profile,
      stateRoot: root.appending(path: "state")
    )
    #expect(repinned == composition)
    #expect(try Data(contentsOf: lockURL) == staleData)
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

  @Test(arguments: ["[", "[]"])
  func nativeNeovimLockRejectsMalformedJSONAndNonObjects(lock: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (neovim, profile) = try legacyNeovimConfiguration(in: root)
    try Data(lock.utf8).write(to: neovim.appending(path: "lazy-lock.json"))
    let reason =
      lock == "[]"
      ? "Neovim lazy-lock.json must contain an object"
      : "Neovim lazy-lock.json is invalid JSON"

    do {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
      Issue.record("invalid Neovim lock was accepted")
    } catch let error as EnvironmentConfigurationError {
      #expect(error.sourceURL == neovim)
      #expect(
        error.description == EnvironmentConfigurationError.invalid(neovim, reason).description)
    }
  }

  @Test(arguments: [
    "colors/macarchy-imported.lua",
    "lua/config/macarchy-theme.lua",
    "lua/plugins/colorscheme.lua",
  ])
  func legacyNeovimThemeRecognitionRequiresExactBytes(path: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (neovim, profile) = try legacyNeovimConfiguration(in: root)
    let source = neovim.appending(path: path)
    try (Data(contentsOf: source) + Data([0x0A])).write(to: source)

    do {
      _ = try composer.compose(resourcesRoot: resourcesRoot, profile: profile, stateRoot: root)
      Issue.record("modified legacy Neovim theme artifact was accepted")
    } catch let error as EnvironmentConfigurationError {
      #expect(error.sourceURL == neovim)
      #expect(
        error.description
          == EnvironmentConfigurationError.invalid(
            neovim,
            "Neovim configuration has a partial or conflicting reserved theme seam"
          ).description
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
