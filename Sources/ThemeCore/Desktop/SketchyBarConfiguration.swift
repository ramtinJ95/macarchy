import Darwin
import Foundation
import TOMLDecoder

package struct SketchyBarSettings: Equatable, Codable, Sendable {
  package let position: String
  package let height: Int
  package let margin: Int
  package let cornerRadius: Int
  package let itemPadding: Int
  package let font: String
  package let fontSize: Int
  package let clockFormat: String

  enum CodingKeys: String, CodingKey {
    case position, height, margin, font
    case cornerRadius = "corner_radius"
    case itemPadding = "item_padding"
    case fontSize = "font_size"
    case clockFormat = "clock_format"
  }
}

package enum SketchyBarSpaceModule: String, Codable, Sendable {
  case dynamicYabai = "dynamic_yabai"
  case disabledWithoutDesktop = "disabled_without_supported_desktop"
  case hidden
}

package enum SketchyBarPosition: String, CaseIterable, Codable, Sendable {
  case left
  case center
  case right
}

package struct SketchyBarLayout: Equatable, Codable, Sendable {
  package let left: [SketchyBarModule]
  package let center: [SketchyBarModule]
  package let right: [SketchyBarModule]

  package func modules(at position: SketchyBarPosition) -> [SketchyBarModule] {
    switch position {
    case .left: left
    case .center: center
    case .right: right
    }
  }

  package func position(of module: SketchyBarModule) -> SketchyBarPosition? {
    SketchyBarPosition.allCases.first { modules(at: $0).contains(module) }
  }
  package func hasTrailingGroupPadding(_ module: SketchyBarModule) -> Bool {
    guard let position = position(of: module) else { return false }
    if module == .battery { return true }
    guard module == .cpu || module == .memory else { return false }
    let group = modules(at: position)
    guard let index = group.firstIndex(of: module) else { return false }
    return index + 1 == group.count || ![SketchyBarModule.cpu, .memory].contains(group[index + 1])
  }
}

package struct SketchyBarConfigurationArtifact: Equatable, Sendable {
  package let path: String
  package let contents: String
  package let digest: String

  package init(path: String, contents: String) {
    self.path = path
    self.contents = contents
    digest = sha256Digest(Data(contents.utf8))
  }
}

package struct SketchyBarComposition: Equatable, Sendable {
  package let settings: SketchyBarSettings
  package let layout: SketchyBarLayout
  package let automaticClock: Bool
  package let spaceModule: SketchyBarSpaceModule
  package let hookURL: URL?
  package let hookDigest: String?
  package let artifacts: [SketchyBarConfigurationArtifact]
  package let renderedDigest: String
  package let inputDigest: String
}

package enum SketchyBarConfigurationError: Error, CustomStringConvertible, Sendable {
  case invalid(URL, String)
  case cannotRead(URL, String)

  package var description: String {
    switch self {
    case .invalid(let source, let reason):
      "\(source.path): invalid SketchyBar configuration: \(reason)"
    case .cannotRead(let source, let reason):
      "\(source.path): cannot read SketchyBar configuration: \(reason)"
    }
  }

  package var sourceURL: URL {
    switch self {
    case .invalid(let source, _), .cannotRead(let source, _): source
    }
  }
}

package struct SketchyBarConfigurationComposer: Sendable {
  package static let providerID = "sketchybar"
  package static let paletteArtifactPath = "generated/sketchybar.sh"
  package static let readyItem = "macarchy.theme.ready"
  static let paletteSource = ". \"$PALETTE\""
  static let managedReadyMarkerDeclaration =
    "\"$SKETCHYBAR\" --add item \(readyItem) right --set \(readyItem) drawing=off"

  package init() {}

  package func effectiveLayout(defaultsURL: URL, profile: PortableProfile) throws
    -> SketchyBarLayout
  {
    try resolveLayout(
      profile: profile, defaults: loadDefaults(at: defaultsURL).layout, source: defaultsURL)
  }

  private func resolveLayout(profile: PortableProfile, defaults: SketchyBarLayout, source: URL)
    throws -> SketchyBarLayout
  {
    let layout = SketchyBarLayout(
      left: profile.sketchyBar.left ?? defaults.left,
      center: profile.sketchyBar.center ?? defaults.center,
      right: profile.sketchyBar.right ?? defaults.right)
    try validate(layout, source: profile.sourceURL ?? source)
    return layout
  }

  package func compose(
    defaultsURL: URL,
    profile: PortableProfile,
    stateRoot: URL,
    macarchyExecutableURL: URL = URL(filePath: "/opt/homebrew/bin/macarchy")
  ) throws -> SketchyBarComposition {
    let defaults = try loadDefaults(at: defaultsURL)
    let settings = defaults.settings
    let layout = try resolveLayout(profile: profile, defaults: defaults.layout, source: defaultsURL)
    guard layout.position(of: .toggle) == nil || settings.position == "top" else {
      throw SketchyBarConfigurationError.invalid(
        defaultsURL, "native-menu toggle requires a top-positioned bar")
    }
    let automaticClock = ![
      profile.sketchyBar.left, profile.sketchyBar.center, profile.sketchyBar.right,
    ]
    .compactMap { $0 }.joined().contains(.clock)
    let spaceModule: SketchyBarSpaceModule =
      if layout.position(of: .spaces) == nil {
        .hidden
      } else if profile.desktop.provider == .yabaiSkhd {
        .dynamicYabai
      } else {
        .disabledWithoutDesktop
      }
    let palettePath = Self.palettePath(stateRoot: stateRoot)
    let pluginPath =
      stateRoot
      .appending(path: "desktop/sketchybar/current/plugins", directoryHint: .isDirectory)
      .standardizedFileURL.path
    let hook: (text: String, digest: String)?
    if let hookURL = profile.sketchyBar.hookURL {
      guard let hookRootURL = profile.sketchyBar.hookRootURL else {
        throw SketchyBarConfigurationError.invalid(hookURL, "trusted hook root is unavailable")
      }
      hook = try readHook(at: hookURL, root: hookRootURL)
    } else {
      hook = nil
    }
    let macarchyExecutablePath = macarchyExecutableURL.standardizedFileURL.path
    var artifacts = [
      SketchyBarConfigurationArtifact(
        path: "sketchybarrc",
        contents: renderEntry(
          settings: settings,
          layout: layout,
          spaceModule: spaceModule,
          palettePath: palettePath,
          pluginPath: pluginPath,
          hasHook: hook != nil,
          macarchyExecutablePath: macarchyExecutablePath,
          stateRootPath: stateRoot.standardizedFileURL.path
        )
      ),
      SketchyBarConfigurationArtifact(
        path: "plugins/clock.sh",
        contents: renderClock(
          settings: settings,
          position: automaticClock ? "auto" : (layout.position(of: .clock)?.rawValue ?? "right"),
          palettePath: palettePath, macarchyExecutablePath: macarchyExecutablePath)
      ),
      SketchyBarConfigurationArtifact(
        path: "plugins/space-indexes.sh",
        contents: renderSpaceIndexes()
      ),
    ]
    if layout.position(of: .volume) != nil {
      artifacts.append(
        SketchyBarConfigurationArtifact(
          path: "plugins/volume.sh",
          contents: SketchyBarVolumeScript.render(
            palettePath: palettePath, macarchyExecutablePath: macarchyExecutablePath)
        )
      )
    }
    if layout.position(of: .battery) != nil {
      artifacts.append(
        SketchyBarConfigurationArtifact(
          path: "plugins/battery.sh",
          contents: SketchyBarBatteryScript.render(palettePath: palettePath)
        )
      )
    }
    for module in [SketchyBarModule.cpu, .memory] where layout.position(of: module) != nil {
      artifacts.append(
        SketchyBarConfigurationArtifact(
          path: "plugins/\(module.rawValue).sh",
          contents: SketchyBarMetricScript.render(
            module: module, palettePath: palettePath,
            macarchyExecutablePath: macarchyExecutablePath)))
    }
    if layout.position(of: .wifi) != nil {
      artifacts.append(
        SketchyBarConfigurationArtifact(
          path: "plugins/wifi.sh",
          contents: SketchyBarWiFiScript.render(
            palettePath: palettePath,
            macarchyExecutablePath: macarchyExecutablePath)))
    }
    if layout.position(of: .apple) != nil {
      artifacts.append(
        .init(
          path: "plugins/apple.sh",
          contents: SketchyBarAppleScript.render(
            palettePath: palettePath,
            helperPath: macarchyExecutableURL.deletingLastPathComponent().appending(
              path: "macarchy-menu"
            ).standardizedFileURL.path)))
    }
    if layout.position(of: .media) != nil {
      artifacts.append(
        .init(
          path: "plugins/media.sh",
          contents: SketchyBarMediaScript.render(
            palettePath: palettePath, macarchyExecutablePath: macarchyExecutablePath)))
    }
    if let hook {
      artifacts.append(
        SketchyBarConfigurationArtifact(
          path: "plugins/user-hook.sh",
          contents: hook.text
        )
      )
    }
    let renderedDigest = sketchyBarArtifactDigest(
      Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0.digest) })
    )
    let identity = SketchyBarInputIdentity(
      schemaVersion: 1,
      topBarProvider: profile.topBar.rawValue,
      desktopProvider: profile.desktop.provider.rawValue,
      settings: settings,
      layout: layout,
      automaticClock: automaticClock,
      spaceModule: spaceModule,
      hookDigest: hook?.digest,
      macarchyExecutablePath: macarchyExecutablePath,
      palettePath: palettePath,
      pluginPath: pluginPath
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SketchyBarComposition(
      settings: settings,
      layout: layout,
      automaticClock: automaticClock,
      spaceModule: spaceModule,
      hookURL: profile.sketchyBar.hookURL,
      hookDigest: hook?.digest,
      artifacts: artifacts,
      renderedDigest: renderedDigest,
      inputDigest: sha256Digest(try encoder.encode(identity))
    )
  }

  private func loadDefaults(at source: URL) throws -> SketchyBarDefaults {
    let text: String
    do {
      text = try BoundedRegularFile.readUTF8(at: source, maximumSize: 65_536)
    } catch {
      throw SketchyBarConfigurationError.cannotRead(source, String(describing: error))
    }
    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(
        text: text,
        file: source,
        syntaxRole: "SketchyBar defaults"
      )
    } catch {
      throw SketchyBarConfigurationError.invalid(source, String(describing: error))
    }
    if let table = index.tables.first {
      throw SketchyBarConfigurationError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    let allowedFields = Set([
      "schema_version", "position", "height", "margin", "corner_radius",
      "item_padding", "font", "font_size", "clock_format", "left", "center", "right",
    ])
    if let field = index.fields.first(where: { !allowedFields.contains($0.path) }) {
      throw SketchyBarConfigurationError.invalid(
        source,
        "line \(field.line), column \(field.column): unknown key '\(field.path)'"
      )
    }

    let document: SketchyBarDefaultsDocument
    do {
      document = try TOMLDecoder().decode(SketchyBarDefaultsDocument.self, from: text)
    } catch {
      throw SketchyBarConfigurationError.invalid(source, String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw SketchyBarConfigurationError.invalid(
        source,
        "unsupported schema_version \(document.schemaVersion); expected 1"
      )
    }
    try validate(document.settings, source: source)
    try validate(document.layout, source: source)
    return SketchyBarDefaults(settings: document.settings, layout: document.layout)
  }

  private func validate(_ settings: SketchyBarSettings, source: URL) throws {
    guard ["top", "bottom"].contains(settings.position) else {
      throw SketchyBarConfigurationError.invalid(source, "position must be top or bottom")
    }
    for (field, value, range) in [
      ("height", settings.height, 20...96),
      ("margin", settings.margin, 0...64),
      ("corner_radius", settings.cornerRadius, 0...48),
      ("item_padding", settings.itemPadding, 0...32),
      ("font_size", settings.fontSize, 8...32),
    ] {
      guard range.contains(value) else {
        throw SketchyBarConfigurationError.invalid(
          source,
          "\(field) must be between \(range.lowerBound) and \(range.upperBound)"
        )
      }
    }
    for (field, value) in [("font", settings.font), ("clock_format", settings.clockFormat)] {
      guard !value.isEmpty, value.utf8.count <= 128, !value.contains("\n"), !value.contains("\0")
      else {
        throw SketchyBarConfigurationError.invalid(
          source,
          "\(field) must be a nonempty single-line value of at most 128 bytes"
        )
      }
    }
    guard settings.clockFormat.hasPrefix("+") else {
      throw SketchyBarConfigurationError.invalid(
        source,
        "clock_format must begin with + for /bin/date"
      )
    }
  }

  private func validate(_ layout: SketchyBarLayout, source: URL) throws {
    let modules = SketchyBarPosition.allCases.flatMap(layout.modules)
    guard Set(modules).count == modules.count else {
      throw SketchyBarConfigurationError.invalid(
        source,
        "each SketchyBar module may appear in only one position"
      )
    }
  }

  private func renderEntry(
    settings: SketchyBarSettings,
    layout: SketchyBarLayout,
    spaceModule: SketchyBarSpaceModule,
    palettePath: String,
    pluginPath: String,
    hasHook: Bool,
    macarchyExecutablePath: String,
    stateRootPath: String
  ) -> String {
    let font = Self.shellLiteral("\(settings.font):Semibold:\(settings.fontSize).0")
    let iconFont = Self.shellLiteral("\(settings.font):Bold:\(settings.fontSize).0")
    let labelFont = Self.shellLiteral(
      "\(settings.font):Semibold:\(max(8, settings.fontSize - 1)).0")
    var lines = [
      "#!/bin/sh",
      "set -eu",
      "",
      "SKETCHYBAR=/opt/homebrew/bin/sketchybar",
      "YABAI=/opt/homebrew/bin/yabai",
      "PLUGIN_DIR=\(Self.shellLiteral(pluginPath))",
      Self.paletteAssignment(path: palettePath),
      Self.paletteSource,
      "",
      "\"$SKETCHYBAR\" --bar position=\(settings.position) height=\(settings.height) margin=\(settings.margin) corner_radius=\(settings.cornerRadius) color=\"$MACARCHY_BAR_COLOR\" topmost=window padding_left=8 padding_right=8 hidden=off y_offset=0",
      "\"$SKETCHYBAR\" --default padding_left=\(settings.itemPadding) padding_right=\(settings.itemPadding) icon.font=\(iconFont) label.font=\(labelFont) icon.color=\"$MACARCHY_TEXT_COLOR\" label.color=\"$MACARCHY_TEXT_COLOR\" icon.padding_left=2 icon.padding_right=2 label.padding_left=2 label.padding_right=2 background.height=\(settings.height) background.corner_radius=0 background.border_width=0 background.color=0x00000000 popup.background.border_width=2 popup.background.corner_radius=9 popup.background.border_color=\"$MACARCHY_ACCENT_COLOR\" popup.background.color=\"$MACARCHY_BAR_COLOR\" popup.background.shadow.drawing=on popup.blur_radius=50 updates=when_shown scroll_texts=on",
      "",
    ]
    var helperCommands: [String] = []
    for position in SketchyBarPosition.allCases {
      for module in layout.modules(at: position) {
        switch module {
        case .spaces:
          switch spaceModule {
          case .dynamicYabai:
            lines += [
              "SPACE_INDICES=$(\"$PLUGIN_DIR/space-indexes.sh\")",
              "for sid in $SPACE_INDICES; do",
              "  item=\"macarchy.space.$sid\"",
              "  \"$SKETCHYBAR\" --add space \"$item\" \(position.rawValue) \\",
              "    --set \"$item\" space=\"$sid\" icon=\"$sid\" label.drawing=off \\",
              "      icon.font=\(font) icon.width=24 \\",
              "      icon.highlight_color=\"$MACARCHY_ACCENT_COLOR\" \\",
              "      click_script=\"$YABAI -m space --focus $sid\"",
              "done",
            ]
          case .disabledWithoutDesktop:
            lines += [
              "\"$SKETCHYBAR\" --add item macarchy.spaces.unavailable \(position.rawValue) \\",
              "  --set macarchy.spaces.unavailable icon=\"!\" label=\"Spaces unavailable\" \\",
              "    icon.color=\"$MACARCHY_MUTED_COLOR\" label.color=\"$MACARCHY_MUTED_COLOR\"",
            ]
          case .hidden:
            break
          }
        case .clock:
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.clock.preview right --set macarchy.clock.preview drawing=off label=0",
            "\"$SKETCHYBAR\" --add item macarchy.clock \(position.rawValue) \\",
            "  --set macarchy.clock icon.drawing=off label.font='SF Mono:Semibold:13.0' label.align=center update_freq=30 script=\"$PLUGIN_DIR/clock.sh\"",
            "\"$SKETCHYBAR\" --subscribe macarchy.clock mouse.clicked display_change system_woke",
          ]
        case .toggle:
          lines += [
            "TOGGLE_TOKEN=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')",
            "\"$SKETCHYBAR\" --add item macarchy.toggle \(position.rawValue) --set macarchy.toggle drawing=on icon='Toggle starting' label.drawing=off label=\"$TOGGLE_TOKEN|starting\"",
          ]
          helperCommands.append(
            "\(Self.shellLiteral(macarchyExecutablePath)) desktop _bar-toggle --state-root \(Self.shellLiteral(stateRootPath)) --token \"$TOGGLE_TOKEN\" </dev/null >/dev/null 2>&1 &"
          )
        case .apple:
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.apple \(position.rawValue) --set macarchy.apple icon='􀣺' icon.font='SF Pro:Bold:14.0' icon.padding_left=2 icon.padding_right=6 label.drawing=off padding_left=0 padding_right=4 script=\"$PLUGIN_DIR/apple.sh\"",
            "\"$SKETCHYBAR\" --subscribe macarchy.apple mouse.clicked",
          ]
        case .media:
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.media.preview right --set macarchy.media.preview drawing=off label=0",
            "\"$SKETCHYBAR\" --add item macarchy.media \(position.rawValue) --set macarchy.media drawing=off updates=on update_freq=2 label.drawing=off label=inactive icon.drawing=off background.image.scale=0.85 popup.align=center popup.horizontal=on script=\"$PLUGIN_DIR/media.sh\"",
            "\"$SKETCHYBAR\" --subscribe macarchy.media mouse.entered mouse.exited mouse.clicked mouse.exited.global system_woke",
          ]
          for (part, size, offset, limit) in [("artist", 9, 6, 18), ("title", 11, -5, 16)] {
            lines += [
              "\"$SKETCHYBAR\" --add item macarchy.media.\(part) \(position.rawValue) --set macarchy.media.\(part) drawing=off \(part == "artist" ? "width=0 " : "")padding_left=3 padding_right=0 icon.drawing=off label.width=0 label.font='SF Pro:Semibold:\(size).0' label.max_chars=\(limit) label.y_offset=\(offset) label.color=\"$\(part == "artist" ? "MACARCHY_MUTED_COLOR" : "MACARCHY_TEXT_COLOR")\" script=\"$PLUGIN_DIR/media.sh\"",
              "\"$SKETCHYBAR\" --subscribe macarchy.media.\(part) mouse.entered mouse.exited mouse.exited.global",
            ]
          }
          for (part, icon) in [("previous", "􀊊"), ("playpause", "􀊈"), ("next", "􀊌")] {
            lines += [
              "\"$SKETCHYBAR\" --add item macarchy.media.\(part) popup.macarchy.media --set macarchy.media.\(part) label.drawing=off icon='\(icon)' click_script=\(Self.shellLiteral(Self.pluginClickScript(sender: "macarchy.media.\(part)", pluginPath: "\(pluginPath)/media.sh")))"
            ]
          }
        case .wifi:
          for (suffix, icon, offset) in [("up", "􀄨", 4), ("down", "􀄩", -4)] {
            lines += [
              "\"$SKETCHYBAR\" --add item macarchy.wifi.\(suffix) \(position.rawValue) --set macarchy.wifi.\(suffix) padding_left=-5 \(suffix == "up" ? "width=0 " : "")y_offset=\(offset) icon='\(icon)' icon.font='SF Pro:Bold:9.0' icon.padding_right=0 label.font='SF Mono:Bold:9.0' label='--' script=\"$PLUGIN_DIR/wifi.sh\"",
              "\"$SKETCHYBAR\" --subscribe macarchy.wifi.\(suffix) mouse.clicked",
            ]
          }
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.wifi \(position.rawValue) --set macarchy.wifi label.drawing=off icon='􀙈' icon.padding_right=8 update_freq=2 script=\"$PLUGIN_DIR/wifi.sh\"",
            "\"$SKETCHYBAR\" --add bracket macarchy.wifi.bracket macarchy.wifi macarchy.wifi.up macarchy.wifi.down --set macarchy.wifi.bracket position=\(position.rawValue) label.drawing=off icon.drawing=off background.color=0x00000000 background.border_width=0 popup.align=center popup.height=30",
            "\"$SKETCHYBAR\" --subscribe macarchy.wifi mouse.clicked mouse.exited.global system_woke",
          ]
          for (field, title) in [
            ("ssid", "􁓤"), ("hostname", "Hostname:"), ("ip", "IP:"), ("mask", "Subnet mask:"),
            ("router", "Router:"),
          ] {
            lines += [
              "\"$SKETCHYBAR\" --add item macarchy.wifi.\(field) popup.macarchy.wifi.bracket --set macarchy.wifi.\(field) width=250 icon='\(title)' icon.align=left icon.width=125 label='Unavailable' label.width=125 label.align=right label.max_chars=20 script=\"$PLUGIN_DIR/wifi.sh\"",
              "\"$SKETCHYBAR\" --subscribe macarchy.wifi.\(field) mouse.clicked",
            ]
          }
        case .cpu, .memory:
          let name = "macarchy.\(module.rawValue)"
          lines += [
            "\"$SKETCHYBAR\" --add item \(name) \(position.rawValue) --set \(name) icon.drawing=off width=54 padding_left=2 padding_right=2 label.font='SF Mono:Bold:10.0' label.padding_left=0 label.padding_right=0 label.align=left label='--%' update_freq=\(module == .cpu ? 2 : 5) script=\"$PLUGIN_DIR/\(module.rawValue).sh\" click_script='/usr/bin/open -a \"Activity Monitor\"'"
          ]
        case .battery:
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.battery \(position.rawValue) --set macarchy.battery icon.font='SF Pro:Regular:15.0' label.font='SF Mono:Semibold:10.0' label='--%' update_freq=180 script=\"$PLUGIN_DIR/battery.sh\"",
            "\"$SKETCHYBAR\" --add item macarchy.battery.remaining popup.macarchy.battery --set macarchy.battery.remaining icon.drawing=off label='No estimate'",
            "\"$SKETCHYBAR\" --subscribe macarchy.battery power_source_change system_woke mouse.clicked mouse.exited.global",
          ]
        case .volume:
          lines += [
            "\"$SKETCHYBAR\" --add item macarchy.volume \(position.rawValue) \\",
            "  --set macarchy.volume icon.drawing=off label.font='SF Mono:Semibold:10.0' label.padding_left=-1 label=\"--%\" script=\"$PLUGIN_DIR/volume.sh\"",
            "\"$SKETCHYBAR\" --add item macarchy.volume.icon \(position.rawValue) --set macarchy.volume.icon padding_right=-1 icon='􀊩' icon.width=0 icon.align=left icon.color=\"$MACARCHY_MUTED_COLOR\" icon.font='SF Pro:Regular:13.0' label='􀊣' label.width=25 label.align=left label.font='SF Pro:Regular:13.0' script=\"$PLUGIN_DIR/volume.sh\"",
            "\"$SKETCHYBAR\" --add bracket macarchy.volume.bracket macarchy.volume.icon macarchy.volume --set macarchy.volume.bracket position=\(position.rawValue) icon.drawing=off label.drawing=off background.color=0x00000000 background.border_width=0 popup.align=center",
            "\"$SKETCHYBAR\" --add item macarchy.volume.padding \(position.rawValue) --set macarchy.volume.padding width=8 icon.drawing=off label.drawing=off",
            "\"$SKETCHYBAR\" --add slider macarchy.volume.slider popup.macarchy.volume.bracket 250 --set macarchy.volume.slider slider.highlight_color=\"$MACARCHY_ACCENT_COLOR\" slider.background.height=6 slider.background.corner_radius=3 slider.background.color=\"$MACARCHY_MUTED_COLOR\" slider.knob='􀀁' background.height=2 background.y_offset=-20 icon.drawing=off label.drawing=off click_script=\(Self.shellLiteral(Self.pluginClickScript(sender: "macarchy.slider", pluginPath: "\(pluginPath)/volume.sh")))",
            "\"$SKETCHYBAR\" --subscribe macarchy.volume volume_change system_woke mouse.clicked mouse.scrolled mouse.exited.global",
            "\"$SKETCHYBAR\" --subscribe macarchy.volume.icon mouse.clicked mouse.scrolled",
          ]
        }
        if layout.hasTrailingGroupPadding(module) {
          lines.append(
            "\"$SKETCHYBAR\" --add item macarchy.\(module.rawValue).padding \(position.rawValue) --set macarchy.\(module.rawValue).padding width=8 icon.drawing=off label.drawing=off"
          )
        }
        lines.append("")
      }
    }
    if hasHook {
      lines += [
        "export SKETCHYBAR YABAI PLUGIN_DIR PALETTE MACARCHY_BAR_COLOR MACARCHY_TEXT_COLOR MACARCHY_MUTED_COLOR MACARCHY_ACCENT_COLOR",
        "\(Self.shellLiteral(macarchyExecutablePath)) desktop _run-sketchybar-hook \"$PLUGIN_DIR/user-hook.sh\"",
      ]
    }
    lines += [Self.managedReadyMarkerDeclaration, "\"$SKETCHYBAR\" --update"]
    lines += helperCommands
    return lines.joined(separator: "\n") + "\n"
  }

  private func renderClock(
    settings: SketchyBarSettings, position: String, palettePath: String,
    macarchyExecutablePath: String
  ) -> String {
    [
      "#!/bin/sh",
      "set -eu",
      "[ \"${NAME-}\" = macarchy.clock ] || exit 1",
      ". \(Self.shellLiteral(palettePath))",
      "if \(Self.shellLiteral(macarchyExecutablePath)) desktop _calendar --sender \"${SENDER-forced}\" --position \(Self.shellLiteral(position)) --format \(Self.shellLiteral(settings.clockFormat)); then",
      "  /opt/homebrew/bin/sketchybar --set macarchy.clock label.color=\"$MACARCHY_TEXT_COLOR\"",
      "else",
      "  echo 'Macarchy: calendar query failed' >&2",
      "  /opt/homebrew/bin/sketchybar --set macarchy.clock label=ERR label.color=\"$MACARCHY_BATTERY_RED\" || echo 'Macarchy: calendar error presentation also failed' >&2",
      "  exit 1",
      "fi",
    ].joined(separator: "\n") + "\n"
  }

  private func renderSpaceIndexes() -> String {
    [
      "#!/bin/sh",
      "set -eu",
      "JSON=$(/opt/homebrew/bin/yabai -m query --spaces)",
      "INDICES=$(printf '%s\\n' \"$JSON\" | /usr/bin/grep -Eo '\"index\"[[:space:]]*:[[:space:]]*[0-9]+' | /usr/bin/sed -E 's/.*:[[:space:]]*//') || {",
      "  echo 'cannot parse yabai Space inventory' >&2",
      "  exit 1",
      "}",
      "if [ -z \"$INDICES\" ]; then",
      "  echo 'yabai returned no inspectable Spaces' >&2",
      "  exit 1",
      "fi",
      "printf '%s\\n' \"$INDICES\"",
    ].joined(separator: "\n") + "\n"
  }

  private func readHook(at source: URL, root: URL) throws -> (text: String, digest: String) {
    let root = root.standardizedFileURL
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard resolved.path.hasPrefix(prefix) else {
      throw SketchyBarConfigurationError.invalid(
        source,
        "trusted hook symlink must stay beside the profile"
      )
    }
    let data: Data
    do {
      data = try readPinnedHook(at: resolved, root: root)
    } catch {
      throw SketchyBarConfigurationError.cannotRead(source, String(describing: error))
    }
    guard !data.starts(with: [0xef, 0xbb, 0xbf]) else {
      throw SketchyBarConfigurationError.invalid(source, "trusted hook must not have a UTF-8 BOM")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw SketchyBarConfigurationError.invalid(source, "trusted hook is not valid UTF-8")
    }
    guard !text.contains("\0") else {
      throw SketchyBarConfigurationError.invalid(source, "trusted hook contains a NUL byte")
    }
    try validateShellSyntax(data, source: source)
    return (text, sha256Digest(data))
  }

  private func readPinnedHook(at source: URL, root: URL) throws -> Data {
    let relativePath = String(source.path.dropFirst(root.path.count + (root.path == "/" ? 0 : 1)))
    let components = relativePath.split(separator: "/").map(String.init)
    guard let name = components.last else {
      throw SketchyBarConfigurationError.invalid(source, "trusted hook path is invalid")
    }
    var descriptor = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(descriptor) }
    var directory = root
    for component in components.dropLast() {
      directory.append(path: component, directoryHint: .isDirectory)
      let next = try PinnedFilesystem.openDirectory(
        parentDescriptor: descriptor,
        name: component,
        url: directory
      )
      Darwin.close(descriptor)
      descriptor = next
    }
    return try PinnedFilesystem.readRegularFile(
      parentDescriptor: descriptor,
      name: name,
      url: source,
      maximumSize: 1_048_576
    ).data
  }

  private func validateShellSyntax(_ data: Data, source: URL) throws {
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-n"]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: data)
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
    } catch {
      try? input.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      throw SketchyBarConfigurationError.invalid(source, "cannot validate trusted hook syntax")
    }
    guard process.terminationStatus == 0 else {
      throw SketchyBarConfigurationError.invalid(source, "trusted hook has invalid /bin/sh syntax")
    }
  }

  static func managedPaletteAssignment(stateRoot: URL) -> String {
    paletteAssignment(path: palettePath(stateRoot: stateRoot))
  }

  static func palettePath(stateRoot: URL) -> String {
    stateRoot
      .appending(path: "current/\(paletteArtifactPath)")
      .standardizedFileURL.path
  }

  private static func paletteAssignment(path: String) -> String {
    "PALETTE=\(shellLiteral(path))"
  }

  package static func pluginClickScript(sender: String, pluginPath: String) -> String {
    "SENDER=\(shellLiteral(sender)) \(shellLiteral(pluginPath))"
  }

  static func shellLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}

package func sketchyBarArtifactDigest(_ artifacts: [String: String]) -> String {
  var data = Data()
  for path in artifacts.keys.sorted() {
    for value in [path, artifacts[path]!] {
      let bytes = Data(value.utf8)
      data.append(Data("\(bytes.count):".utf8))
      data.append(bytes)
    }
  }
  return sha256Digest(data)
}

private struct SketchyBarInputIdentity: Encodable {
  let schemaVersion: Int
  let topBarProvider: String
  let desktopProvider: String
  let settings: SketchyBarSettings
  let layout: SketchyBarLayout
  let automaticClock: Bool
  let spaceModule: SketchyBarSpaceModule
  let hookDigest: String?
  let macarchyExecutablePath: String
  let palettePath: String
  let pluginPath: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case topBarProvider = "top_bar_provider"
    case desktopProvider = "desktop_provider"
    case settings
    case layout
    case automaticClock = "automatic_clock"
    case spaceModule = "space_module"
    case hookDigest = "hook_digest"
    case macarchyExecutablePath = "macarchy_executable_path"
    case palettePath = "palette_path"
    case pluginPath = "plugin_path"
  }
}

private struct SketchyBarDefaultsDocument: Decodable {
  let schemaVersion: Int
  let position: String
  let height: Int
  let margin: Int
  let cornerRadius: Int
  let itemPadding: Int
  let font: String
  let fontSize: Int
  let clockFormat: String
  let left: [SketchyBarModule]
  let center: [SketchyBarModule]
  let right: [SketchyBarModule]

  var settings: SketchyBarSettings {
    SketchyBarSettings(
      position: position,
      height: height,
      margin: margin,
      cornerRadius: cornerRadius,
      itemPadding: itemPadding,
      font: font,
      fontSize: fontSize,
      clockFormat: clockFormat
    )
  }

  var layout: SketchyBarLayout {
    SketchyBarLayout(left: left, center: center, right: right)
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case position, height, margin, font
    case cornerRadius = "corner_radius"
    case itemPadding = "item_padding"
    case fontSize = "font_size"
    case clockFormat = "clock_format"
    case left, center, right
  }
}

private struct SketchyBarDefaults {
  let settings: SketchyBarSettings
  let layout: SketchyBarLayout
}
