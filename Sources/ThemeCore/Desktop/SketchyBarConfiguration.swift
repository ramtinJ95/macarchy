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
  package let spaceModule: SketchyBarSpaceModule
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

  package func compose(
    defaultsURL: URL,
    profile: PortableProfile,
    stateRoot: URL
  ) throws -> SketchyBarComposition {
    let defaults = try loadDefaults(at: defaultsURL)
    let settings = defaults.settings
    let layout = SketchyBarLayout(
      left: profile.sketchyBar.left ?? defaults.layout.left,
      center: profile.sketchyBar.center ?? defaults.layout.center,
      right: profile.sketchyBar.right ?? defaults.layout.right
    )
    try validate(layout, source: profile.sourceURL ?? defaultsURL)
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
    let artifacts = [
      SketchyBarConfigurationArtifact(
        path: "sketchybarrc",
        contents: renderEntry(
          settings: settings,
          layout: layout,
          spaceModule: spaceModule,
          palettePath: palettePath,
          pluginPath: pluginPath
        )
      ),
      SketchyBarConfigurationArtifact(
        path: "plugins/clock.sh",
        contents: renderClock(settings: settings)
      ),
      SketchyBarConfigurationArtifact(
        path: "plugins/space-indexes.sh",
        contents: renderSpaceIndexes()
      ),
    ]
    let renderedDigest = sketchyBarArtifactDigest(
      Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0.digest) })
    )
    let identity = SketchyBarInputIdentity(
      schemaVersion: 1,
      topBarProvider: profile.topBar.rawValue,
      desktopProvider: profile.desktop.provider.rawValue,
      settings: settings,
      layout: layout,
      spaceModule: spaceModule,
      palettePath: palettePath,
      pluginPath: pluginPath
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SketchyBarComposition(
      settings: settings,
      layout: layout,
      spaceModule: spaceModule,
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
    pluginPath: String
  ) -> String {
    let font = Self.shellLiteral("\(settings.font):Semibold:\(settings.fontSize).0")
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
      "\"$SKETCHYBAR\" --bar position=\(settings.position) height=\(settings.height) margin=\(settings.margin) corner_radius=\(settings.cornerRadius) color=\"$MACARCHY_BAR_COLOR\"",
      "\"$SKETCHYBAR\" --default padding_left=\(settings.itemPadding) padding_right=\(settings.itemPadding) icon.font=\(font) label.font=\(font) icon.color=\"$MACARCHY_TEXT_COLOR\" label.color=\"$MACARCHY_TEXT_COLOR\"",
      "",
    ]
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
            "\"$SKETCHYBAR\" --add item macarchy.clock \(position.rawValue) \\",
            "  --set macarchy.clock icon.drawing=off update_freq=30 script=\"$PLUGIN_DIR/clock.sh\"",
          ]
        }
        lines.append("")
      }
    }
    lines += [
      Self.managedReadyMarkerDeclaration,
      "\"$SKETCHYBAR\" --update",
    ]
    return lines.joined(separator: "\n") + "\n"
  }

  private func renderClock(settings: SketchyBarSettings) -> String {
    [
      "#!/bin/sh",
      "set -eu",
      ": \"${NAME:?SketchyBar did not provide an item name}\"",
      "LABEL=$(/bin/date \(Self.shellLiteral(settings.clockFormat)))",
      "/opt/homebrew/bin/sketchybar --set \"$NAME\" label=\"$LABEL\"",
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

  private static func shellLiteral(_ value: String) -> String {
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
  let spaceModule: SketchyBarSpaceModule
  let palettePath: String
  let pluginPath: String

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case topBarProvider = "top_bar_provider"
    case desktopProvider = "desktop_provider"
    case settings
    case layout
    case spaceModule = "space_module"
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
