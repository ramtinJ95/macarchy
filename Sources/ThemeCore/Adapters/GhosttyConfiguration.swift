import Darwin
import Foundation

/// Ghostty 1.4.0's default-file order and breadth-first `config-file` queue.
package enum GhosttyConfiguration {
  package static func files(home: URL, xdgConfigurationHome: URL) -> [URL] {
    let directories = [
      xdgConfigurationHome.appending(path: "ghostty"),
      home.appending(path: "Library/Application Support/com.mitchellh.ghostty"),
    ]
    return directories.flatMap { directory in
      ["config", "config.ghostty"].map { directory.appending(path: $0) }
    }
  }

  package static func selectedFile(in files: [URL]) throws -> URL {
    for url in files.reversed() {
      var metadata = stat()
      if lstat(url.path, &metadata) == 0 { return url }
      guard errno == ENOENT else {
        throw AdapterConfigurationError.cannotReadConfiguration("Ghostty configuration", url)
      }
    }
    return files[0]
  }

  package static func includeDirective(root: URL) -> String {
    "config-file = ?\"\(StateLayout(root: root).currentThemeArtifact(GhosttyAdapter.outputPath).path)\""
  }

  package static func read(_ url: URL) throws -> String {
    try AdapterConfigurationFile.readUTF8(
      at: url.resolvingSymlinksInPath(),
      tooLarge: AdapterConfigurationError.configurationTooLarge("Ghostty configuration", url),
      unreadable: AdapterConfigurationError.cannotReadConfiguration("Ghostty configuration", url))
  }

  static let colorKeys: Set<String> = [
    "palette", "background", "foreground", "cursor-color", "cursor-text",
    "selection-background", "selection-foreground", "split-divider-color",
  ]

  struct Include {
    let url: URL
    let optional: Bool
  }

  /// Paths are not shell strings: Ghostty removes an optional leading ? and outer quotes,
  /// expands ~/ and resolves relative paths against the containing configuration file.
  static func include(_ value: String, source: URL, home: URL) -> Include? {
    guard !value.isEmpty else { return nil }
    var path = value
    let optional = path.hasPrefix("?")
    if optional { path.removeFirst() }
    if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
      path.removeFirst()
      path.removeLast()
    }
    guard !path.isEmpty else { return nil }
    let url: URL
    if path.hasPrefix("~/") {
      url = home.appending(path: String(path.dropFirst(2)))
    } else if path.hasPrefix("/") {
      url = URL(filePath: path)
    } else {
      url = source.deletingLastPathComponent().appending(path: path).resolvingSymlinksInPath()
    }
    return Include(url: url, optional: optional)
  }

  static func assignments(_ text: String) -> [(key: String, value: String)] {
    let contents = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    return contents.components(separatedBy: "\n").compactMap { line in
      let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
      var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
        value.removeFirst()
        value.removeLast()
      }
      return (String(line[..<separator]).trimmingCharacters(in: .whitespaces), value)
    }
  }

  /// Read-only, bounded simulation of Config.loadDefaultFiles/loadRecursiveFiles. Nested
  /// includes append to the same queue, not a recursive depth-first traversal. A reset clears it.
  package static func overrideMessage(files: [URL], root: URL, home: URL) -> String? {
    let canonical = StateLayout(root: root).currentThemeArtifact(GhosttyAdapter.outputPath)
      .standardizedFileURL
    var queue: [Include] = []
    var notices: [String] = []
    var loaded = Set<String>()
    var afterManaged = false
    let maximumFiles = 128
    var bytes = 0
    let maximumBytes = 4 * 1_048_576

    func load(_ item: Include, main: Bool) -> Bool {
      var metadata = stat()
      if stat(item.url.path, &metadata) != 0, errno == ENOENT, item.optional { return true }
      do {
        let text = try read(item.url)
        bytes += text.utf8.count
        guard bytes <= maximumBytes else {
          notices.append("Ghostty include inspection stopped at the 4 MiB limit.")
          return false
        }
        let values = assignments(text)
        if !main, afterManaged {
          let keys = Set(values.map(\.key)).intersection(colorKeys).sorted()
          if !keys.isEmpty {
            notices.append(
              "Ghostty color overrides: \(item.url.path) (\(keys.joined(separator: ", "))).")
          }
        }
        for assignment in values where assignment.key == "config-file" {
          if assignment.value.isEmpty {
            queue.removeAll()
          } else if let child = include(assignment.value, source: item.url, home: home) {
            guard queue.count < maximumFiles else {
              notices.append("Ghostty include inspection stopped at the 128-file limit.")
              return false
            }
            queue.append(child)
          }
        }
      } catch {
        notices.append("Ghostty include not checked: \(item.url.path): \(error)")
      }
      return true
    }

    for url in files {
      guard load(Include(url: url, optional: true), main: true) else {
        return notices.joined(separator: " ")
      }
    }
    var index = 0
    while index < queue.count {
      let item = queue[index]
      index += 1
      guard loaded.insert(item.url.path).inserted else { continue }
      guard loaded.count <= maximumFiles else {
        notices.append("Ghostty include inspection stopped at the 128-file limit.")
        break
      }
      if item.url == canonical {
        afterManaged = true
      } else if !load(item, main: false) {
        break
      }
    }
    if !afterManaged {
      notices.append(
        "Ghostty's config-file queue does not load the Macarchy include (it may have been reset).")
    }
    return notices.isEmpty ? nil : notices.joined(separator: " ")
  }
}
