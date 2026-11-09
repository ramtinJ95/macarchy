import Darwin
import Foundation

/// Kitty configuration that overrides the colors Macarchy's include sets: the auto theme files,
/// which Kitty applies over every configured color for the matching macOS appearance, and color
/// options set after the include, directly or through a later include. Macarchy reports these
/// and never writes into them.
struct KittyColorOverrides: Equatable, Sendable {
  struct Source: Equatable, Sendable {
    let description: String
    /// The color options it sets, in file order; nil when it could not be read, which Kitty
    /// also skips, so it is reported as unchecked rather than as an override.
    let keys: [String]?
  }

  /// Kitty's auto theme files (Kitty 0.38+), in its configuration directory, and the macOS
  /// appearance each applies to.
  static let autoThemeFiles: [(name: String, appearance: String)] = [
    ("light-theme.auto.conf", "when macOS is in Light mode"),
    ("dark-theme.auto.conf", "when macOS is in Dark mode"),
    ("no-preference-theme.auto.conf", "when macOS has no appearance preference"),
  ]

  /// Every Kitty option whose value is a color (Kitty 0.48), plus the palette.
  static let colorOptions: Set<String> = Set(
    [
      "foreground", "background", "selection_foreground", "selection_background", "cursor",
      "cursor_text_color", "cursor_trail_color", "url_color", "visual_bell_color",
      "active_border_color", "inactive_border_color", "bell_border_color",
      "macos_titlebar_color", "wayland_titlebar_color", "active_tab_foreground",
      "active_tab_background", "inactive_tab_foreground", "inactive_tab_background",
      "tab_bar_background", "tab_bar_margin_color", "mark1_foreground", "mark1_background",
      "mark2_foreground", "mark2_background", "mark3_foreground", "mark3_background",
      "scrollbar_handle_color", "scrollbar_track_color", "window_title_bar_active_foreground",
      "window_title_bar_active_background", "window_title_bar_inactive_foreground",
      "window_title_bar_inactive_background", "transparent_background_colors",
    ] + (0..<256).map { "color\($0)" })

  /// Keys named in a message before the rest are counted.
  static let listedKeyLimit = 6

  let sources: [Source]

  /// What the adapter reports alongside its status; nil when nothing overrides the theme.
  var message: String? {
    var parts: [String] = []
    let overriding = sources.compactMap { source in
      source.keys.map { "\(source.description) (\(Self.describe($0)))" }
    }
    if !overriding.isEmpty {
      parts.append("Theme colors are overridden by " + overriding.joined(separator: "; "))
    }
    let unreadable = sources.filter { $0.keys == nil }.map(\.description)
    if !unreadable.isEmpty {
      parts.append(
        "Not checked for color overrides because it could not be read: "
          + unreadable.joined(separator: "; "))
    }
    return parts.isEmpty ? nil : parts.joined(separator: ". ")
  }

  private static func describe(_ keys: [String]) -> String {
    guard !keys.isEmpty else { return "sets no colors, so Kitty's defaults show" }
    guard keys.count > listedKeyLimit else { return keys.joined(separator: ", ") }
    return keys.prefix(listedKeyLimit).joined(separator: ", ")
      + " and \(keys.count - listedKeyLimit) more"
  }

  /// Finds the overrides of `configuration`, Kitty's configuration file in `directory`, whose
  /// line `includeDirective` includes Macarchy's theme. Later includes are read one level deep.
  static func inspect(
    configuration: String,
    directory: URL,
    includeDirective: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    read: (URL) throws -> String = {
      try BoundedRegularFile.readUTF8(at: $0.resolvingSymlinksInPath())
    }
  ) -> Self {
    var sources: [Source] = []
    for file in autoThemeFiles {
      let url = directory.appending(path: file.name)
      guard exists(url) else { continue }
      sources.append(
        Source(
          description: "\(file.name), which replaces every color \(file.appearance)",
          keys: try? colorKeys(in: read(url))))
    }

    let lines = configuration.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      let include = lines.lastIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == includeDirective
      })
    else { return Self(sources: sources) }
    var direct: [String] = []
    for line in lines[(include + 1)...] {
      guard let (key, value) = directive(line) else { continue }
      if colorOptions.contains(key) {
        appendUnique(key, to: &direct)
      } else if key == "include" || key == "globinclude" {
        for url in includedFiles(
          value, glob: key == "globinclude", directory: directory, environment: environment)
        {
          let keys = try? colorKeys(in: read(url))
          if keys?.isEmpty == true { continue }
          sources.append(
            Source(description: "\(url.path), included after Macarchy's theme", keys: keys))
        }
      }
    }
    if !direct.isEmpty {
      sources.append(
        Source(description: "kitty.conf lines after Macarchy's theme include", keys: direct))
    }
    return Self(sources: sources)
  }

  /// The color options `text` sets, each once, in order.
  static func colorKeys(in text: String) -> [String] {
    var keys: [String] = []
    for line in text.split(separator: "\n") {
      if let (key, _) = directive(line), colorOptions.contains(key) {
        appendUnique(key, to: &keys)
      }
    }
    return keys
  }

  /// A configuration line's option and value; nil for blank lines and comments.
  private static func directive(_ line: Substring) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
    return (
      String(parts[0]),
      parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    )
  }

  private static func appendUnique(_ key: String, to keys: inout [String]) {
    if !keys.contains(key) { keys.append(key) }
  }

  /// The files an include names, as Kitty resolves them: `~` and environment variables expanded,
  /// relative paths against the configuration directory, and a glob include matched like
  /// Python's `Path.glob` (`**` spans directories, `*` also matches hidden names), sorted.
  private static func includedFiles(
    _ value: String, glob isGlob: Bool, directory: URL, environment: [String: String]
  ) -> [URL] {
    guard !value.isEmpty else { return [] }
    let expanded = expandVariables((value as NSString).expandingTildeInPath, environment)
    guard isGlob else {
      let url =
        expanded.hasPrefix("/") ? URL(filePath: expanded) : directory.appending(path: expanded)
      return exists(url) ? [url] : []
    }
    var matches = [expanded.hasPrefix("/") ? URL(filePath: "/") : directory]
    for component in expanded.split(separator: "/").map(String.init) {
      matches = matches.flatMap { match -> [URL] in
        switch component {
        case ".", "..": return [match.appending(path: component)]
        case "**": return [match] + descendantDirectories(of: match)
        default:
          let names = (try? FileManager.default.contentsOfDirectory(atPath: match.path)) ?? []
          return names.filter { fnmatch(component, $0, 0) == 0 }.map {
            match.appending(path: $0)
          }
        }
      }
    }
    var seen = Set<String>()
    return matches.filter { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue && seen.insert(url.standardizedFileURL.path).inserted
    }.sorted { $0.path < $1.path }
  }

  /// `$NAME` and `${NAME}` replaced from `environment`; unknown names stay as written, as with
  /// Python's `os.path.expandvars`, which Kitty uses.
  private static func expandVariables(_ path: String, _ environment: [String: String]) -> String {
    let pattern = /\$(?:\{([A-Za-z0-9_]+)\}|([A-Za-z0-9_]+))/
    return path.replacing(pattern) { match in
      let name = String(match.output.1 ?? match.output.2 ?? "")
      return environment[name] ?? String(match.output.0)
    }
  }

  /// Every directory below `url`, without following symbolic links, as `Path.glob` does.
  private static func descendantDirectories(of url: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
      let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      return values?.isDirectory == true && values?.isSymbolicLink != true
    }
  }

  private static func exists(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
  }
}
