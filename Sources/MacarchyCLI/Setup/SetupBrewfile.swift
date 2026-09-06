import Foundation
import ThemeCore

/// Inert literal declarations, never Ruby evaluation. The generated file, not
/// a personal input, is passed to Homebrew.
struct SetupBrewfile: Equatable, Sendable {
  let packages: [HomebrewPackageIdentity]
  let taps: [String]

  init(packages: [HomebrewPackageIdentity], taps: [String] = []) {
    self.packages = Set(packages).sorted { $0.key < $1.key }
    self.taps = Set(taps).sorted()
  }

  /// Named missing roots only; unrelated declarative taps are not execution scope.
  static func installing(_ packages: [HomebrewPackageIdentity]) -> Self {
    Self(packages: packages, taps: packages.compactMap(\.tap))
  }

  static func read(at url: URL) throws -> Self {
    do {
      let data = try BoundedRegularFile.read(at: url).data
      guard let source = String(data: data, encoding: .utf8) else {
        throw SetupPackageAdoptionError("Brewfile must be UTF-8.")
      }
      return try parse(source)
    } catch {
      throw SetupPackageAdoptionError("Brewfile \(url.path): \(error)")
    }
  }

  static func parse(_ source: String) throws -> Self {
    guard source.utf8.count <= 1024 * 1024 else {
      throw SetupPackageAdoptionError("Brewfile exceeds 1 MiB.")
    }
    let pattern = #"^\s*(brew|cask|tap)\s+(?:"([a-z0-9+_.@/-]+)"|'([a-z0-9+_.@/-]+)')\s*(?:#.*)?$"#
    let expression = try NSRegularExpression(pattern: pattern)
    var packages = [HomebrewPackageIdentity]()
    var taps = [String]()
    for (offset, line) in source.components(separatedBy: .newlines).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let ns = line as NSString
      guard
        let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
      else {
        throw SetupPackageAdoptionError(
          "Unsupported Brewfile syntax at line \(offset + 1); only literal brew, cask and tap declarations are accepted."
        )
      }
      let kind = ns.substring(with: match.range(at: 1))
      let range =
        match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
      let name = ns.substring(with: range)
      let parts = name.components(separatedBy: "/")
      guard kind == "tap" ? parts.count == 2 : [1, 3].contains(parts.count),
        parts.allSatisfy(HomebrewPackageIdentity.validToken)
      else { throw SetupPackageAdoptionError("Invalid Brewfile identity at line \(offset + 1).") }
      if kind == "tap" {
        taps.append(name)
      } else {
        packages.append(.init(kind: kind == "brew" ? .formula : .cask, name: name))
      }
    }
    guard Set(packages).count == packages.count, Set(taps).count == taps.count else {
      throw SetupPackageAdoptionError("Duplicate Brewfile declarations.")
    }
    guard packages.count <= 1024, taps.count <= 1024 else {
      throw SetupPackageAdoptionError("Brewfile exceeds 1024 package declarations or taps.")
    }
    return Self(packages: packages, taps: taps)
  }

  var text: String {
    let lines =
      taps.map { "tap \"\($0)\"" }
      + packages.map {
        "\($0.kind == .formula ? "brew" : "cask") \"\($0.name)\""
      }
    return lines.joined(separator: "\n") + "\n"
  }
}
