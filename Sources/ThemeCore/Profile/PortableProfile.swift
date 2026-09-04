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
  package let codex: Bool
  package let herdr: Bool
  package let pi: Bool
  package let slack: Bool
  package let spicetify: Bool
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

package enum PortableProfileLayerKind: String, Sendable {
  case portable
  case machine
}

package struct PortableProfileLayer: Equatable, Sendable {
  package let kind: PortableProfileLayerKind
  package let sourceURL: URL
  package let present: Bool
  package let declaredFields: [String]
}

package struct LayeredPortableProfile: Equatable, Sendable {
  package let profile: PortableProfile
  package let layers: [PortableProfileLayer]
  package let fieldOrigins: [String: PortableProfileLayerKind]
}

package struct PortableProfileLoader: Sendable {
  package init() {}

  private static let allowedTables = Set([
    "keybindings", "desktop", "yabai", "top_bar", "sketchybar",
    "terminal", "kitty", "shell", "zsh", "prompt", "starship", "history", "atuin",
    "editor", "neovim", "tools", "presets", "btop", "yazi",
  ])

  private static let allowedFields = Set([
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
    "presets.codex",
    "presets.herdr",
    "presets.pi",
    "presets.slack",
    "presets.spicetify",
    "presets.tuicr",
    "btop.vim_keys",
    "yazi.show_hidden",
  ])

  package func load(at source: URL, required: Bool) throws -> PortableProfile {
    guard let loaded = try read(at: source, required: required) else { return .defaults }
    return try decode(loaded.text, source: source, resolvedSource: loaded.resolvedSource)
  }

  package func load(
    portableAt portableURL: URL,
    portableRequired: Bool,
    machineAt machineURL: URL,
    machineRequired: Bool
  ) throws -> LayeredPortableProfile {
    let portable = try loadLayer(
      at: portableURL,
      kind: .portable,
      required: portableRequired
    )
    let machine = try loadLayer(
      at: machineURL,
      kind: .machine,
      required: machineRequired
    )
    let merged = try merge(portable: portable, machine: machine)
    var origins: [String: PortableProfileLayerKind] = Dictionary(
      uniqueKeysWithValues: portable.summary.declaredFields.map {
        ($0, PortableProfileLayerKind.portable)
      }
    )
    for field in machine.summary.declaredFields {
      origins[field] = .machine
    }
    return LayeredPortableProfile(
      profile: merged,
      layers: [portable.summary, machine.summary],
      fieldOrigins: origins
    )
  }

  package func decode(
    _ text: String,
    source: URL,
    resolvedSource: URL? = nil
  ) throws -> PortableProfile {
    let index = try sourceIndex(text, source: source)
    return try decode(text, source: source, resolvedSource: resolvedSource, index: index)
  }

  private func decode(
    _ text: String,
    source: URL,
    resolvedSource: URL?,
    index: TOMLSourceIndex
  ) throws -> PortableProfile {
    if let table = index.tables.first(where: {
      !Self.allowedTables.contains($0.path) || $0.isArray
    }) {
      throw KeybindingProfileError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    if let field = index.fields.first(where: { !Self.allowedFields.contains($0.path) }) {
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
    let environment = try environment(
      document,
      declaredTables: Set(index.tables.map(\.path)),
      source: sourceURL,
      base: base
    )
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
    declaredTables: Set<String>,
    source: URL,
    base: URL
  ) throws -> EnvironmentProfile {
    let terminal = try selection(
      document.terminal?.provider ?? TerminalProviderSelection.kitty.rawValue,
      as: TerminalProviderSelection.self,
      field: "terminal.provider",
      source: source
    )
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
    let editor = try selection(
      document.editor?.provider ?? EditorProviderSelection.neovim.rawValue,
      as: EditorProviderSelection.self,
      field: "editor.provider",
      source: source
    )
    let tools = DailyToolsProfile(
      bat: document.tools?.bat ?? true,
      eza: document.tools?.eza ?? true,
      btop: document.tools?.btop ?? true,
      yazi: document.tools?.yazi ?? true
    )
    try validateEnvironment(
      terminal: terminal,
      shell: shell,
      prompt: declaredPrompt,
      history: declaredHistory,
      editor: editor,
      tools: tools,
      declaredTables: declaredTables,
      source: source
    )
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
        codex: document.presets?.codex ?? false,
        herdr: document.presets?.herdr ?? false,
        pi: document.presets?.pi ?? false,
        slack: document.presets?.slack ?? false,
        spicetify: document.presets?.spicetify ?? false,
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

  private struct LoadedSource {
    let text: String
    let resolvedSource: URL
  }

  private struct LoadedLayer {
    let summary: PortableProfileLayer
    let profile: PortableProfile
    let declaredTables: Set<String>
  }

  private func read(at source: URL, required: Bool) throws -> LoadedSource? {
    var metadata = stat()
    guard lstat(source.path, &metadata) == 0 else {
      if errno == ENOENT, !required { return nil }
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
    return LoadedSource(text: text, resolvedSource: resolved)
  }

  private func sourceIndex(_ text: String, source: URL) throws -> TOMLSourceIndex {
    do {
      return try TOMLSourceIndex(
        text: text,
        file: source,
        syntaxRole: "Macarchy profile"
      )
    } catch {
      throw KeybindingProfileError.invalid(source, String(describing: error))
    }
  }

  private func loadLayer(
    at source: URL,
    kind: PortableProfileLayerKind,
    required: Bool
  ) throws -> LoadedLayer {
    guard let loaded = try read(at: source, required: required) else {
      return LoadedLayer(
        summary: PortableProfileLayer(
          kind: kind,
          sourceURL: source.standardizedFileURL,
          present: false,
          declaredFields: []
        ),
        profile: .defaults,
        declaredTables: []
      )
    }
    let index = try sourceIndex(loaded.text, source: source)
    let profile = try decode(
      loaded.text,
      source: source,
      resolvedSource: loaded.resolvedSource,
      index: index
    )
    return LoadedLayer(
      summary: PortableProfileLayer(
        kind: kind,
        sourceURL: source.standardizedFileURL,
        present: true,
        declaredFields: index.fields.map(\.path).filter { $0 != "schema_version" }.sorted()
      ),
      profile: profile,
      declaredTables: Set(index.tables.map(\.path))
    )
  }

  private func merge(
    portable: LoadedLayer,
    machine: LoadedLayer
  ) throws -> PortableProfile {
    let machineFields = Set(machine.summary.declaredFields)
    let portableFields = Set(portable.summary.declaredFields)
    func value<T>(_ field: String, _ portableValue: T, _ machineValue: T) -> T {
      machineFields.contains(field) ? machineValue : portableValue
    }
    func declaredValue<T>(
      _ field: String,
      _ portableValue: T,
      _ machineValue: T,
      default defaultValue: T
    ) -> T {
      if machineFields.contains(field) { return machineValue }
      if portableFields.contains(field) { return portableValue }
      return defaultValue
    }

    let portableProfile = portable.profile
    let machineProfile = machine.profile
    let sourceURL =
      machine.summary.present
      ? machine.summary.sourceURL
      : portableProfile.sourceURL
    let keybindingSourceURL =
      machineFields.contains { $0.hasPrefix("keybindings.") }
      ? machine.summary.sourceURL
      : portableProfile.keybindings.sourceURL
    let keybindings = KeybindingProfile(
      sourceURL: keybindingSourceURL,
      overrideURL: value(
        "keybindings.override",
        portableProfile.keybindings.overrideURL,
        machineProfile.keybindings.overrideURL
      ),
      metadataURL: value(
        "keybindings.metadata",
        portableProfile.keybindings.metadataURL,
        machineProfile.keybindings.metadataURL
      ),
      disabledIdentities: value(
        "keybindings.disabled",
        portableProfile.keybindings.disabledIdentities,
        machineProfile.keybindings.disabledIdentities
      )
    )
    let yabai = YabaiProfileOptions(
      layout: value(
        "yabai.layout", portableProfile.desktop.yabai.layout, machineProfile.desktop.yabai.layout),
      splitRatio: value(
        "yabai.split_ratio",
        portableProfile.desktop.yabai.splitRatio,
        machineProfile.desktop.yabai.splitRatio
      ),
      topPadding: value(
        "yabai.top_padding",
        portableProfile.desktop.yabai.topPadding,
        machineProfile.desktop.yabai.topPadding
      ),
      bottomPadding: value(
        "yabai.bottom_padding",
        portableProfile.desktop.yabai.bottomPadding,
        machineProfile.desktop.yabai.bottomPadding
      ),
      leftPadding: value(
        "yabai.left_padding",
        portableProfile.desktop.yabai.leftPadding,
        machineProfile.desktop.yabai.leftPadding
      ),
      rightPadding: value(
        "yabai.right_padding",
        portableProfile.desktop.yabai.rightPadding,
        machineProfile.desktop.yabai.rightPadding
      ),
      windowGap: value(
        "yabai.window_gap",
        portableProfile.desktop.yabai.windowGap,
        machineProfile.desktop.yabai.windowGap
      ),
      mouseFollowsFocus: value(
        "yabai.mouse_follows_focus",
        portableProfile.desktop.yabai.mouseFollowsFocus,
        machineProfile.desktop.yabai.mouseFollowsFocus
      ),
      hookURL: value(
        "yabai.hook", portableProfile.desktop.yabai.hookURL, machineProfile.desktop.yabai.hookURL)
    )
    let sketchyBarHookFromMachine = machineFields.contains("sketchybar.hook")
    let sketchyBar = SketchyBarProfileOptions(
      left: value(
        "sketchybar.left", portableProfile.sketchyBar.left, machineProfile.sketchyBar.left),
      center: value(
        "sketchybar.center", portableProfile.sketchyBar.center, machineProfile.sketchyBar.center),
      right: value(
        "sketchybar.right", portableProfile.sketchyBar.right, machineProfile.sketchyBar.right),
      hookURL: value(
        "sketchybar.hook",
        portableProfile.sketchyBar.hookURL,
        machineProfile.sketchyBar.hookURL
      ),
      hookRootURL: sketchyBarHookFromMachine
        ? machineProfile.sketchyBar.hookRootURL
        : portableProfile.sketchyBar.hookRootURL
    )

    let declaredPrompt = declaredValue(
      "prompt.provider",
      portableProfile.environment.prompt,
      machineProfile.environment.prompt,
      default: PortableProfile.defaults.environment.prompt
    )
    let declaredHistory = declaredValue(
      "history.provider",
      portableProfile.environment.history,
      machineProfile.environment.history,
      default: PortableProfile.defaults.environment.history
    )
    let shell = value(
      "shell.provider",
      portableProfile.environment.shell,
      machineProfile.environment.shell
    )
    let tools = DailyToolsProfile(
      bat: value(
        "tools.bat", portableProfile.environment.tools.bat, machineProfile.environment.tools.bat),
      eza: value(
        "tools.eza", portableProfile.environment.tools.eza, machineProfile.environment.tools.eza),
      btop: value(
        "tools.btop", portableProfile.environment.tools.btop, machineProfile.environment.tools.btop),
      yazi: value(
        "tools.yazi", portableProfile.environment.tools.yazi, machineProfile.environment.tools.yazi)
    )
    let terminal = value(
      "terminal.provider",
      portableProfile.environment.terminal,
      machineProfile.environment.terminal
    )
    let editor = value(
      "editor.provider",
      portableProfile.environment.editor,
      machineProfile.environment.editor
    )
    let declaredTables = portable.declaredTables.union(machine.declaredTables)
    try validateEnvironment(
      terminal: terminal,
      shell: shell,
      prompt: declaredPrompt,
      history: declaredHistory,
      editor: editor,
      tools: tools,
      declaredTables: declaredTables,
      source: sourceURL ?? portable.summary.sourceURL
    )
    let environment = EnvironmentProfile(
      terminal: terminal,
      shell: shell,
      prompt: shell == .disabled ? .disabled : declaredPrompt,
      history: shell == .disabled ? .disabled : declaredHistory,
      editor: editor,
      kitty: KittyProfileOptions(
        fontFamily: value(
          "kitty.font_family",
          portableProfile.environment.kitty.fontFamily,
          machineProfile.environment.kitty.fontFamily
        ),
        fontSize: value(
          "kitty.font_size",
          portableProfile.environment.kitty.fontSize,
          machineProfile.environment.kitty.fontSize
        ),
        backgroundOpacity: value(
          "kitty.background_opacity",
          portableProfile.environment.kitty.backgroundOpacity,
          machineProfile.environment.kitty.backgroundOpacity
        ),
        backgroundBlur: value(
          "kitty.background_blur",
          portableProfile.environment.kitty.backgroundBlur,
          machineProfile.environment.kitty.backgroundBlur
        ),
        overrideDirectoryURL: value(
          "kitty.override",
          portableProfile.environment.kitty.overrideDirectoryURL,
          machineProfile.environment.kitty.overrideDirectoryURL
        )
      ),
      zsh: ZshProfileOptions(
        editor: value(
          "zsh.editor", portableProfile.environment.zsh.editor,
          machineProfile.environment.zsh.editor),
        hookURL: value(
          "zsh.hook", portableProfile.environment.zsh.hookURL,
          machineProfile.environment.zsh.hookURL)
      ),
      starship: StarshipProfileOptions(
        behaviorURL: value(
          "starship.behavior",
          portableProfile.environment.starship.behaviorURL,
          machineProfile.environment.starship.behaviorURL
        )
      ),
      atuin: AtuinProfileOptions(
        searchMode: value(
          "atuin.search_mode",
          portableProfile.environment.atuin.searchMode,
          machineProfile.environment.atuin.searchMode
        ),
        keymapMode: value(
          "atuin.keymap_mode",
          portableProfile.environment.atuin.keymapMode,
          machineProfile.environment.atuin.keymapMode
        ),
        enterAccept: value(
          "atuin.enter_accept",
          portableProfile.environment.atuin.enterAccept,
          machineProfile.environment.atuin.enterAccept
        ),
        daemon: value(
          "atuin.daemon",
          portableProfile.environment.atuin.daemon,
          machineProfile.environment.atuin.daemon
        ),
        configurationURL: value(
          "atuin.configuration",
          portableProfile.environment.atuin.configurationURL,
          machineProfile.environment.atuin.configurationURL
        )
      ),
      neovim: NeovimProfileOptions(
        configurationDirectoryURL: value(
          "neovim.configuration",
          portableProfile.environment.neovim.configurationDirectoryURL,
          machineProfile.environment.neovim.configurationDirectoryURL
        )
      ),
      tools: tools,
      presets: PresetsProfile(
        codex: value(
          "presets.codex", portableProfile.environment.presets.codex,
          machineProfile.environment.presets.codex),
        herdr: value(
          "presets.herdr", portableProfile.environment.presets.herdr,
          machineProfile.environment.presets.herdr),
        pi: value(
          "presets.pi", portableProfile.environment.presets.pi,
          machineProfile.environment.presets.pi),
        slack: value(
          "presets.slack", portableProfile.environment.presets.slack,
          machineProfile.environment.presets.slack),
        spicetify: value(
          "presets.spicetify",
          portableProfile.environment.presets.spicetify,
          machineProfile.environment.presets.spicetify
        ),
        tuicr: value(
          "presets.tuicr", portableProfile.environment.presets.tuicr,
          machineProfile.environment.presets.tuicr)
      ),
      btop: BtopProfileOptions(
        vimKeys: value(
          "btop.vim_keys",
          portableProfile.environment.btop.vimKeys,
          machineProfile.environment.btop.vimKeys
        )
      ),
      yazi: YaziProfileOptions(
        showHidden: value(
          "yazi.show_hidden",
          portableProfile.environment.yazi.showHidden,
          machineProfile.environment.yazi.showHidden
        )
      )
    )
    let result = PortableProfile(
      sourceURL: sourceURL,
      keybindings: keybindings,
      desktop: DesktopProfile(
        provider: value(
          "desktop.provider", portableProfile.desktop.provider, machineProfile.desktop.provider),
        yabai: yabai
      ),
      topBar: value("top_bar.provider", portableProfile.topBar, machineProfile.topBar),
      sketchyBar: sketchyBar,
      environment: environment
    )
    return result
  }

  private func validateEnvironment(
    terminal: TerminalProviderSelection,
    shell: ShellProviderSelection,
    prompt: PromptProviderSelection,
    history: HistoryProviderSelection,
    editor: EditorProviderSelection,
    tools: DailyToolsProfile,
    declaredTables: Set<String>,
    source: URL
  ) throws {
    if terminal == .disabled, declaredTables.contains("kitty") {
      throw KeybindingProfileError.invalid(
        source,
        "[kitty] cannot customize a disabled terminal provider"
      )
    }
    let hasShellCustomization =
      declaredTables.contains("zsh")
      || declaredTables.contains("starship")
      || declaredTables.contains("atuin")
      || prompt != .disabled && declaredTables.contains("prompt")
      || history != .disabled && declaredTables.contains("history")
    if shell == .disabled, hasShellCustomization {
      throw KeybindingProfileError.invalid(
        source,
        "zsh, prompt, and history customization requires shell.provider = \"zsh\""
      )
    }
    if prompt == .disabled, declaredTables.contains("starship") {
      throw KeybindingProfileError.invalid(
        source,
        "[starship] cannot customize a disabled prompt provider"
      )
    }
    if history == .disabled, declaredTables.contains("atuin") {
      throw KeybindingProfileError.invalid(
        source,
        "[atuin] cannot customize a disabled history provider"
      )
    }
    if editor == .disabled, declaredTables.contains("neovim") {
      throw KeybindingProfileError.invalid(
        source,
        "[neovim] cannot customize a disabled editor provider"
      )
    }
    if !tools.btop, declaredTables.contains("btop") {
      throw KeybindingProfileError.invalid(source, "[btop] cannot customize a disabled daily tool")
    }
    if !tools.yazi, declaredTables.contains("yazi") {
      throw KeybindingProfileError.invalid(source, "[yazi] cannot customize a disabled daily tool")
    }
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
    presets: PresetsProfile(
      codex: false,
      herdr: false,
      pi: false,
      slack: false,
      spicetify: false,
      tuicr: false
    ),
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
  let codex: Bool?
  let herdr: Bool?
  let pi: Bool?
  let slack: Bool?
  let spicetify: Bool?
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
