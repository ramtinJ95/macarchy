import Foundation

package struct SkhdBinding: Equatable, Sendable {
  package let identity: String
  package let chord: String
  package let command: String
  package let line: Int
}

package enum SkhdDiagnosticCode: String, Sendable {
  case unsupportedSyntax = "unsupported_syntax"
  case duplicateChord = "duplicate_chord"
}

package struct SkhdDiagnostic: Equatable, Sendable {
  package let code: SkhdDiagnosticCode
  package let line: Int?
  package let relatedLine: Int?
  package let message: String

  package init(
    code: SkhdDiagnosticCode,
    line: Int? = nil,
    relatedLine: Int? = nil,
    message: String
  ) {
    self.code = code
    self.line = line
    self.relatedLine = relatedLine
    self.message = message
  }
}

package struct SkhdParseResult: Equatable, Sendable {
  package let bindings: [SkhdBinding]
  package let diagnostics: [SkhdDiagnostic]
}

package struct SkhdConfigurationParser: Sendable {
  package init() {}

  package func parse(_ text: String) -> SkhdParseResult {
    var bindings: [SkhdBinding] = []
    var diagnostics: [SkhdDiagnostic] = []
    var skippingUnsupportedContinuation = false

    for (offset, rawLine) in text.split(
      omittingEmptySubsequences: false,
      whereSeparator: { $0.isNewline }
    ).enumerated() {
      let lineNumber = offset + 1
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if skippingUnsupportedContinuation {
        skippingUnsupportedContinuation = line.hasSuffix("\\")
        continue
      }
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      if line.hasSuffix("\\") {
        diagnostics.append(
          unsupported(
            line: lineNumber,
            "multiline commands are not supported"
          )
        )
        skippingUnsupportedContinuation = true
        continue
      }

      guard let colon = line.firstIndex(of: ":") else {
        diagnostics.append(
          unsupported(
            line: lineNumber,
            "enabled lines must bind one key chord to one command"
          )
        )
        continue
      }

      let action = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      let command = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else {
        diagnostics.append(
          unsupported(line: lineNumber, "enabled bindings must contain a command")
        )
        continue
      }

      guard let parsedChord = parseChord(action) else {
        diagnostics.append(
          unsupported(
            line: lineNumber,
            "unsupported key chord '\(action)'"
          )
        )
        continue
      }

      bindings.append(
        SkhdBinding(
          identity: parsedChord.identity,
          chord: parsedChord.display,
          command: command,
          line: lineNumber
        )
      )
    }

    var firstLineByIdentity: [String: Int] = [:]
    for binding in bindings {
      if let firstLine = firstLineByIdentity[binding.identity] {
        diagnostics.append(
          SkhdDiagnostic(
            code: .duplicateChord,
            line: binding.line,
            relatedLine: firstLine,
            message:
              "chord '\(binding.chord)' duplicates the binding on line \(firstLine)"
          )
        )
      } else {
        firstLineByIdentity[binding.identity] = binding.line
      }
    }

    diagnostics.sort {
      ($0.line ?? 0, $0.code.rawValue) < ($1.line ?? 0, $1.code.rawValue)
    }
    return SkhdParseResult(bindings: bindings, diagnostics: diagnostics)
  }

  private func parseChord(_ action: String) -> (identity: String, display: String)? {
    guard !action.isEmpty else { return nil }

    let components = action.split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    let rawModifiers: [Substring]
    let rawKey: Substring
    if components.count == 1 {
      rawModifiers = []
      rawKey = components[0]
    } else {
      rawModifiers = components[0].split(
        separator: "+",
        omittingEmptySubsequences: false
      )
      rawKey = components[1]
    }

    let rawKeyValue = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = normalizedKey(rawKeyValue) else { return nil }

    var modifiers = Set<String>()
    for rawModifier in rawModifiers {
      let modifier = rawModifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.modifierOrder.contains(modifier), modifiers.insert(modifier).inserted else {
        return nil
      }
    }
    guard components.count == 1 || !modifiers.isEmpty else { return nil }

    let orderedModifiers = Self.modifierOrder.filter(modifiers.contains)
    if orderedModifiers.isEmpty {
      return (key, key)
    }
    return (
      orderedModifiers.joined(separator: "+") + "-" + key,
      orderedModifiers.joined(separator: " + ") + " - " + key
    )
  }

  private func normalizedKey(_ key: String) -> String? {
    if key.count == 1, let character = key.first {
      if character.isASCII && character.isNumber { return key }
      return character.isASCII && character.isLowercase ? key : nil
    }
    if Self.namedKeys.contains(key) { return key }
    guard key.hasPrefix("0x") else { return nil }
    let digits = key.dropFirst(2)
    guard (1...2).contains(digits.count),
      digits.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isLowercase })
    else {
      return nil
    }
    return "0x" + String(repeating: "0", count: 2 - digits.count) + digits.uppercased()
  }

  private func unsupported(line: Int, _ message: String) -> SkhdDiagnostic {
    SkhdDiagnostic(code: .unsupportedSyntax, line: line, message: message)
  }

  private static let modifierOrder = ["cmd", "ctrl", "alt", "shift"]
  private static let namedKeys = Set([
    "return", "tab", "space", "backspace", "escape", "delete", "home", "end", "pageup",
    "pagedown", "insert", "left", "right", "up", "down",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
    "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    "sound_up", "sound_down", "mute", "play", "previous", "next", "rewind", "fast",
    "brightness_up", "brightness_down", "illumination_up", "illumination_down",
  ])
}
