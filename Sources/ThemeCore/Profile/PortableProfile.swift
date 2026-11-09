import Darwin
import Foundation
import TOMLDecoder

package enum DesktopProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case yabaiSkhd = "yabai-skhd"
  case disabled

  package static let table = "desktop"
  package static let defaults = Self.yabaiSkhd
}

package enum TopBarProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case sketchybar
  case disabled

  package static let table = "top_bar"
  package static let defaults = Self.sketchybar
}

package enum FocusRingProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case borders
  case lean
  case disabled

  package static let table = "focus_ring"
  package static let defaults = Self.borders
}

package enum TerminalProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case kitty
  case disabled

  package static let table = "terminal"
  package static let defaults = Self.kitty
}

package enum ShellProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case zsh
  case disabled

  package static let table = "shell"
  package static let defaults = Self.zsh
}

package enum PromptProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case starship
  case disabled

  package static let table = "prompt"
  package static let defaults = Self.starship
}

package enum HistoryProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case atuin
  case disabled

  package static let table = "history"
  package static let defaults = Self.atuin
}

package enum EditorProviderSelection: String, Codable, Sendable, PortableProfileProvider {
  case neovim
  case disabled

  package static let table = "editor"
  package static let defaults = Self.neovim
}

package enum SketchyBarModule: String, CaseIterable, Codable, Hashable, Sendable {
  case spaces
  case clock
  case volume
  case battery
  case cpu
  case memory
  case wifi
  case media
  case apple
  case toggle
}

package struct SketchyBarProfileOptions: Equatable, Sendable {
  package var left: [SketchyBarModule]?
  package var center: [SketchyBarModule]?
  package var right: [SketchyBarModule]?
  package var automaticClock: Bool?
  package var hookURL: URL?
  package var hookRootURL: URL?
  package var configurationURL: URL? = nil
  package var configurationRootURL: URL? = nil
}

extension SketchyBarProfileOptions: PortableProfileSection {
  package static let table = "sketchybar"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("left", \.left),
      .init("center", \.center),
      .init("right", \.right),
      .init("automatic_clock", \.automaticClock),
      .init("hook", \.hookURL, \.hookRootURL),
      .init("configuration", \.configurationURL, \.configurationRootURL),
    ]
  }

  /// An explicit automatic clock needs a clock module in the resolved layout.
  package func automaticClockConflict(clockEnabled: Bool) -> String? {
    automaticClock == true && !clockEnabled
      ? "automatic_clock requires an enabled clock module" : nil
  }
}

package struct YabaiProfileOptions: Equatable, Sendable {
  package var layout: String?
  package var splitRatio: Double?
  package var topPadding: Int?
  package var bottomPadding: Int?
  package var leftPadding: Int?
  package var rightPadding: Int?
  package var windowGap: Int?
  package var mouseFollowsFocus: Bool?
  package var hookURL: URL?
  package var configurationURL: URL? = nil
}

extension YabaiProfileOptions: PortableProfileSection {
  package static let table = "yabai"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("layout", \.layout),
      .init("split_ratio", \.splitRatio),
      .init("top_padding", \.topPadding),
      .init("bottom_padding", \.bottomPadding),
      .init("left_padding", \.leftPadding),
      .init("right_padding", \.rightPadding),
      .init("window_gap", \.windowGap),
      .init("mouse_follows_focus", \.mouseFollowsFocus),
      .init("hook", \.hookURL),
      .init("configuration", \.configurationURL),
    ]
  }

  /// Bounds shared by the profile and the bundled yabai defaults.
  package static let supportedLayouts = ["bsp", "stack", "float"]
  package static let splitRatioRange = 0.1...0.9
  package static let spacingRange = 0...256
}

package struct DesktopProfile: Equatable, Sendable {
  package var provider: DesktopProviderSelection
  package var yabai: YabaiProfileOptions
}

package struct KittyProfileOptions: Equatable, Sendable {
  package var fontFamily: String?
  package var fontSize: Double?
  package var backgroundOpacity: Double?
  package var backgroundBlur: Int?
  package var overrideDirectoryURL: URL?
  package var configurationURL: URL? = nil
}

extension KittyProfileOptions: PortableProfileSection {
  package static let table = "kitty"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("font_family", \.fontFamily),
      .init("font_size", \.fontSize),
      .init("background_opacity", \.backgroundOpacity),
      .init("background_blur", \.backgroundBlur),
      .init("override", \.overrideDirectoryURL),
      .init("configuration", \.configurationURL),
    ]
  }

  /// A native configuration replaces the copied override directory, so only one may be set.
  package var sourceConflict: String? {
    configurationURL != nil && overrideDirectoryURL != nil
      ? "kitty.configuration and kitty.override are mutually exclusive" : nil
  }
}

package struct ZshProfileOptions: Equatable, Sendable {
  package var editor: String?
  package var hookURL: URL?
  package var configurationURL: URL? = nil
}

extension ZshProfileOptions: PortableProfileSection {
  package static let table = "zsh"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("editor", \.editor),
      .init("hook", \.hookURL),
      .init("configuration", \.configurationURL),
    ]
  }

  /// A native configuration replaces the copied hook, so only one may be set.
  package var sourceConflict: String? {
    configurationURL != nil && hookURL != nil
      ? "zsh.configuration and zsh.hook are mutually exclusive" : nil
  }
}

package struct StarshipProfileOptions: Equatable, Sendable {
  package var behaviorURL: URL?
  package var nativeConfigurationURL: URL? = nil
}

extension StarshipProfileOptions: PortableProfileSection {
  package static let table = "starship"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("behavior", \.behaviorURL),
      .init("native_configuration", \.nativeConfigurationURL),
    ]
  }

  /// A native configuration replaces the copied behavior file, so only one may be set.
  package var sourceConflict: String? {
    nativeConfigurationURL != nil && behaviorURL != nil
      ? "starship.native_configuration cannot be combined with starship.behavior" : nil
  }
}

package struct AtuinProfileOptions: Equatable, Sendable {
  package var searchMode: String?
  package var keymapMode: String?
  package var enterAccept: Bool?
  package var daemon: Bool?
  package var configurationURL: URL?
  package var nativeConfigurationURL: URL? = nil
}

extension AtuinProfileOptions: PortableProfileSection {
  package static let table = "atuin"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("search_mode", \.searchMode),
      .init("keymap_mode", \.keymapMode),
      .init("enter_accept", \.enterAccept),
      .init("daemon", \.daemon),
      .init("configuration", \.configurationURL),
      .init("native_configuration", \.nativeConfigurationURL),
    ]
  }

  /// A native configuration owns every Atuin setting, so copied behavior cannot join it.
  package var sourceConflict: String? {
    let copiesBehavior =
      configurationURL != nil || searchMode != nil || keymapMode != nil
      || enterAccept != nil || daemon != nil
    return nativeConfigurationURL != nil && copiesBehavior
      ? "atuin.native_configuration cannot be combined with copied Atuin behavior options" : nil
  }
}

package struct NeovimProfileOptions: Equatable, Sendable {
  package var configurationDirectoryURL: URL?
  package var nativeConfigurationDirectoryURL: URL? = nil
}

extension NeovimProfileOptions: PortableProfileSection {
  package static let table = "neovim"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("configuration", \.configurationDirectoryURL),
      .init("native_configuration", \.nativeConfigurationDirectoryURL),
    ]
  }
}

package struct DailyToolsProfile: Equatable, Sendable {
  package var bat: Bool
  package var eza: Bool
  package var btop: Bool
  package var yazi: Bool
}

extension DailyToolsProfile: PortableProfileSection {
  package static let table = "tools"
  package static let defaults = Self(bat: true, eza: true, btop: true, yazi: true)
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("bat", \.bat),
      .init("eza", \.eza),
      .init("btop", \.btop),
      .init("yazi", \.yazi),
    ]
  }
}

package struct PresetsProfile: Equatable, Sendable {
  package var codex: Bool
  package var herdr: Bool
  package var pi: Bool
  package var slack: Bool
  package var spicetify: Bool
  package var tuicr: Bool
  package var ghostty: Bool = false
  package var zed: Bool = false
  package var alacritty: Bool = false
  package var vscode: Bool = false
  package var cursor: Bool = false
  package var vscodium: Bool = false
  package var windsurf: Bool = false
}

extension PresetsProfile: PortableProfileSection {
  package static let table = "presets"
  package static let defaults = Self(
    codex: false, herdr: false, pi: false, slack: false, spicetify: false, tuicr: false)
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("codex", \.codex),
      .init("herdr", \.herdr),
      .init("pi", \.pi),
      .init("slack", \.slack),
      .init("spicetify", \.spicetify),
      .init("tuicr", \.tuicr),
      .init("ghostty", \.ghostty),
      .init("zed", \.zed),
      .init("alacritty", \.alacritty),
      .init("vscode", \.vscode),
      .init("cursor", \.cursor),
      .init("vscodium", \.vscodium),
      .init("windsurf", \.windsurf),
    ]
  }
}

package struct BtopProfileOptions: Equatable, Sendable {
  package var vimKeys: Bool?
}

extension BtopProfileOptions: PortableProfileSection {
  package static let table = "btop"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] { [.init("vim_keys", \.vimKeys)] }
}

package struct YaziProfileOptions: Equatable, Sendable {
  package var showHidden: Bool?
}

extension YaziProfileOptions: PortableProfileSection {
  package static let table = "yazi"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] { [.init("show_hidden", \.showHidden)] }
}

package struct UserScriptsProfile: Equatable, Sendable, PortableProfileSection {
  package var run: [URL] = []
  package static let defaults = Self()
  package static let table = "scripts"
  package static var fields: [PortableProfileField<Self>] { [.init("run", \.run)] }
}

package struct MacOSLookProfile: Equatable, Sendable, PortableProfileSection {
  package var accent = false
  package static let defaults = Self()
  package static let table = "macos_look"
  package static var fields: [PortableProfileField<Self>] { [.init("accent", \.accent)] }
}

package struct EnvironmentProfile: Equatable, Sendable {
  package var macOSLook: MacOSLookProfile = .defaults
  package var scripts: UserScriptsProfile = .defaults
  package var focusRing: FocusRingProviderSelection
  package var terminal: TerminalProviderSelection
  package var shell: ShellProviderSelection
  package var prompt: PromptProviderSelection
  package var history: HistoryProviderSelection
  package var editor: EditorProviderSelection
  package var kitty: KittyProfileOptions
  package var zsh: ZshProfileOptions
  package var starship: StarshipProfileOptions
  package var atuin: AtuinProfileOptions
  package var neovim: NeovimProfileOptions
  package var tools: DailyToolsProfile
  package var presets: PresetsProfile
  package var btop: BtopProfileOptions
  package var yazi: YaziProfileOptions

  fileprivate static let defaults = EnvironmentProfile(
    focusRing: .defaults,
    terminal: .defaults,
    shell: .defaults,
    prompt: .defaults,
    history: .defaults,
    editor: .defaults,
    kitty: .defaults,
    zsh: .defaults,
    starship: .defaults,
    atuin: .defaults,
    neovim: .defaults,
    tools: .defaults,
    presets: .defaults,
    btop: .defaults,
    yazi: .defaults
  )

  /// Prompt and history run inside the managed shell, so a disabled shell disables both.
  fileprivate mutating func disableShellHostedRoles() {
    guard shell == .disabled else { return }
    prompt = .disabled
    history = .disabled
  }
}

package struct PortableProfile: Equatable, Sendable {
  package var sourceURL: URL?
  package var keybindings: KeybindingProfile
  package var desktop: DesktopProfile
  package var topBar: TopBarProviderSelection
  package var sketchyBar: SketchyBarProfileOptions
  package var environment: EnvironmentProfile
  package var packages: PackageProfile
  package var macOSPreferences: MacOSPreferencesProfile

  package static let defaults = PortableProfile(
    sourceURL: nil,
    keybindings: .defaults,
    desktop: DesktopProfile(provider: .defaults, yabai: .defaults),
    topBar: .defaults,
    sketchyBar: .defaults,
    environment: .defaults,
    packages: .defaults,
    macOSPreferences: .defaults
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

package enum PortableProfileError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL, String)
  case invalid(URL, String)

  package var description: String {
    switch self {
    case .cannotRead(let source, let reason):
      "\(source.path): cannot read Macarchy profile: \(reason)"
    case .invalid(let source, let reason):
      "\(source.path): invalid Macarchy profile: \(reason)"
    }
  }
}

package struct PortableProfileLoader: Sendable {
  private let proposedSources: [URL: String]

  /// Preview approved source edits through the same decoding and layering path.
  package init(proposedSources: [URL: String] = [:]) {
    self.proposedSources = proposedSources
  }

  private static let allowedTables = Set(PortableProfile.tables.map(\.name))

  private static let allowedFields = Set(
    ["schema_version"] + PortableProfile.tables.flatMap(\.fields))

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
    // These inputs contribute by package identity; no single field wins.
    // Keep both layer summaries and let the package compiler report provenance.
    for field in PortableProfile.tables.flatMap(\.contributedFields) {
      origins.removeValue(forKey: field)
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
    index: TOMLSourceIndex,
    layerKind: PortableProfileLayerKind = .portable
  ) throws -> PortableProfile {
    if let reason = index.firstUnknownEntry(
      allowsTable: { Self.allowedTables.contains($0.path) && !$0.isArray },
      allowedFields: Self.allowedFields)
    {
      throw PortableProfileError.invalid(source, reason)
    }

    let document: PortableProfileDocument
    do {
      document = try TOMLDecoder().decode(PortableProfileDocument.self, from: text)
    } catch {
      throw PortableProfileError.invalid(source, String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw PortableProfileError.invalid(
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
    let topBar: TopBarProviderSelection = try provider(document.topBar, source: sourceURL)
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
      environment: environment,
      packages: try packages(document.packages, kind: layerKind, source: sourceURL, base: base),
      macOSPreferences: document.macOSPreferences ?? .defaults
    )
  }

  private func packages(
    _ document: PackagesDocument?, kind: PortableProfileLayerKind, source: URL, base: URL
  ) throws -> PackageProfile {
    guard let document else { return .defaults }
    return PackageProfile(
      baseline: document.baseline ?? PackageProfile.defaults.baseline,
      layers: [
        .init(
          kind: kind, sourceURL: source,
          brewfileURL: try Self.resolvePortablePath(
            document.brewfile, field: "packages.brewfile", base: base, source: source),
          excludedFormulae: document.excludeFormulae ?? [],
          excludedCasks: document.excludeCasks ?? [])
      ])
  }

  private func keybindings(
    _ options: KeybindingsDocument?,
    source: URL,
    base: URL
  ) throws -> KeybindingProfile {
    let disabled = options?.disabled ?? []
    guard disabled.count <= 1_024 else {
      throw PortableProfileError.invalid(source, "disabled contains more than 1024 identities")
    }
    guard Set(disabled).count == disabled.count else {
      throw PortableProfileError.invalid(source, "disabled identities must be unique")
    }
    let parser = SkhdConfigurationParser()
    if let identity = disabled.first(where: { !parser.isCanonicalIdentity($0) }) {
      throw PortableProfileError.invalid(
        source,
        "disabled identity '\(identity)' is not a normalized skhd chord"
      )
    }

    return KeybindingProfile(
      sourceURL: source,
      overrideURL: try Self.resolvePortablePath(
        options?.override, field: "keybindings.override", base: base, source: source),
      metadataURL: try Self.resolvePortablePath(
        options?.metadata, field: "keybindings.metadata", base: base, source: source),
      disabledIdentities: disabled
    )
  }

  private func desktop(
    _ document: ProviderDocument?,
    yabai options: YabaiDocument?,
    source: URL,
    base: URL
  ) throws -> DesktopProfile {
    let provider: DesktopProviderSelection = try self.provider(document, source: source)
    if let layout = options?.layout, !YabaiProfileOptions.supportedLayouts.contains(layout) {
      throw PortableProfileError.invalid(
        source,
        "yabai.layout must be bsp, stack, or float"
      )
    }
    if let ratio = options?.splitRatio, !YabaiProfileOptions.splitRatioRange.contains(ratio) {
      throw PortableProfileError.invalid(
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
      if let value, !YabaiProfileOptions.spacingRange.contains(value) {
        throw PortableProfileError.invalid(
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
        hookURL: try Self.resolvePortablePath(
          options?.hook, field: "yabai.hook", base: base, source: source),
        configurationURL: try Self.resolvePortablePath(
          options?.configuration, field: "yabai.configuration", base: base, source: source)
      )
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
      throw PortableProfileError.invalid(
        source,
        "each explicitly positioned SketchyBar module must be unique"
      )
    }
    let hookURL = try Self.resolvePortablePath(
      document?.hook, field: "sketchybar.hook", base: base, source: source)
    return SketchyBarProfileOptions(
      left: document?.left,
      center: document?.center,
      right: document?.right,
      automaticClock: document?.automaticClock,
      hookURL: hookURL,
      hookRootURL: hookURL == nil ? nil : base,
      configurationURL: try Self.resolvePortablePath(
        document?.configuration, field: "sketchybar.configuration", base: base, source: source),
      configurationRootURL: document?.configuration == nil ? nil : base
    )
  }

  private func environment(
    _ document: PortableProfileDocument,
    declaredTables: Set<String>,
    source: URL,
    base: URL
  ) throws -> EnvironmentProfile {
    let terminal: TerminalProviderSelection = try provider(document.terminal, source: source)
    let shell: ShellProviderSelection = try provider(document.shell, source: source)
    let prompt: PromptProviderSelection = try provider(document.prompt, source: source)
    let history: HistoryProviderSelection = try provider(document.history, source: source)
    let editor: EditorProviderSelection = try provider(document.editor, source: source)
    let tools = DailyToolsProfile(
      bat: document.tools?.bat ?? DailyToolsProfile.defaults.bat,
      eza: document.tools?.eza ?? DailyToolsProfile.defaults.eza,
      btop: document.tools?.btop ?? DailyToolsProfile.defaults.btop,
      yazi: document.tools?.yazi ?? DailyToolsProfile.defaults.yazi
    )
    try validateEnvironment(
      terminal: terminal,
      shell: shell,
      prompt: prompt,
      history: history,
      editor: editor,
      tools: tools,
      declaredTables: declaredTables,
      source: source
    )
    let kitty = try kitty(document.kitty, source: source, base: base)
    let zsh = try zsh(document.zsh, source: source, base: base)
    let starship = StarshipProfileOptions(
      behaviorURL: try Self.resolvePortablePath(
        document.starship?.behavior, field: "starship.behavior", base: base, source: source),
      nativeConfigurationURL: try Self.resolveNativeSourcePath(
        document.starship?.nativeConfiguration,
        field: "starship.native_configuration", base: base, source: source)
    )
    let atuin = try atuin(document.atuin, source: source, base: base)
    let neovim = NeovimProfileOptions(
      configurationDirectoryURL: try Self.resolvePortablePath(
        document.neovim?.configuration, field: "neovim.configuration", base: base, source: source),
      nativeConfigurationDirectoryURL: try Self.resolveNativeSourcePath(
        document.neovim?.nativeConfiguration,
        field: "neovim.native_configuration", base: base, source: source)
    )
    var environment = EnvironmentProfile(
      macOSLook: MacOSLookProfile(accent: document.macOSLook?.accent ?? false),
      scripts: try scripts(document.scripts, source: source, base: base),
      focusRing: try provider(document.focusRing, source: source),
      terminal: terminal,
      shell: shell,
      prompt: prompt,
      history: history,
      editor: editor,
      kitty: kitty,
      zsh: zsh,
      starship: starship,
      atuin: atuin,
      neovim: neovim,
      tools: tools,
      presets: PresetsProfile(
        codex: document.presets?.codex ?? PresetsProfile.defaults.codex,
        herdr: document.presets?.herdr ?? PresetsProfile.defaults.herdr,
        pi: document.presets?.pi ?? PresetsProfile.defaults.pi,
        slack: document.presets?.slack ?? PresetsProfile.defaults.slack,
        spicetify: document.presets?.spicetify ?? PresetsProfile.defaults.spicetify,
        tuicr: document.presets?.tuicr ?? PresetsProfile.defaults.tuicr,
        ghostty: document.presets?.ghostty ?? PresetsProfile.defaults.ghostty,
        zed: document.presets?.zed ?? PresetsProfile.defaults.zed,
        alacritty: document.presets?.alacritty ?? PresetsProfile.defaults.alacritty,
        vscode: document.presets?.vscode ?? PresetsProfile.defaults.vscode,
        cursor: document.presets?.cursor ?? PresetsProfile.defaults.cursor,
        vscodium: document.presets?.vscodium ?? PresetsProfile.defaults.vscodium,
        windsurf: document.presets?.windsurf ?? PresetsProfile.defaults.windsurf
      ),
      btop: BtopProfileOptions(vimKeys: document.btop?.vimKeys),
      yazi: YaziProfileOptions(showHidden: document.yazi?.showHidden)
    )
    environment.disableShellHostedRoles()
    return environment
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
        throw PortableProfileError.invalid(
          source,
          "kitty.font_family must be a single-line value of at most 128 bytes"
        )
      }
    }
    if let size = options?.fontSize, !(4...96).contains(size) {
      throw PortableProfileError.invalid(source, "kitty.font_size must be between 4 and 96")
    }
    if let opacity = options?.backgroundOpacity, !(0...1).contains(opacity) {
      throw PortableProfileError.invalid(
        source,
        "kitty.background_opacity must be between 0 and 1"
      )
    }
    if let blur = options?.backgroundBlur, !(0...64).contains(blur) {
      throw PortableProfileError.invalid(
        source,
        "kitty.background_blur must be between 0 and 64"
      )
    }
    return KittyProfileOptions(
      fontFamily: options?.fontFamily,
      fontSize: options?.fontSize,
      backgroundOpacity: options?.backgroundOpacity,
      backgroundBlur: options?.backgroundBlur,
      overrideDirectoryURL: try Self.resolvePortablePath(
        options?.override, field: "kitty.override", base: base, source: source),
      configurationURL: try Self.resolveNativeSourcePath(
        options?.configuration, field: "kitty.configuration", base: base, source: source)
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
        throw PortableProfileError.invalid(
          source,
          "zsh.editor must be an ASCII command name of at most 128 bytes"
        )
      }
    }
    return ZshProfileOptions(
      editor: options?.editor,
      hookURL: try Self.resolvePortablePath(
        options?.hook, field: "zsh.hook", base: base, source: source),
      configurationURL: try Self.resolveNativeSourcePath(
        options?.configuration, field: "zsh.configuration", base: base, source: source)
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
      throw PortableProfileError.invalid(
        source,
        "atuin.search_mode must be fuzzy, prefix, fulltext, or daemon-fuzzy"
      )
    }
    if let mode = options?.keymapMode,
      !["emacs", "vim-insert", "vim-normal"].contains(mode)
    {
      throw PortableProfileError.invalid(
        source,
        "atuin.keymap_mode must be emacs, vim-insert, or vim-normal"
      )
    }
    return AtuinProfileOptions(
      searchMode: options?.searchMode,
      keymapMode: options?.keymapMode,
      enterAccept: options?.enterAccept,
      daemon: options?.daemon,
      configurationURL: try Self.resolvePortablePath(
        options?.configuration, field: "atuin.configuration", base: base, source: source),
      nativeConfigurationURL: try Self.resolveNativeSourcePath(
        options?.nativeConfiguration,
        field: "atuin.native_configuration", base: base, source: source)
    )
  }

  /// An undeclared role keeps its default provider.
  private func provider<Provider: PortableProfileProvider>(
    _ document: ProviderDocument?,
    source: URL
  ) throws -> Provider {
    guard let value = document?.provider else { return .defaults }
    guard let selection = Provider(rawValue: value) else {
      let field = Provider.table + "." + Provider.key(\.self)
      throw PortableProfileError.invalid(source, "\(field) has unsupported provider '\(value)'")
    }
    return selection
  }

  /// Native sources are explicit user-owned connections, not bounded copied inputs.
  /// Provider validation still excludes generated state and public adoption entries.
  private static func resolveNativeSourcePath(
    _ path: String?, field: String, base: URL, source: URL
  ) throws -> URL? {
    guard let path else { return nil }
    guard !path.isEmpty, path == path.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.hasPrefix("~"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw PortableProfileError.invalid(
        source,
        "\(field) must be an explicit absolute or profile-relative path without tilde expansion or control characters"
      )
    }
    // File standardization can follow symlinks when dot segments remain.
    return
      (NSString(string: path).isAbsolutePath ? URL(filePath: path) : base.appending(path: path))
      .standardized.standardizedFileURL
  }

  private func scripts(_ document: ScriptsDocument?, source: URL, base: URL) throws
    -> UserScriptsProfile
  {
    let paths = document?.run ?? []
    guard paths.count <= 8 else {
      throw PortableProfileError.invalid(source, "scripts.run accepts at most 8 entries")
    }
    let urls = try paths.map {
      try Self.resolvePortablePath($0, field: "scripts.run", base: base, source: source)!
    }
    guard Set(urls.map { Self.resolvingPortablePath($0).path }).count == urls.count else {
      throw PortableProfileError.invalid(source, "scripts.run must not contain duplicate paths")
    }
    return UserScriptsProfile(run: urls)
  }

  /// Foundation leaves a missing leaf unresolved, including its existing symlink parents.
  /// Resolve each component so containment still holds for a not-yet-created input.
  private static func resolvingPortablePath(_ url: URL) -> URL {
    url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(filePath: "/")) {
      $0.appending(path: $1).resolvingSymlinksInPath().standardizedFileURL
    }
  }

  private static func resolvePortablePath(
    _ path: String?, field: String, base: URL, source: URL
  ) throws -> URL? {
    guard let path else { return nil }
    guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      throw PortableProfileError.invalid(source, "\(field) must be a nonempty relative path")
    }
    guard !NSString(string: path).isAbsolutePath else {
      throw PortableProfileError.invalid(source, "\(field) must be a relative path")
    }
    let lexicalBase = base.standardizedFileURL
    let lexicalTarget = lexicalBase.appending(path: path).standardizedFileURL
    let lexicalPrefix = lexicalBase.path.hasSuffix("/") ? lexicalBase.path : lexicalBase.path + "/"
    guard lexicalTarget.path.hasPrefix(lexicalPrefix) else {
      throw PortableProfileError.invalid(source, "\(field) must stay beside the profile")
    }
    let resolvedBase = resolvingPortablePath(lexicalBase)
    let resolvedTarget = resolvingPortablePath(lexicalTarget)
    let resolvedPrefix =
      resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
    guard resolvedTarget.path.hasPrefix(resolvedPrefix) else {
      throw PortableProfileError.invalid(
        source,
        "\(field) must not escape the profile directory through a symbolic link"
      )
    }
    return lexicalTarget
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
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    if let text = proposedSources[resolved] {
      guard text.utf8.count <= 65_536 else {
        throw PortableProfileError.invalid(source, "profile exceeds 64 KiB")
      }
      return LoadedSource(text: text, resolvedSource: resolved)
    }
    var metadata = stat()
    guard lstat(source.path, &metadata) == 0 else {
      if errno == ENOENT, !required { return nil }
      throw PortableProfileError.cannotRead(source, errnoDescription(errno))
    }

    let data: Data
    do {
      data = try BoundedRegularFile.read(at: resolved, maximumSize: 65_536).data
    } catch {
      throw PortableProfileError.cannotRead(source, String(describing: error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw PortableProfileError.invalid(source, "profile is not valid UTF-8")
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
      throw PortableProfileError.invalid(source, String(describing: error))
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
      index: index,
      layerKind: kind
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

  /// Each field takes its value from the last layer that declares it, else its default.
  /// A layer's undeclared values are never used: its shell may have disabled its prompt and
  /// history, which the merged shell must decide instead.
  private func merge(
    portable: LoadedLayer,
    machine: LoadedLayer
  ) throws -> PortableProfile {
    var merged = PortableProfile.defaults
    for layer in [portable, machine] {
      let declaredFields = Set(layer.summary.declaredFields)
      for table in PortableProfile.tables {
        table.replaceDeclared(declaredFields, in: &merged, from: layer.profile)
      }
    }
    merged.sourceURL =
      machine.summary.present
      ? machine.summary.sourceURL
      : portable.profile.sourceURL
    merged.keybindings.sourceURL =
      machine.summary.declaredFields.contains { $0.hasPrefix("keybindings.") }
      ? machine.summary.sourceURL
      : portable.profile.keybindings.sourceURL
    merged.packages.layers = portable.profile.packages.layers + machine.profile.packages.layers

    try validateEnvironment(
      terminal: merged.environment.terminal,
      shell: merged.environment.shell,
      prompt: merged.environment.prompt,
      history: merged.environment.history,
      editor: merged.environment.editor,
      tools: merged.environment.tools,
      declaredTables: portable.declaredTables.union(machine.declaredTables),
      source: merged.sourceURL ?? portable.summary.sourceURL
    )
    merged.environment.disableShellHostedRoles()
    return merged
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
      throw PortableProfileError.invalid(
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
      throw PortableProfileError.invalid(
        source,
        "zsh, prompt, and history customization requires shell.provider = \"zsh\""
      )
    }
    if prompt == .disabled, declaredTables.contains("starship") {
      throw PortableProfileError.invalid(
        source,
        "[starship] cannot customize a disabled prompt provider"
      )
    }
    if history == .disabled, declaredTables.contains("atuin") {
      throw PortableProfileError.invalid(
        source,
        "[atuin] cannot customize a disabled history provider"
      )
    }
    if editor == .disabled, declaredTables.contains("neovim") {
      throw PortableProfileError.invalid(
        source,
        "[neovim] cannot customize a disabled editor provider"
      )
    }
    if !tools.btop, declaredTables.contains("btop") {
      throw PortableProfileError.invalid(source, "[btop] cannot customize a disabled daily tool")
    }
    if !tools.yazi, declaredTables.contains("yazi") {
      throw PortableProfileError.invalid(source, "[yazi] cannot customize a disabled daily tool")
    }
  }
}

private struct PortableProfileDocument: Decodable {
  let schemaVersion: Int
  let keybindings: KeybindingsDocument?
  let desktop: ProviderDocument?
  let yabai: YabaiDocument?
  let topBar: ProviderDocument?
  let focusRing: ProviderDocument?
  let scripts: ScriptsDocument?
  let macOSLook: MacOSLookDocument?
  let sketchyBar: SketchyBarDocument?
  let terminal: ProviderDocument?
  let kitty: KittyDocument?
  let shell: ProviderDocument?
  let zsh: ZshDocument?
  let prompt: ProviderDocument?
  let starship: StarshipDocument?
  let history: ProviderDocument?
  let atuin: AtuinDocument?
  let editor: ProviderDocument?
  let neovim: NeovimDocument?
  let tools: DailyToolsDocument?
  let presets: PresetsDocument?
  let btop: BtopDocument?
  let yazi: YaziDocument?
  let packages: PackagesDocument?
  let macOSPreferences: MacOSPreferencesProfile?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case keybindings
    case desktop
    case yabai
    case topBar = "top_bar"
    case focusRing = "focus_ring"
    case scripts
    case macOSLook = "macos_look"
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
    case packages
    case macOSPreferences = "macos_preferences"
  }
}

private struct MacOSLookDocument: Decodable {
  let accent: Bool?
}

private struct ScriptsDocument: Decodable {
  let run: [String]?
}

private struct PackagesDocument: Decodable {
  let baseline: PackageBaseline?
  let brewfile: String?
  let excludeFormulae: [String]?
  let excludeCasks: [String]?

  enum CodingKeys: String, CodingKey {
    case baseline, brewfile
    case excludeFormulae = "exclude_formulae"
    case excludeCasks = "exclude_casks"
  }
}

private struct KeybindingsDocument: Decodable {
  let override: String?
  let metadata: String?
  let disabled: [String]?
}

/// A role table whose only key is `provider`.
private struct ProviderDocument: Decodable {
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
  let configuration: String?

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
    case configuration
  }
}

private struct SketchyBarDocument: Decodable {
  let left: [SketchyBarModule]?
  let center: [SketchyBarModule]?
  let right: [SketchyBarModule]?
  let automaticClock: Bool?
  let hook: String?
  let configuration: String?

  enum CodingKeys: String, CodingKey {
    case left, center, right, hook, configuration
    case automaticClock = "automatic_clock"
  }
}

private struct KittyDocument: Decodable {
  let fontFamily: String?
  let fontSize: Double?
  let backgroundOpacity: Double?
  let backgroundBlur: Int?
  let override: String?
  let configuration: String?

  enum CodingKeys: String, CodingKey {
    case fontFamily = "font_family"
    case fontSize = "font_size"
    case backgroundOpacity = "background_opacity"
    case backgroundBlur = "background_blur"
    case override
    case configuration
  }
}

private struct ZshDocument: Decodable {
  let editor: String?
  let hook: String?
  let configuration: String?
}

private struct StarshipDocument: Decodable {
  let behavior: String?
  let nativeConfiguration: String?

  enum CodingKeys: String, CodingKey {
    case behavior
    case nativeConfiguration = "native_configuration"
  }
}

private struct AtuinDocument: Decodable {
  let searchMode: String?
  let keymapMode: String?
  let enterAccept: Bool?
  let daemon: Bool?
  let configuration: String?
  let nativeConfiguration: String?

  enum CodingKeys: String, CodingKey {
    case searchMode = "search_mode"
    case keymapMode = "keymap_mode"
    case enterAccept = "enter_accept"
    case daemon
    case configuration
    case nativeConfiguration = "native_configuration"
  }
}

private struct NeovimDocument: Decodable {
  let configuration: String?
  let nativeConfiguration: String?

  enum CodingKeys: String, CodingKey {
    case configuration
    case nativeConfiguration = "native_configuration"
  }
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
  let ghostty: Bool?
  let zed: Bool?
  let alacritty: Bool?
  let vscode: Bool?
  let cursor: Bool?
  let vscodium: Bool?
  let windsurf: Bool?
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
