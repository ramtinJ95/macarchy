import Foundation

struct TOMLFieldLocation {
  let path: String
  let line: Int
  let column: Int
}

struct TOMLSourceIndex {
  let fields: [TOMLFieldLocation]
  let tables: [TOMLFieldLocation]

  init(text: String, file: URL, syntaxRole: String = "Theme manifest") throws {
    var currentTable = ""
    var fields: [TOMLFieldLocation] = []
    var tables: [TOMLFieldLocation] = []

    for (offset, rawLine) in text.split(
      omittingEmptySubsequences: false,
      whereSeparator: { $0.isNewline }
    ).enumerated() {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      if trimmed.hasPrefix("[[") {
        guard trimmed.hasSuffix("]]") else {
          throw ThemeDiagnostic(
            location: .init(file: file, line: offset + 1, column: 1),
            message: "\(syntaxRole) array tables must end with ']]'"
          )
        }
        let table = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard Self.isBareKey(table) else {
          throw ThemeDiagnostic(
            location: .init(file: file, line: offset + 1, column: 1),
            field: table,
            message: "\(syntaxRole) tables must use bare names"
          )
        }
        currentTable = table
        let column =
          (line.firstIndex(of: "[").map { line.distance(from: line.startIndex, to: $0) } ?? 0) + 1
        tables.append(.init(path: table, line: offset + 1, column: column))
        continue
      }

      if trimmed.hasPrefix("["), let closing = trimmed.firstIndex(of: "]") {
        let start = trimmed.index(after: trimmed.startIndex)
        let table = String(trimmed[start..<closing]).trimmingCharacters(in: .whitespaces)
        guard Self.isBareKey(table) else {
          throw ThemeDiagnostic(
            location: .init(file: file, line: offset + 1, column: 1),
            field: table,
            message: "\(syntaxRole) tables must use bare names"
          )
        }
        currentTable = table
        let column =
          (line.firstIndex(of: "[").map { line.distance(from: line.startIndex, to: $0) } ?? 0) + 1
        tables.append(.init(path: table, line: offset + 1, column: column))
        continue
      }

      guard let equals = line.firstIndex(of: "=") else { continue }
      let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard !rawKey.isEmpty else { continue }
      guard Self.isBareKey(rawKey) else {
        throw ThemeDiagnostic(
          location: .init(file: file, line: offset + 1, column: 1),
          field: rawKey,
          message: "\(syntaxRole) keys must use bare names"
        )
      }
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
        throw ThemeDiagnostic(
          location: .init(file: file, line: offset + 1, column: 1),
          field: rawKey,
          message: "Multiline TOML strings are not supported in \(syntaxRole.lowercased())"
        )
      }
      let key = rawKey
      let path = currentTable.isEmpty ? key : "\(currentTable).\(key)"
      let column =
        (line.range(of: rawKey).map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? 0)
        + 1
      fields.append(.init(path: path, line: offset + 1, column: column))
    }

    self.fields = fields
    self.tables = tables
  }

  private static func isBareKey<S: StringProtocol>(_ value: S) -> Bool {
    !value.isEmpty
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
      }
  }

  func location(for path: String, file: URL) -> ThemeSourceLocation {
    guard let field = fields.first(where: { $0.path == path }) else {
      return ThemeSourceLocation(file: file)
    }
    return ThemeSourceLocation(file: file, line: field.line, column: field.column)
  }
}
