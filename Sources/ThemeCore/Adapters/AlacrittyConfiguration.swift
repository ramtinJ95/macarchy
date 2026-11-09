import Darwin
import Foundation
import TOMLDecoder

package enum AlacrittyConfiguration {
  /// Alacritty v0.17.0 config/mod.rs and xdg 3.0.0: each XDG lookup
  /// includes CONFIG_DIRS before the next lookup, not just CONFIG_HOME.
  package static func files(home: URL, environment: [String: String]) -> [URL] {
    let xdg =
      environment["XDG_CONFIG_HOME"].flatMap {
        $0.hasPrefix("/") ? URL(filePath: $0).standardizedFileURL : nil
      } ?? home.appending(path: ".config")
    let configuredDirs = (environment["XDG_CONFIG_DIRS"] ?? "")
      .split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(filePath: String($0)) }
    let dirs = configuredDirs.isEmpty ? [URL(filePath: "/etc/xdg")] : configuredDirs
    let bases = [xdg] + dirs
    let paths =
      bases.map { $0.appending(path: "alacritty/alacritty.toml") }
      + bases.map { $0.appending(path: "alacritty.toml") }
      + [
        home.appending(path: ".config/alacritty/alacritty.toml"),
        home.appending(path: ".alacritty.toml"), URL(filePath: "/etc/alacritty/alacritty.toml"),
      ]
    var seen = Set<String>()
    return paths.filter { seen.insert($0.path).inserted }
  }

  package static func selectedFile(in files: [URL]) throws -> URL {
    for url in files {
      var metadata = stat()
      if lstat(url.path, &metadata) == 0 { return url }
      guard errno == ENOENT else {
        throw AdapterConfigurationError.cannotReadConfiguration("Alacritty configuration", url)
      }
    }
    for toml in files {
      let yaml = toml.deletingPathExtension().appendingPathExtension("yml")
      var metadata = stat()
      if lstat(yaml.path, &metadata) == 0 {
        throw AlacrittyImportEdit.Failure.manual(
          "legacy YAML configuration \(yaml.path) would be shadowed; run alacritty migrate first")
      }
      guard errno == ENOENT else {
        throw AdapterConfigurationError.cannotReadConfiguration(
          "Alacritty legacy YAML configuration", yaml)
      }
    }
    return files[0]
  }

  package static func read(_ url: URL) throws -> String {
    let data = try BoundedRegularFile.read(at: url.resolvingSymlinksInPath()).data
    guard let text = String(data: data, encoding: .utf8) else {
      throw BoundedRegularFileError.invalidUTF8
    }
    return text
  }

  struct ReloadState {
    let enabled: Bool
    let notices: [String]
  }

  /// Imports merge first, the main file last. A legacy root reload value takes
  /// precedence over general.live_config_reload even when inherited from an import.
  static func reloadState(configuration: String, source: URL, home: URL) throws -> ReloadState {
    var notices: [String] = []
    var count = 0
    var bytes = 0
    func load(_ text: String, _ url: URL, depth: Int) throws -> (legacy: Bool?, general: Bool?) {
      count += 1
      bytes += text.utf8.count
      guard count <= 128, bytes <= 4 * 1_048_576 else {
        throw AlacrittyImportEdit.Failure.manual(
          "live_config_reload inspection exceeded its include/size limit")
      }
      let doc = try AlacrittyImportEdit.document(text)
      var result: (legacy: Bool?, general: Bool?) = (nil, nil)
      for path in doc.imports ?? doc.general?.imports ?? [] {
        guard depth < 5 else {
          notices.append("Alacritty ignores imports beyond its five-level recursion limit.")
          break
        }
        let child =
          path.hasPrefix("~/")
          ? home.appending(path: String(path.dropFirst(2)))
          : path.hasPrefix("/")
            ? URL(filePath: path)
            : url.deletingLastPathComponent().appending(path: path)
        var metadata = stat()
        if stat(child.path, &metadata) != 0, errno == ENOENT {
          notices.append("Alacritty missing import skipped: \(child.path).")
          continue
        }
        let nested = try load(read(child), child, depth: depth + 1)
        result = (nested.legacy ?? result.legacy, nested.general ?? result.general)
      }
      return (
        doc.liveConfigReload ?? result.legacy, doc.general?.liveConfigReload ?? result.general
      )
    }
    let values = try load(configuration, source, depth: 0)
    return ReloadState(enabled: values.legacy ?? values.general ?? true, notices: notices)
  }

  /// Color values can be strings, indexed-color arrays, booleans or nested tables.
  /// Use TOMLTable for structural type inspection. A custom recursive Decodable
  /// cannot probe scalar values as keyed containers: TOMLDecoder retains their
  /// containing table, causing that probe to revisit the same keys indefinitely.
  private static func colorKeys(_ table: TOMLTable, depth: Int = 0) throws -> [String] {
    guard depth < 8 else {
      throw AlacrittyImportEdit.Failure.manual(
        "color override table nesting exceeds the inspection limit")
    }
    return try table.keys.sorted().flatMap { key in
      if let nested = try? table.table(forKey: key) {
        return try colorKeys(nested, depth: depth + 1).map { key + "." + $0 }
      }
      return [key]
    }
  }

  package static func overrideMessage(configuration: String, source: URL, root: URL, home: URL)
    -> String?
  {
    var notices: [String] = []
    var visited = Set<String>()
    var byteCount = configuration.utf8.count
    let theme = root.appending(path: AlacrittyAdapter.bridgePath).path
    func report(_ text: String, _ url: URL) throws {
      let table = try TOMLTable(source: text)
      guard table.contains(key: "colors") else { return }
      let keys = try colorKeys(table.table(forKey: "colors"))
      if !keys.isEmpty {
        notices.append(
          "Alacritty color overrides: \(url.path) (\(keys.map { "colors." + $0 }.joined(separator: ", ")))."
        )
      }
    }
    func visit(_ path: String, parent: URL, depth: Int) {
      let url =
        path.hasPrefix("~/")
        ? home.appending(path: String(path.dropFirst(2)))
        : path.hasPrefix("/")
          ? URL(filePath: path)
          : parent.deletingLastPathComponent().appending(path: path)
      guard visited.insert(url.standardizedFileURL.path).inserted else { return }
      guard visited.count <= 128, depth <= 5 else {
        notices.append("Alacritty override inspection reached its include limit.")
        return
      }
      do {
        let text = try read(url)
        byteCount += text.utf8.count
        guard byteCount <= 4 * 1_048_576 else {
          notices.append("Alacritty override inspection reached its 4 MiB limit.")
          return
        }
        // Native imports use legacy import first in user-owned included files.
        let doc = try AlacrittyImportEdit.document(text)
        for child in doc.imports ?? doc.general?.imports ?? [] {
          visit(child, parent: url, depth: depth + 1)
        }
        try report(text, url)
      } catch { notices.append("Alacritty include not checked: \(url.path): \(error)") }
    }
    do {
      let imports = try AlacrittyImportEdit.imports(configuration)
      if let owned = imports.firstIndex(of: theme) {
        for path in imports.dropFirst(owned + 1) { visit(path, parent: source, depth: 1) }
      }
      try report(configuration, source)
    } catch { notices.append("Alacritty overrides not checked: \(source.path): \(error)") }
    return notices.isEmpty ? nil : notices.joined(separator: " ")
  }
}
