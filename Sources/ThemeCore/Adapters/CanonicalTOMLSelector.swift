import Foundation

package struct CanonicalTOMLSelector {
  package let tableHeaderCount: Int
  package let values: [String]

  package init(configuration: String, table: String, key: String) {
    var arrayDepth = 0
    var multilineQuote: MultilineQuote?
    var inSelectionTable = false
    var tableHeaderCount = 0
    var values = [String]()

    for rawLine in configuration.split(
      omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    {
      let startsAtTopLevel = arrayDepth == 0 && multilineQuote == nil
      let raw = String(rawLine)
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if startsAtTopLevel, trimmed.hasPrefix("[") {
        let header = trimmed.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        inSelectionTable = header == "[\(table)]"
        if inSelectionTable { tableHeaderCount += 1 }
        continue
      }

      let line = scanTOMLLine(
        raw,
        arrayDepth: &arrayDepth,
        multilineQuote: &multilineQuote
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard startsAtTopLevel, inSelectionTable else { continue }
      let parts = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.first == key {
        values.append(parts.count == 2 ? parts[1] : "")
      }
    }

    self.tableHeaderCount = tableHeaderCount
    self.values = values
  }
}

private enum MultilineQuote {
  case basic
  case literal
}

private func scanTOMLLine(
  _ line: String,
  arrayDepth: inout Int,
  multilineQuote: inout MultilineQuote?
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
