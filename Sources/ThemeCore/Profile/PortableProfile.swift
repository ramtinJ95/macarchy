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

package enum SketchyBarModule: String, Codable, Hashable, Sendable {
  case spaces
  case clock
}

package struct SketchyBarProfileOptions: Equatable, Sendable {
  package let left: [SketchyBarModule]?
  package let center: [SketchyBarModule]?
  package let right: [SketchyBarModule]?
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

package struct PortableProfile: Equatable, Sendable {
  package let sourceURL: URL?
  package let keybindings: KeybindingProfile
  package let desktop: DesktopProfile
  package let topBar: TopBarProviderSelection
  package let sketchyBar: SketchyBarProfileOptions

  package static let defaults = PortableProfile(
    sourceURL: nil,
    keybindings: .empty,
    desktop: DesktopProfile(provider: .yabaiSkhd, yabai: .empty),
    topBar: .sketchybar,
    sketchyBar: .empty
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

    let allowedTables = Set(["keybindings", "desktop", "yabai", "top_bar", "sketchybar"])
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
    let sketchyBar = try sketchyBar(document.sketchyBar, source: sourceURL)
    return PortableProfile(
      sourceURL: sourceURL,
      keybindings: keybindings,
      desktop: desktop,
      topBar: topBar,
      sketchyBar: sketchyBar
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
    source: URL
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
    return SketchyBarProfileOptions(
      left: document?.left,
      center: document?.center,
      right: document?.right
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
    let resolved = base.appending(path: path).standardizedFileURL
    let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
    guard resolved.path.hasPrefix(prefix) else {
      throw KeybindingProfileError.invalid(source, "\(field) must stay beside the profile")
    }
    return resolved
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
    right: nil
  )
}

private struct PortableProfileDocument: Decodable {
  let schemaVersion: Int
  let keybindings: KeybindingsDocument?
  let desktop: DesktopDocument?
  let yabai: YabaiDocument?
  let topBar: TopBarDocument?
  let sketchyBar: SketchyBarDocument?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case keybindings
    case desktop
    case yabai
    case topBar = "top_bar"
    case sketchyBar = "sketchybar"
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
}
