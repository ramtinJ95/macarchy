import Foundation
import TOMLDecoder

package struct YabaiRule: Equatable, Codable, Sendable {
  package let label: String?
  package let app: String?
  package let title: String?
  package let role: String?
  package let subrole: String?
}

package struct YabaiSettings: Equatable, Codable, Sendable {
  package let layout: String
  package let windowPlacement: String
  package let windowInsertionPoint: String
  package let autoBalance: Bool
  package let splitRatio: Double
  package let topPadding: Int
  package let bottomPadding: Int
  package let leftPadding: Int
  package let rightPadding: Int
  package let windowGap: Int
  package let mouseFollowsFocus: Bool
  package let mouseModifier: String
  package let mouseAction1: String
  package let mouseAction2: String
  package let externalBarHeight: Int
  package let rules: [YabaiRule]

  enum CodingKeys: String, CodingKey {
    case layout
    case windowPlacement = "window_placement"
    case windowInsertionPoint = "window_insertion_point"
    case autoBalance = "auto_balance"
    case splitRatio = "split_ratio"
    case topPadding = "top_padding"
    case bottomPadding = "bottom_padding"
    case leftPadding = "left_padding"
    case rightPadding = "right_padding"
    case windowGap = "window_gap"
    case mouseFollowsFocus = "mouse_follows_focus"
    case mouseModifier = "mouse_modifier"
    case mouseAction1 = "mouse_action1"
    case mouseAction2 = "mouse_action2"
    case externalBarHeight = "external_bar_height"
    case rules
  }
}

package struct YabaiComposition: Equatable, Sendable {
  package let settings: YabaiSettings
  package let externalBarEnabled: Bool
  package let hookURL: URL?
  package let hookDigest: String?
  package let renderedConfiguration: String
  package let renderedDigest: String
  package let inputDigest: String
}

package enum YabaiConfigurationError: Error, CustomStringConvertible, Sendable {
  case invalid(URL, String)
  case cannotRead(URL, String)

  package var description: String {
    switch self {
    case .invalid(let source, let reason):
      "\(source.path): invalid yabai configuration: \(reason)"
    case .cannotRead(let source, let reason):
      "\(source.path): cannot read yabai configuration: \(reason)"
    }
  }

  package var sourceURL: URL {
    switch self {
    case .invalid(let source, _), .cannotRead(let source, _):
      source
    }
  }
}

package struct YabaiConfigurationComposer: Sendable {
  package init() {}

  package func compose(
    defaultsURL: URL,
    profile: PortableProfile
  ) throws -> YabaiComposition {
    let defaults = try loadDefaults(at: defaultsURL)
    let options = profile.desktop.yabai
    let settings = YabaiSettings(
      layout: options.layout ?? defaults.layout,
      windowPlacement: defaults.windowPlacement,
      windowInsertionPoint: defaults.windowInsertionPoint,
      autoBalance: defaults.autoBalance,
      splitRatio: options.splitRatio ?? defaults.splitRatio,
      topPadding: options.topPadding ?? defaults.topPadding,
      bottomPadding: options.bottomPadding ?? defaults.bottomPadding,
      leftPadding: options.leftPadding ?? defaults.leftPadding,
      rightPadding: options.rightPadding ?? defaults.rightPadding,
      windowGap: options.windowGap ?? defaults.windowGap,
      mouseFollowsFocus: options.mouseFollowsFocus ?? defaults.mouseFollowsFocus,
      mouseModifier: defaults.mouseModifier,
      mouseAction1: defaults.mouseAction1,
      mouseAction2: defaults.mouseAction2,
      externalBarHeight: defaults.externalBarHeight,
      rules: defaults.rules
    )
    let hook = try options.hookURL.map(readHook)
    let rendered = render(
      settings: settings,
      topBarEnabled: profile.topBar == .sketchybar,
      hook: hook?.text
    )
    let renderedDigest = sha256Digest(Data(rendered.utf8))
    let input = YabaiInputIdentity(
      schemaVersion: 1,
      desktopProvider: profile.desktop.provider.rawValue,
      topBarProvider: profile.topBar.rawValue,
      settings: settings,
      hookDigest: hook?.digest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return YabaiComposition(
      settings: settings,
      externalBarEnabled: profile.topBar == .sketchybar,
      hookURL: options.hookURL,
      hookDigest: hook?.digest,
      renderedConfiguration: rendered,
      renderedDigest: renderedDigest,
      inputDigest: sha256Digest(try encoder.encode(input))
    )
  }

  private func loadDefaults(at source: URL) throws -> YabaiSettings {
    let text = try readText(at: source, maximumSize: 65_536)
    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(text: text, file: source, syntaxRole: "Yabai defaults")
    } catch {
      throw YabaiConfigurationError.invalid(source, String(describing: error))
    }
    if let table = index.tables.first(where: { $0.path != "rules" || !$0.isArray }) {
      throw YabaiConfigurationError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    let rootFields = [
      "schema_version", "layout", "window_placement", "window_insertion_point",
      "auto_balance", "split_ratio", "top_padding", "bottom_padding", "left_padding",
      "right_padding", "window_gap", "mouse_follows_focus", "mouse_modifier",
      "mouse_action1", "mouse_action2", "external_bar_height",
    ]
    let ruleFields = ["rules.label", "rules.app", "rules.title", "rules.role", "rules.subrole"]
    let allowedFields = Set(rootFields + ruleFields)
    if let field = index.fields.first(where: { !allowedFields.contains($0.path) }) {
      throw YabaiConfigurationError.invalid(
        source,
        "line \(field.line), column \(field.column): unknown key '\(field.path)'"
      )
    }

    let decoder = TOMLDecoder()
    let schema: YabaiDefaultsSchema
    let settings: YabaiSettings
    do {
      schema = try decoder.decode(YabaiDefaultsSchema.self, from: text)
      settings = try decoder.decode(YabaiSettings.self, from: text)
    } catch {
      throw YabaiConfigurationError.invalid(source, String(describing: error))
    }
    guard schema.schemaVersion == 1 else {
      throw YabaiConfigurationError.invalid(
        source,
        "unsupported schema_version \(schema.schemaVersion); expected 1"
      )
    }
    try validate(settings, source: source)
    return settings
  }

  private func validate(_ settings: YabaiSettings, source: URL) throws {
    guard ["bsp", "stack", "float"].contains(settings.layout) else {
      throw YabaiConfigurationError.invalid(source, "layout is unsupported")
    }
    guard ["first_child", "second_child"].contains(settings.windowPlacement) else {
      throw YabaiConfigurationError.invalid(source, "window_placement is unsupported")
    }
    guard ["first", "last"].contains(settings.windowInsertionPoint) else {
      throw YabaiConfigurationError.invalid(source, "window_insertion_point is unsupported")
    }
    guard (0.1...0.9).contains(settings.splitRatio) else {
      throw YabaiConfigurationError.invalid(source, "split_ratio must be between 0.1 and 0.9")
    }
    for (field, value) in [
      ("top_padding", settings.topPadding),
      ("bottom_padding", settings.bottomPadding),
      ("left_padding", settings.leftPadding),
      ("right_padding", settings.rightPadding),
      ("window_gap", settings.windowGap),
      ("external_bar_height", settings.externalBarHeight),
    ] {
      guard (0...256).contains(value) else {
        throw YabaiConfigurationError.invalid(source, "\(field) must be between 0 and 256")
      }
    }
    guard ["alt", "cmd", "ctrl", "shift"].contains(settings.mouseModifier) else {
      throw YabaiConfigurationError.invalid(source, "mouse_modifier is unsupported")
    }
    guard ["move", "resize"].contains(settings.mouseAction1),
      ["move", "resize"].contains(settings.mouseAction2)
    else {
      throw YabaiConfigurationError.invalid(source, "mouse actions must be move or resize")
    }
    guard !settings.rules.isEmpty else {
      throw YabaiConfigurationError.invalid(source, "rules must not be empty")
    }
    for (index, rule) in settings.rules.enumerated() {
      let selectors = [rule.label, rule.app, rule.title, rule.role, rule.subrole].compactMap { $0 }
      guard !selectors.isEmpty else {
        throw YabaiConfigurationError.invalid(source, "rule \(index + 1) has no selector")
      }
      guard
        selectors.allSatisfy({
          !$0.isEmpty && !$0.contains("'") && !$0.contains("\n") && !$0.contains("\0")
        })
      else {
        throw YabaiConfigurationError.invalid(source, "rule \(index + 1) has an unsafe selector")
      }
    }
  }

  private func readHook(at source: URL) throws -> (text: String, digest: String) {
    let text = try readText(at: source.resolvingSymlinksInPath(), maximumSize: 1_048_576)
    guard !text.contains("\0") else {
      throw YabaiConfigurationError.invalid(source, "trusted hook contains a NUL byte")
    }
    return (text, sha256Digest(Data(text.utf8)))
  }

  private func readText(at source: URL, maximumSize: Int) throws -> String {
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: source, maximumSize: maximumSize).data
    } catch {
      throw YabaiConfigurationError.cannotRead(source, String(describing: error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw YabaiConfigurationError.invalid(source, "file is not valid UTF-8")
    }
    return text
  }

  private func render(
    settings: YabaiSettings,
    topBarEnabled: Bool,
    hook: String?
  ) -> String {
    let command = #""$YABAI" -m config"#
    var lines = [
      "# Generated by Macarchy. Do not edit.",
      "YABAI=/opt/homebrew/bin/yabai",
      "",
      "\(command) layout \(settings.layout)",
      "\(command) window_placement \(settings.windowPlacement)",
      "\(command) window_insertion_point \(settings.windowInsertionPoint)",
      "\(command) auto_balance \(settings.autoBalance ? "on" : "off")",
      "\(command) split_ratio \(Self.decimal(settings.splitRatio))",
      "",
      "\(command) top_padding \(settings.topPadding)",
      "\(command) bottom_padding \(settings.bottomPadding)",
      "\(command) left_padding \(settings.leftPadding)",
      "\(command) right_padding \(settings.rightPadding)",
      "\(command) window_gap \(settings.windowGap)",
      "",
      "\(command) mouse_follows_focus \(settings.mouseFollowsFocus ? "on" : "off")",
      "\(command) mouse_modifier \(settings.mouseModifier)",
      "\(command) mouse_action1 \(settings.mouseAction1)",
      "\(command) mouse_action2 \(settings.mouseAction2)",
    ]
    if topBarEnabled {
      lines += ["", "\(command) external_bar all:\(settings.externalBarHeight):0"]
    }
    lines += ["", "# Packaged exclusions"]
    lines += settings.rules.map { rule in
      let fields: [(String, String?)] = [
        ("label", rule.label), ("app", rule.app), ("title", rule.title),
        ("role", rule.role), ("subrole", rule.subrole),
      ]
      let selectors = fields.compactMap { key, value in
        value.map { "\(key)='\($0)'" }
      }.joined(separator: " ")
      return "\"$YABAI\" -m rule --add \(selectors) manage=off"
    }
    lines += [
      "",
      "# Reconcile canonical wallpaper when an inactive Space becomes active.",
      #""$YABAI" -m signal --remove macarchy-wallpaper >/dev/null 2>&1 || true"#,
      #""$YABAI" -m signal --add event=space_changed label=macarchy-wallpaper action='/opt/homebrew/bin/macarchy reconcile wallpaper'"#,
    ]
    if let hook {
      lines += ["", "# Begin trusted user hook."]
      lines.append(hook.hasSuffix("\n") ? String(hook.dropLast()) : hook)
      lines.append("# End trusted user hook.")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func decimal(_ value: Double) -> String {
    var rendered = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    while rendered.last == "0" { rendered.removeLast() }
    if rendered.last == "." { rendered.append("0") }
    return rendered
  }
}

private struct YabaiInputIdentity: Encodable {
  let schemaVersion: Int
  let desktopProvider: String
  let topBarProvider: String
  let settings: YabaiSettings
  let hookDigest: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case desktopProvider = "desktop_provider"
    case topBarProvider = "top_bar_provider"
    case settings
    case hookDigest = "hook_digest"
  }
}

private struct YabaiDefaultsSchema: Decodable {
  let schemaVersion: Int

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
  }
}
