import Darwin
import Foundation
import TOMLDecoder

package enum DesktopProviderSelection: String, Codable, Sendable {
  case yabaiSkhd = "yabai-skhd"
  case disabled
}

package enum TopBarProviderSelection: String, Codable, Sendable {
  case sketchybar
  case disabled
}

package enum TerminalProviderSelection: String, Codable, Sendable {
  case kitty
  case disabled
}

package enum ShellProviderSelection: String, Codable, Sendable {
  case zsh
  case disabled
}

package enum PromptProviderSelection: String, Codable, Sendable {
  case starship
  case disabled
}

package enum HistoryProviderSelection: String, Codable, Sendable {
  case atuin
  case disabled
}

package enum EditorProviderSelection: String, Codable, Sendable {
  case neovim
  case disabled
}

package enum SketchyBarModule: String, Codable, Hashable, Sendable {
  case spaces
  case clock
  case volume
}

package struct SketchyBarProfileOptions: Equatable, Sendable {
  package let left: [SketchyBarModule]?
  package let center: [SketchyBarModule]?
  package let right: [SketchyBarModule]?
  package let hookURL: URL?
  package let hookRootURL: URL?
}

package struct YabaiProfileOptions: Equatable, Sendable {
  package let layout: String?
  package let splitRatio: Double?
  package let topPadding: Int?
  package let bottomPadding: Int?
  package let leftPadding: Int?
  package let rightPadding: Int?
  package let windowGap: Int?
  package let mouseFollowsFocus: Bool?
  package let hookURL: URL?
}

package struct DesktopProfile: Equatable, Sendable {
  package let provider: DesktopProviderSelection
  package let yabai: YabaiProfileOptions
}

package struct KittyProfileOptions: Equatable, Sendable {
  package let fontFamily: String?
  package let fontSize: Double?
  package let backgroundOpacity: Double?
  package let backgroundBlur: Int?
  package let overrideDirectoryURL: URL?
}

package struct ZshProfileOptions: Equatable, Sendable {
  package let editor: String?
  package let hookURL: URL?
}

package struct StarshipProfileOptions: Equatable, Sendable {
  package let behaviorURL: URL?
}

package struct AtuinProfileOptions: Equatable, Sendable {
  package let searchMode: String?
  package let keymapMode: String?
  package let enterAccept: Bool?
  package let daemon: Bool?
  package let configurationURL: URL?
}

package struct NeovimProfileOptions: Equatable, Sendable {
  package let configurationDirectoryURL: URL?
}

package struct DailyToolsProfile: Equatable, Sendable {
  package let bat: Bool
  package let eza: Bool
  package let btop: Bool
  package let yazi: Bool
}

package struct PresetsProfile: Equatable, Sendable {
  package let pi: Bool
  package let tuicr: Bool
}

package struct BtopProfileOptions: Equatable, Sendable {
  package let vimKeys: Bool?
}

package struct YaziProfileOptions: Equatable, Sendable {
  package let showHidden: Bool?
}

package struct EnvironmentProfile: Equatable, Sendable {
  package let terminal: TerminalProviderSelection
  package let shell: ShellProviderSelection
  package let prompt: PromptProviderSelection
  package let history: HistoryProviderSelection
  package let editor: EditorProviderSelection
  package let kitty: KittyProfileOptions
  package let zsh: ZshProfileOptions
  package let starship: StarshipProfileOptions
  package let atuin: AtuinProfileOptions
  package let neovim: NeovimProfileOptions
  package let tools: DailyToolsProfile
  package let presets: PresetsProfile
  package let btop: BtopProfileOptions
  package let yazi: YaziProfileOptions
}

package struct PortableProfile: Equatable, Sendable {
  package let sourceURL: URL?
  package let keybindings: KeybindingProfile
  package let desktop: DesktopProfile
  package let topBar: TopBarProviderSelection
  package let sketchyBar: SketchyBarProfileOptions
  package let environment: EnvironmentProfile

  package static let defaults = PortableProfile(
    sourceURL: nil,
    keybindings: .empty,
    desktop: DesktopProfile(provider: .yabaiSkhd, yabai: .empty),
    topBar: .sketchybar,
    sketchyBar: .empty,
    environment: .defaults
  )
}

package struct PortableProfileLoader: Sendable {
  package init() {}

  package func load(at source: URL, required: Bool) throws -> PortableProfile {
    var metadata = stat()
    guard lstat(source.path, &metadata) == 0 else {
      if errno == ENOENT, !required { return .defaults }
      throw KeybindingProfileError.cannotRead(source, Self.systemError(errno))
    }

    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: resolved, maximumSize: 65_536).data
    } catch {
      throw KeybindingProfileError.cannotRead(source, String(describing: error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw KeybindingProfileError.invalid(source, "profile is not valid UTF-8")
    }
    return try decode(text, source: source, resolvedSource: resolved)
  }

  package func decode(
    _ text: String,
    source: URL,
    resolvedSource: URL? = nil
  ) throws -> PortableProfile {
    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(
        text: text,
        file: source,
        syntaxRole: "Macarchy profile"
      )
    } catch {
      throw KeybindingProfileError.invalid(source, String(describing: error))
    }

    let allowedTables = Set([
      "keybindings", "desktop", "yabai", "top_bar", "sketchybar",
      "terminal", "kitty", "shell", "zsh", "prompt", "starship", "history", "atuin",
      "editor", "neovim",
      "tools", "presets", "btop", "yazi",
    ])
    if let table = index.tables.first(where: {
      !allowedTables.contains($0.path) || $0.isArray
    }) {
      throw KeybindingProfileError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    let allowedFields = Set([
      "schema_version",
      "keybindings.override",
      "keybindings.metadata",
      "keybindings.disabled",
      "desktop.provider",
      "yabai.layout",
      "yabai.split_ratio",
      "yabai.top_padding",
      "yabai.bottom_padding",
      "yabai.left_padding",
      "yabai.right_padding",
      "yabai.window_gap",
      "yabai.mouse_follows_focus",
      "yabai.hook",
      "top_bar.provider",
      "sketchybar.left",
      "sketchybar.center",
      "sketchybar.right",
      "sketchybar.hook",
      "terminal.provider",
      "kitty.font_family",
      "kitty.font_size",
      "kitty.background_opacity",
      "kitty.background_blur",
      "kitty.override",
      "shell.provider",
      "zsh.editor",
      "zsh.hook",
      "prompt.provider",
      "starship.behavior",
      "history.provider",
      "atuin.search_mode",
      "atuin.keymap_mode",
      "atuin.enter_accept",
      "atuin.daemon",
      "atuin.configuration",
      "editor.provider",
      "neovim.configuration",
      "tools.bat",
      "tools.eza",
      "tools.btop",
      "tools.yazi",
      "presets.pi",
      "presets.tuicr",
      "btop.vim_keys",
      "yazi.show_hidden",
    ])
    if let field = index.fields.first(where: { !allowedFields.contains($0.path) }) {
      throw KeybindingProfileError.invalid(
        source,
        "line \(field.line), column \(field.column): unknown key '\(field.path)'"
      )
    }

    let document: PortableProfileDocument
    do {
      document = try TOMLDecoder().decode(PortableProfileDocument.self, from: text)
    } catch {
      throw KeybindingProfileError.invalid(source, String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw KeybindingProfileError.invalid(
        source,
        "unsupported schema_version \(document.schemaVersion); expected 1"
      )
    }

    let base = (resolvedSource ?? source).standardizedFileURL.deletingLastPathComponent()
    let sourceURL = source.standardizedFileURL
    let keybindings = try keybindings(
      document.keybindings,
      source: sourceURL,
      base: base
    )
    let desktop = try desktop(
      document.desktop,
      yabai: document.yabai,
      source: sourceURL,
      base: base
    )
    let topBar = try topBar(document.topBar, source: sourceURL)
    let sketchyBar = try sketchyBar(document.sketchyBar, source: sourceURL, base: base)
    let environment = try environment(document, source: sourceURL, base: base)
    return PortableProfile(
      sourceURL: sourceURL,
      keybindings: keybindings,
      desktop: desktop,
      topBar: topBar,
      sketchyBar: sketchyBar,
      environment: environment
    )
  }

  private func keybindings(
    _ options: KeybindingsDocument?,
    source: URL,
    base: URL
  ) throws -> KeybindingProfile {
    let disabled = options?.disabled ?? []
    guard disabled.count <= 1_024 else {
      throw KeybindingProfileError.invalid(source, "disabled contains more than 1024 identities")
    }
    guard Set(disabled).count == disabled.count else {
      throw KeybindingProfileError.invalid(source, "disabled identities must be unique")
    }
    let parser = SkhdConfigurationParser()
    if let identity = disabled.first(where: { !parser.isCanonicalIdentity($0) }) {
      throw KeybindingProfileError.invalid(
        source,
        "disabled identity '\(identity)' is not a normalized skhd chord"
      )
    }

    return KeybindingProfile(
      sourceURL: source,
      overrideURL: try options?.override.map {
        try Self.resolvePortablePath(
          $0,
          field: "keybindings.override",
          base: base,
          source: source
        )
      },
      metadataURL: try options?.metadata.map {
        try Self.resolvePortablePath(
          $0,
          field: "keybindings.metadata",
          base: base,
          source: source
        )
      },
      disabledIdentities: disabled
    )
  }

  private func desktop(
    _ document: DesktopDocument?,
    yabai options: YabaiDocument?,
    source: URL,
    base: URL
  ) throws -> DesktopProfile {
    let provider = try selection(
      document?.provider ?? DesktopProviderSelection.yabaiSkhd.rawValue,
      as: DesktopProviderSelection.self,
      field: "desktop.provider",
      source: source
    )
    if let layout = options?.layout, !["bsp", "stack", "float"].contains(layout) {
      throw KeybindingProfileError.invalid(
        source,
        "yabai.layout must be bsp, stack, or float"
      )
    }
    if let ratio = options?.splitRatio, !(0.1...0.9).contains(ratio) {
      throw KeybindingProfileError.invalid(
        source,
        "yabai.split_ratio must be between 0.1 and 0.9"
      )
    }
    for (field, value) in [
      ("top_padding", options?.topPadding),
      ("bottom_padding", options?.bottomPadding),
      ("left_padding", options?.leftPadding),
      ("right_padding", options?.rightPadding),
      ("window_gap", options?.windowGap),
    ] {
      if let value, !(0...256).contains(value) {
        throw KeybindingProfileError.invalid(
          source,
          "yabai.\(field) must be between 0 and 256"
        )
      }
    }

    return DesktopProfile(
      provider: provider,
      yabai: YabaiProfileOptions(
        layout: options?.layout,
        splitRatio: options?.splitRatio,
        topPadding: options?.topPadding,
        bottomPadding: options?.bottomPadding,
        leftPadding: options?.leftPadding,
        rightPadding: options?.rightPadding,
        windowGap: options?.windowGap,
        mouseFollowsFocus: options?.mouseFollowsFocus,
        hookURL: try options?.hook.map {
          try Self.resolvePortablePath(
            $0,
            field: "yabai.hook",
            base: base,
            source: source
          )
        }
      )
    )
  }

  private func topBar(
    _ document: TopBarDocument?,
    source: URL
  ) throws -> TopBarProviderSelection {
    try selection(
      document?.provider ?? TopBarProviderSelection.sketchybar.rawValue,
      as: TopBarProviderSelection.self,
      field: "top_bar.provider",
      source: source
    )
  }

  private func sketchyBar(
    _ document: SketchyBarDocument?,
    source: URL,
    base: URL
  ) throws -> SketchyBarProfileOptions {
    let modules = [document?.left, document?.center, document?.right]
      .compactMap { $0 }
      .flatMap { $0 }
    if Set(modules).count != modules.count {
      throw KeybindingProfileError.invalid(
        source,
        "each explicitly positioned SketchyBar module must be unique"
      )
    }
    let hookURL = try document?.hook.map {
      try Self.resolvePortablePath(
        $0,
        field: "sketchybar.hook",
        base: base,
        source: source
      )
    }
    return SketchyBarProfileOptions(
      left: document?.left,
      center: document?.center,
      right: document?.right,
      hookURL: hookURL,
      hookRootURL: hookURL == nil ? nil : base
    )
  }

  private func environment(
    _ document: PortableProfileDocument,
    source: URL,
    base: URL
  ) throws -> EnvironmentProfile {
    let terminal = try selection(
      document.terminal?.provider ?? TerminalProviderSelection.kitty.rawValue,
      as: TerminalProviderSelection.self,
      field: "terminal.provider",
      source: source
    )
    if terminal == .disabled, document.kitty != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[kitty] cannot customize a disabled terminal provider"
      )
    }

    let shell = try selection(
      document.shell?.provider ?? ShellProviderSelection.zsh.rawValue,
      as: ShellProviderSelection.self,
      field: "shell.provider",
      source: source
    )
    let declaredPrompt = try selection(
      document.prompt?.provider ?? PromptProviderSelection.starship.rawValue,
      as: PromptProviderSelection.self,
      field: "prompt.provider",
      source: source
    )
    let declaredHistory = try selection(
      document.history?.provider ?? HistoryProviderSelection.atuin.rawValue,
      as: HistoryProviderSelection.self,
      field: "history.provider",
      source: source
    )
    let hasShellCustomization =
      document.zsh != nil || document.starship != nil || document.atuin != nil
      || declaredPrompt != .disabled && document.prompt != nil
      || declaredHistory != .disabled && document.history != nil
    if shell == .disabled, hasShellCustomization {
      throw KeybindingProfileError.invalid(
        source,
        "zsh, prompt, and history customization requires shell.provider = \"zsh\""
      )
    }
    if declaredPrompt == .disabled, document.starship != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[starship] cannot customize a disabled prompt provider"
      )
    }
    if declaredHistory == .disabled, document.atuin != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[atuin] cannot customize a disabled history provider"
      )
    }

    let kitty = try kitty(document.kitty, source: source, base: base)
    let zsh = try zsh(document.zsh, source: source, base: base)
    let starship = StarshipProfileOptions(
      behaviorURL: try document.starship?.behavior.map {
        try Self.resolvePortablePath(
          $0,
          field: "starship.behavior",
          base: base,
          source: source
        )
      }
    )
    let atuin = try atuin(document.atuin, source: source, base: base)
    let editor = try selection(
      document.editor?.provider ?? EditorProviderSelection.neovim.rawValue,
      as: EditorProviderSelection.self,
      field: "editor.provider",
      source: source
    )
    if editor == .disabled, document.neovim != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[neovim] cannot customize a disabled editor provider"
      )
    }
    let neovim = NeovimProfileOptions(
      configurationDirectoryURL: try document.neovim?.configuration.map {
        try Self.resolvePortablePath(
          $0,
          field: "neovim.configuration",
          base: base,
          source: source
        )
      }
    )
    let tools = DailyToolsProfile(
      bat: document.tools?.bat ?? true,
      eza: document.tools?.eza ?? true,
      btop: document.tools?.btop ?? true,
      yazi: document.tools?.yazi ?? true
    )
    if !tools.btop, document.btop != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[btop] cannot customize a disabled daily tool"
      )
    }
    if !tools.yazi, document.yazi != nil {
      throw KeybindingProfileError.invalid(
        source,
        "[yazi] cannot customize a disabled daily tool"
      )
    }
    return EnvironmentProfile(
      terminal: terminal,
      shell: shell,
      prompt: shell == .disabled ? .disabled : declaredPrompt,
      history: shell == .disabled ? .disabled : declaredHistory,
      editor: editor,
      kitty: kitty,
      zsh: zsh,
      starship: starship,
      atuin: atuin,
      neovim: neovim,
      tools: tools,
      presets: PresetsProfile(
        pi: document.presets?.pi ?? false,
        tuicr: document.presets?.tuicr ?? false
      ),
      btop: BtopProfileOptions(vimKeys: document.btop?.vimKeys),
      yazi: YaziProfileOptions(showHidden: document.yazi?.showHidden)
    )
  }

  private func kitty(
    _ options: KittyDocument?,
    source: URL,
    base: URL
  ) throws -> KittyProfileOptions {
    if let family = options?.fontFamily {
      guard family == family.trimmingCharacters(in: .whitespacesAndNewlines),
        !family.isEmpty, family.utf8.count <= 128,
        !family.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw KeybindingProfileError.invalid(
          source,
          "kitty.font_family must be a single-line value of at most 128 bytes"
        )
      }
    }
    if let size = options?.fontSize, !(4...96).contains(size) {
      throw KeybindingProfileError.invalid(source, "kitty.font_size must be between 4 and 96")
    }
    if let opacity = options?.backgroundOpacity, !(0...1).contains(opacity) {
      throw KeybindingProfileError.invalid(
        source,
        "kitty.background_opacity must be between 0 and 1"
      )
    }
    if let blur = options?.backgroundBlur, !(0...64).contains(blur) {
      throw KeybindingProfileError.invalid(
        source,
        "kitty.background_blur must be between 0 and 64"
      )
    }
    return KittyProfileOptions(
      fontFamily: options?.fontFamily,
      fontSize: options?.fontSize,
      backgroundOpacity: options?.backgroundOpacity,
      backgroundBlur: options?.backgroundBlur,
      overrideDirectoryURL: try options?.override.map {
        try Self.resolvePortablePath($0, field: "kitty.override", base: base, source: source)
      }
    )
  }

  private func zsh(
    _ options: ZshDocument?,
    source: URL,
    base: URL
  ) throws -> ZshProfileOptions {
    if let editor = options?.editor {
      let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+.-"
      )
      guard !editor.isEmpty, editor.utf8.count <= 128,
        editor.unicodeScalars.allSatisfy(allowed.contains)
      else {
        throw KeybindingProfileError.invalid(
          source,
          "zsh.editor must be an ASCII command name of at most 128 bytes"
        )
      }
    }
    return ZshProfileOptions(
      editor: options?.editor,
      hookURL: try options?.hook.map {
        try Self.resolvePortablePath($0, field: "zsh.hook", base: base, source: source)
      }
    )
  }

  private func atuin(
    _ options: AtuinDocument?,
    source: URL,
    base: URL
  ) throws -> AtuinProfileOptions {
    if let mode = options?.searchMode,
      !["fuzzy", "prefix", "fulltext", "daemon-fuzzy"].contains(mode)
    {
      throw KeybindingProfileError.invalid(
        source,
        "atuin.search_mode must be fuzzy, prefix, fulltext, or daemon-fuzzy"
      )
    }
    if let mode = options?.keymapMode,
      !["emacs", "vim-insert", "vim-normal"].contains(mode)
    {
      throw KeybindingProfileError.invalid(
        source,
        "atuin.keymap_mode must be emacs, vim-insert, or vim-normal"
      )
    }
    return AtuinProfileOptions(
      searchMode: options?.searchMode,
      keymapMode: options?.keymapMode,
      enterAccept: options?.enterAccept,
      daemon: options?.daemon,
      configurationURL: try options?.configuration.map {
        try Self.resolvePortablePath(
          $0,
          field: "atuin.configuration",
          base: base,
          source: source
        )
      }
    )
  }

  private func selection<T: RawRepresentable>(
    _ value: String,
    as type: T.Type,
    field: String,
    source: URL
  ) throws -> T where T.RawValue == String {
    guard let selection = T(rawValue: value) else {
      throw KeybindingProfileError.invalid(
        source,
        "\(field) has unsupported provider '\(value)'"
      )
    }
    return selection
  }

  private static func resolvePortablePath(
    _ path: String,
    field: String,
    base: URL,
    source: URL
  ) throws -> URL {
    guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      throw KeybindingProfileError.invalid(source, "\(field) must be a nonempty relative path")
    }
    guard !NSString(string: path).isAbsolutePath else {
      throw KeybindingProfileError.invalid(source, "\(field) must be a relative path")
    }
    let lexicalBase = base.standardizedFileURL
    let lexicalTarget = lexicalBase.appending(path: path).standardizedFileURL
    let lexicalPrefix = lexicalBase.path.hasSuffix("/") ? lexicalBase.path : lexicalBase.path + "/"
    guard lexicalTarget.path.hasPrefix(lexicalPrefix) else {
      throw KeybindingProfileError.invalid(source, "\(field) must stay beside the profile")
    }
    let resolvedBase = lexicalBase.resolvingSymlinksInPath().standardizedFileURL
    let resolvedTarget = lexicalTarget.resolvingSymlinksInPath().standardizedFileURL
    let resolvedPrefix =
      resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
    guard resolvedTarget.path.hasPrefix(resolvedPrefix) else {
      throw KeybindingProfileError.invalid(
        source,
        "\(field) must not escape the profile directory through a symbolic link"
      )
    }
    return lexicalTarget
  }

  private static func systemError(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}

extension YabaiProfileOptions {
  fileprivate static let empty = YabaiProfileOptions(
    layout: nil,
    splitRatio: nil,
    topPadding: nil,
    bottomPadding: nil,
    leftPadding: nil,
    rightPadding: nil,
    windowGap: nil,
    mouseFollowsFocus: nil,
    hookURL: nil
  )
}

extension SketchyBarProfileOptions {
  fileprivate static let empty = SketchyBarProfileOptions(
    left: nil,
    center: nil,
    right: nil,
    hookURL: nil,
    hookRootURL: nil
  )
}

extension EnvironmentProfile {
  fileprivate static let defaults = EnvironmentProfile(
    terminal: .kitty,
    shell: .zsh,
    prompt: .starship,
    history: .atuin,
    editor: .neovim,
    kitty: KittyProfileOptions(
      fontFamily: nil,
      fontSize: nil,
      backgroundOpacity: nil,
      backgroundBlur: nil,
      overrideDirectoryURL: nil
    ),
    zsh: ZshProfileOptions(editor: nil, hookURL: nil),
    starship: StarshipProfileOptions(behaviorURL: nil),
    atuin: AtuinProfileOptions(
      searchMode: nil,
      keymapMode: nil,
      enterAccept: nil,
      daemon: nil,
      configurationURL: nil
    ),
    neovim: NeovimProfileOptions(configurationDirectoryURL: nil),
    tools: DailyToolsProfile(bat: true, eza: true, btop: true, yazi: true),
    presets: PresetsProfile(pi: false, tuicr: false),
    btop: BtopProfileOptions(vimKeys: nil),
    yazi: YaziProfileOptions(showHidden: nil)
  )
}

private struct PortableProfileDocument: Decodable {
  let schemaVersion: Int
  let keybindings: KeybindingsDocument?
  let desktop: DesktopDocument?
  let yabai: YabaiDocument?
  let topBar: TopBarDocument?
  let sketchyBar: SketchyBarDocument?
  let terminal: TerminalDocument?
  let kitty: KittyDocument?
  let shell: ShellDocument?
  let zsh: ZshDocument?
  let prompt: PromptDocument?
  let starship: StarshipDocument?
  let history: HistoryDocument?
  let atuin: AtuinDocument?
  let editor: EditorDocument?
  let neovim: NeovimDocument?
  let tools: DailyToolsDocument?
  let presets: PresetsDocument?
  let btop: BtopDocument?
  let yazi: YaziDocument?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case keybindings
    case desktop
    case yabai
    case topBar = "top_bar"
    case sketchyBar = "sketchybar"
    case terminal
    case kitty
    case shell
    case zsh
    case prompt
    case starship
    case history
    case atuin
    case editor
    case neovim
    case tools
    case presets
    case btop
    case yazi
  }
}

private struct KeybindingsDocument: Decodable {
  let override: String?
  let metadata: String?
  let disabled: [String]?
}

private struct DesktopDocument: Decodable {
  let provider: String?
}

private struct YabaiDocument: Decodable {
  let layout: String?
  let splitRatio: Double?
  let topPadding: Int?
  let bottomPadding: Int?
  let leftPadding: Int?
  let rightPadding: Int?
  let windowGap: Int?
  let mouseFollowsFocus: Bool?
  let hook: String?

  enum CodingKeys: String, CodingKey {
    case layout
    case splitRatio = "split_ratio"
    case topPadding = "top_padding"
    case bottomPadding = "bottom_padding"
    case leftPadding = "left_padding"
    case rightPadding = "right_padding"
    case windowGap = "window_gap"
    case mouseFollowsFocus = "mouse_follows_focus"
    case hook
  }
}

private struct TopBarDocument: Decodable {
  let provider: String?
}

private struct SketchyBarDocument: Decodable {
  let left: [SketchyBarModule]?
  let center: [SketchyBarModule]?
  let right: [SketchyBarModule]?
  let hook: String?
}

private struct TerminalDocument: Decodable {
  let provider: String?
}

private struct KittyDocument: Decodable {
  let fontFamily: String?
  let fontSize: Double?
  let backgroundOpacity: Double?
  let backgroundBlur: Int?
  let override: String?

  enum CodingKeys: String, CodingKey {
    case fontFamily = "font_family"
    case fontSize = "font_size"
    case backgroundOpacity = "background_opacity"
    case backgroundBlur = "background_blur"
    case override
  }
}

private struct ShellDocument: Decodable {
  let provider: String?
}

private struct ZshDocument: Decodable {
  let editor: String?
  let hook: String?
}

private struct PromptDocument: Decodable {
  let provider: String?
}

private struct StarshipDocument: Decodable {
  let behavior: String?
}

private struct HistoryDocument: Decodable {
  let provider: String?
}

private struct AtuinDocument: Decodable {
  let searchMode: String?
  let keymapMode: String?
  let enterAccept: Bool?
  let daemon: Bool?
  let configuration: String?

  enum CodingKeys: String, CodingKey {
    case searchMode = "search_mode"
    case keymapMode = "keymap_mode"
    case enterAccept = "enter_accept"
    case daemon
    case configuration
  }
}

private struct EditorDocument: Decodable {
  let provider: String?
}

private struct NeovimDocument: Decodable {
  let configuration: String?
}

private struct DailyToolsDocument: Decodable {
  let bat: Bool?
  let eza: Bool?
  let btop: Bool?
  let yazi: Bool?
}

private struct PresetsDocument: Decodable {
  let pi: Bool?
  let tuicr: Bool?
}

private struct BtopDocument: Decodable {
  let vimKeys: Bool?

  enum CodingKeys: String, CodingKey {
    case vimKeys = "vim_keys"
  }
}

private struct YaziDocument: Decodable {
  let showHidden: Bool?

  enum CodingKeys: String, CodingKey {
    case showHidden = "show_hidden"
  }
}
