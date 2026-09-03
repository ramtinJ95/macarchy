import Foundation

package struct CanonicalTOMLSelector {
  package let tableHeaderCount: Int
  package let values: [String]
  package let assignments: [CanonicalTOMLAssignment]
  package let firstTopLevelTableIndex: String.Index?

  package init(configuration: String, table: String, key: String) {
    self.init(configuration: configuration, selectionTable: table, key: key)
  }

  package init(configuration: String, key: String) {
    self.init(configuration: configuration, selectionTable: nil, key: key)
  }

  package func selectsExactly(_ value: String) -> Bool {
    tableHeaderCount == 1 && values == [value]
  }

  private init(configuration: String, selectionTable: String?, key: String) {
    var arrayDepth = 0
    var multilineQuote: TOMLMultilineQuote?
    var inSelectionTable = selectionTable == nil
    var tableHeaderCount = 0
    var values = [String]()
    var assignments = [CanonicalTOMLAssignment]()
    var pendingAssignment: (lineIndex: Int, start: String.Index)?
    var firstTopLevelTableIndex: String.Index?

    for line in tomlPhysicalLines(configuration) {
      let startsAtTopLevel = arrayDepth == 0 && multilineQuote == nil
      let raw = String(configuration[line.contentRange])
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if startsAtTopLevel, trimmed.hasPrefix("[") {
        if firstTopLevelTableIndex == nil { firstTopLevelTableIndex = line.fullRange.lowerBound }
        let header = trimmed.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        inSelectionTable = selectionTable.map { header == "[\($0)]" } ?? false
        if inSelectionTable { tableHeaderCount += 1 }
        continue
      }

      let scanned = scanTOMLLine(
        raw,
        arrayDepth: &arrayDepth,
        multilineQuote: &multilineQuote
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if startsAtTopLevel, inSelectionTable {
        let parts = scanned.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == key {
          values.append(parts.count == 2 ? parts[1] : "")
          pendingAssignment = (line.lineIndex, line.fullRange.lowerBound)
        }
      }
      if let pending = pendingAssignment, arrayDepth == 0, multilineQuote == nil {
        assignments.append(
          CanonicalTOMLAssignment(
            lineIndex: pending.lineIndex,
            fullRange: pending.start..<line.fullRange.upperBound,
            contentRange: pending.start..<line.contentRange.upperBound
          )
        )
        pendingAssignment = nil
      }
    }

    self.tableHeaderCount = tableHeaderCount
    self.values = values
    self.assignments = assignments
    self.firstTopLevelTableIndex = firstTopLevelTableIndex
  }
}

package struct CanonicalTOMLAssignment {
  package let lineIndex: Int
  package let fullRange: Range<String.Index>
  package let contentRange: Range<String.Index>
}

package struct TOMLPhysicalLine {
  package let lineIndex: Int
  package let fullRange: Range<String.Index>
  package let contentRange: Range<String.Index>
  package let terminator: String
}

package func tomlPhysicalLines(_ text: String) -> [TOMLPhysicalLine] {
  guard !text.isEmpty else { return [] }
  var lines = [TOMLPhysicalLine]()
  var lineStart = text.startIndex
  var index = text.startIndex
  while index < text.endIndex {
    if text[index].isNewline {
      let afterNewline = text.index(after: index)
      lines.append(
        TOMLPhysicalLine(
          lineIndex: lines.count,
          fullRange: lineStart..<afterNewline,
          contentRange: lineStart..<index,
          terminator: String(text[index])
        )
      )
      lineStart = afterNewline
    }
    index = text.index(after: index)
  }
  if lineStart < text.endIndex {
    lines.append(
      TOMLPhysicalLine(
        lineIndex: lines.count,
        fullRange: lineStart..<text.endIndex,
        contentRange: lineStart..<text.endIndex,
        terminator: ""
      )
    )
  }
  return lines
}

enum TOMLMultilineQuote {
  case basic
  case literal
}

func scanTOMLLine(
  _ line: String,
  arrayDepth: inout Int,
  multilineQuote: inout TOMLMultilineQuote?
) -> String {
  let characters = Array(line)
  var visible = ""
  var index = 0
  var basicQuote = false
  var literalQuote = false
  var escaped = false

  while index < characters.count {
    let character = characters[index]
    let triple =
      index + 2 < characters.count
      && characters[index] == characters[index + 1]
      && characters[index] == characters[index + 2]

    if let quote = multilineQuote {
      visible.append(character)
      if triple,
        (quote == .basic && character == "\"")
          || (quote == .literal && character == "'")
      {
        visible.append(characters[index + 1])
        visible.append(characters[index + 2])
        multilineQuote = nil
        index += 3
      } else {
        index += 1
      }
      continue
    }

    if basicQuote {
      visible.append(character)
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        basicQuote = false
      }
      index += 1
      continue
    }
    if literalQuote {
      visible.append(character)
      if character == "'" { literalQuote = false }
      index += 1
      continue
    }

    if triple, character == "\"" || character == "'" {
      visible.append(character)
      visible.append(characters[index + 1])
      visible.append(characters[index + 2])
      multilineQuote = character == "\"" ? .basic : .literal
      index += 3
    } else if character == "\"" {
      basicQuote = true
      visible.append(character)
      index += 1
    } else if character == "'" {
      literalQuote = true
      visible.append(character)
      index += 1
    } else if character == "#" {
      break
    } else {
      if character == "[" { arrayDepth += 1 }
      if character == "]" { arrayDepth -= 1 }
      visible.append(character)
      index += 1
    }
  }
  return visible
}
