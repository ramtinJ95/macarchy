import Foundation
import TOMLDecoder

/// Byte edits own only one import element and its punctuation, or an introduced table/line.
package struct AlacrittyImportEdit: Codable, Equatable, Sendable {
  package struct Change: Codable, Equatable, Sendable {
    let offset: Int
    let removed: Data
    let inserted: Data
  }
  package let themePath: String
  package let elementIndex: Int
  package let introducedTable: Bool
  package let changes: [Change]
  enum CodingKeys: String, CodingKey {
    case themePath = "theme_path"
    case elementIndex = "element_index"
    case introducedTable = "introduced_table"
    case changes
  }
  package var hasValidShape: Bool {
    themePath.hasPrefix("/") && themePath.utf8.count < 16_384 && elementIndex >= 0
      && !changes.isEmpty && changes.count <= 2
      && changes.allSatisfy {
        $0.offset >= 0 && $0.offset <= BoundedRegularFile.maximumSize
          && $0.removed.count <= BoundedRegularFile.maximumSize
          && $0.removed.allSatisfy({ $0 == 10 || $0 == 13 })
          && !$0.inserted.isEmpty && $0.inserted.count < 32_768
      } && changes.map(\.offset) == changes.map(\.offset).sorted()
  }
  package enum Failure: Error, CustomStringConvertible, Equatable {
    case manual(String)
    case drift
    case tableInUse
    package var description: String {
      switch self {
      case .manual(let reason):
        "Alacritty manual boundary: \(reason). Use a [general] table with import = [string paths]; move legacy top-level import into that table."
      case .drift:
        "The owned Alacritty import element or its separator was edited, moved or removed"
      case .tableInUse:
        "The Macarchy-introduced [general] table now contains user settings; removing it would change their scope. Teardown requires manual separation of those settings."
      }
    }
  }
  struct Document: Decodable {
    struct General: Decodable {
      let imports: [String]?
      let liveConfigReload: Bool?
      enum CodingKeys: String, CodingKey {
        case imports = "import"
        case liveConfigReload = "live_config_reload"
      }
    }
    let general: General?
    let imports: [String]?
    let liveConfigReload: Bool?
    enum CodingKeys: String, CodingKey {
      case general
      case imports = "import"
      case liveConfigReload = "live_config_reload"
    }
  }
  static func document(_ text: String) throws -> Document {
    do { return try TOMLDecoder().decode(Document.self, from: text) } catch {
      throw Failure.manual("invalid TOML or import is not an array of strings: \(error)")
    }
  }
  package static func imports(_ text: String) throws -> [String] {
    let doc = try document(text)
    guard doc.imports == nil else {
      throw Failure.manual("legacy top-level import takes precedence")
    }
    return doc.general?.imports ?? []
  }
  package static func liveReload(_ text: String) throws -> Bool {
    let doc = try document(text)
    return doc.liveConfigReload ?? doc.general?.liveConfigReload ?? true
  }
  package static func adopting(_ data: Data, themePath: String) throws -> Self {
    guard let text = String(data: data, encoding: .utf8) else {
      throw BoundedRegularFileError.invalidUTF8
    }
    let doc = try document(text)
    guard doc.imports == nil else {
      throw Failure.manual("legacy top-level import takes precedence")
    }
    let selector = CanonicalTOMLSelector(configuration: text, table: "general", key: "import")
    guard selector.tableHeaderCount <= 1,
      doc.general == nil || selector.selectionTableHeader != nil,
      doc.general?.imports == nil || selector.assignments.count == 1
    else {
      throw Failure.manual(
        "dotted general.import, inline general, or noncanonical keys cannot be edited safely")
    }
    guard !(doc.general?.imports ?? []).contains(themePath) else {
      throw Failure.manual("an unowned Macarchy import already exists")
    }
    let value = try basicString(themePath)
    var changes: [Change] = []
    func insert(_ offset: Int, _ string: String) {
      changes.append(Change(offset: offset, removed: Data(), inserted: Data(string.utf8)))
    }
    func offset(_ index: String.Index) -> Int { text[..<index].utf8.count }
    if let assignment = selector.assignments.first {
      let start = offset(assignment.contentRange.lowerBound)
      let bytes = Array(data)
      let end = offset(assignment.contentRange.upperBound)
      guard let equals = bytes[start..<end].firstIndex(of: 61) else { throw Failure.drift }
      let tokens = try arrayTokens(bytes, from: equals + 1, end: end)
      guard let open = tokens.first, open.kind == 91,
        let close = tokens.last, close.kind == 93
      else { throw Failure.manual("import is not a literal array") }
      let contents = Array(tokens.dropFirst().dropLast())
      let lastString = contents.last(where: { $0.kind == 34 })
      let trailingComma = contents.last?.kind == 44
      let multiline = bytes[open.end..<close.start].contains(10)
      if multiline {
        let lineStart = (bytes[..<close.start].lastIndex(of: 10).map { $0 + 1 }) ?? 0
        let closingIndent = bytes[lineStart..<close.start]
        if closingIndent.allSatisfy({ $0 == 32 || $0 == 9 }) {
          if let lastString, !trailingComma { insert(lastString.end, ",") }
          var indent = String(decoding: closingIndent, as: UTF8.self) + "  "
          if let first = contents.first(where: { $0.kind == 34 }) {
            let beginning = (bytes[..<first.start].lastIndex(of: 10).map { $0 + 1 }) ?? 0
            let prefix = bytes[beginning..<first.start]
            if prefix.allSatisfy({ $0 == 32 || $0 == 9 }) {
              indent = String(decoding: prefix, as: UTF8.self)
            }
          }
          insert(
            lineStart, indent + value + (trailingComma ? "," : "") + tomlPreferredNewline(in: text))
        } else {
          let point = contents.last?.end ?? open.end
          insert(
            point,
            (lastString != nil && !trailingComma ? "," : "") + " " + value
              + (trailingComma ? "," : ""))
        }
      } else {
        let point = contents.last?.end ?? open.end
        insert(
          point,
          (lastString != nil ? (trailingComma ? " " : ", ") : "") + value
            + (trailingComma ? "," : ""))
      }
    } else if let header = selector.selectionTableHeader {
      insert(
        offset(header.fullRange.upperBound),
        (header.terminator.isEmpty ? "\n" : "") + "import = [\(value)]\n")
    } else {
      var end = data.count
      while end > 0 && (data[end - 1] == 10 || data[end - 1] == 13) { end -= 1 }
      changes.append(
        Change(
          offset: end, removed: data.subdata(in: end..<data.count),
          inserted: Data(((end == 0 ? "" : "\n\n") + "[general]\nimport = [\(value)]\n").utf8)))
    }
    let edit = Self(
      themePath: themePath, elementIndex: doc.general?.imports?.count ?? 0,
      introducedTable: selector.selectionTableHeader == nil, changes: changes)
    guard edit.hasValidShape else { throw Failure.manual("theme path is not safely representable") }
    _ = try imports(String(decoding: edit.apply(to: data), as: UTF8.self))
    return edit
  }
  package func apply(to original: Data) throws -> Data {
    var result = original
    for change in changes.reversed() {
      let end = change.offset + change.removed.count
      guard end <= result.count,
        result.subdata(in: change.offset..<end) == change.removed
      else { throw Failure.drift }
      result.replaceSubrange(change.offset..<end, with: change.inserted)
    }
    guard result.count <= BoundedRegularFile.maximumSize else {
      throw Failure.manual("configuration exceeds the size limit")
    }
    return result
  }
  package func validateManaged(_ managed: Data) throws {
    guard hasValidShape else { throw Failure.drift }
    var delta = 0
    for change in changes {
      let start = change.offset + delta
      let end = start + change.inserted.count
      guard start >= 0, end <= managed.count,
        managed.subdata(in: start..<end) == change.inserted
      else { throw Failure.drift }
      delta += change.inserted.count - change.removed.count
    }
    let imports = try Self.imports(String(decoding: managed, as: UTF8.self))
    guard imports.indices.filter({ imports[$0] == themePath }) == [elementIndex] else {
      throw Failure.drift
    }
  }

  package func restore(_ managed: Data) throws -> Data {
    try validateManaged(managed)
    if introducedTable {
      let general = try TOMLTable(source: managed).table(forKey: "general")
      guard general.keys == ["import"] else { throw Failure.tableInUse }
    }
    var result = managed
    var delta = changes.reduce(0) { $0 + $1.inserted.count - $1.removed.count }
    for change in changes.reversed() {
      delta -= change.inserted.count - change.removed.count
      let start = change.offset + delta
      let end = start + change.inserted.count
      var replacement = change.removed
      // An appended user table must not join an originally unterminated comment/header.
      // With no later content the original bytes (including no final newline) still win.
      if end < result.count, change.inserted.last == 10,
        let preceding = replacement.last ?? result[..<start].last,
        preceding != 10 && preceding != 13, result[end] != 10 && result[end] != 13
      {
        replacement.append(
          contentsOf: tomlPreferredNewline(in: String(decoding: managed, as: UTF8.self)).utf8)
      }
      result.replaceSubrange(start..<end, with: replacement)
    }
    // Later user imports are allowed and reported as overrides. They are not ours
    // to remove; the element's recorded position and punctuation must still match.
    _ = try Self.adopting(result, themePath: themePath)
    return result
  }
  private static func basicString(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw Failure.manual("control characters in the theme path")
    }
    return "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
  private struct Token {
    let start: Int
    let end: Int
    let kind: UInt8
  }
  /// TOMLDecoder validates semantics; scan only source positions and punctuation.
  private static func arrayTokens(_ bytes: [UInt8], from: Int, end: Int) throws -> [Token] {
    var index = from
    var result: [Token] = []
    while index < end {
      let byte = bytes[index]
      if [9, 10, 13, 32].contains(byte) {
        index += 1
        continue
      }
      if byte == 35 {
        while index < end && bytes[index] != 10 { index += 1 }
        continue
      }
      let start = index
      if byte == 34 || byte == 39 {
        let triple = index + 2 < end && bytes[index + 1] == byte && bytes[index + 2] == byte
        let count = triple ? 3 : 1
        index += count
        var closed = false
        while index < end {
          if byte == 34 && bytes[index] == 92 {
            index += 2
            continue
          }
          if bytes[index] == byte,
            !triple || (index + 2 < end && bytes[index + 1] == byte && bytes[index + 2] == byte)
          {
            index += count
            closed = true
            break
          }
          index += 1
        }
        guard closed else { throw Failure.manual("unterminated import string") }
        result.append(Token(start: start, end: index, kind: 34))
      } else if [91, 93, 44].contains(byte) {
        index += 1
        result.append(Token(start: start, end: index, kind: byte))
      } else {
        throw Failure.manual("unsupported import array syntax")
      }
    }
    return result
  }
}
