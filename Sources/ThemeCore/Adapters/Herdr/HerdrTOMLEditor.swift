import Foundation
import TOMLDecoder

extension HerdrAdapter {
  package static func validateConfiguration(_ configuration: String) throws {
    _ = try parseConfiguration(configuration)
  }

  package struct ManagedSurface: Codable, Equatable, Sendable {
    package let name: String?
    package let custom: [String: String]

    package init(name: String?, custom: [String: String]) {
      self.name = name
      self.custom = custom
    }

    func matches(_ desired: GeneratedHerdrTheme) -> Bool {
      name == desired.name && custom == desired.custom
    }

  }

  package struct ParsedConfiguration {
    package let themeHeaderIndex: Int
    package let customHeaderIndex: Int?
    package let nameIndex: Int?
    package let customIndices: [String: Int]
    package let selection: String?
    package let custom: [String: String]

    package var surface: ManagedSurface {
      ManagedSurface(
        name: selection,
        custom: custom
      )
    }
  }

  private struct ConfigurationDocument: Decodable {
    let theme: ThemeConfiguration
  }

  private struct ThemeConfiguration: Decodable {
    let name: String?
    let autoSwitch: Bool?
    let custom: [String: String]?

    enum CodingKeys: String, CodingKey {
      case name, custom
      case autoSwitch = "auto_switch"
    }
  }

  private enum ConfigurationSection {
    case theme
    case custom
    case other
  }

  package static func parseConfiguration(_ configuration: String) throws -> ParsedConfiguration {
    let document: ConfigurationDocument
    do {
      document = try TOMLDecoder().decode(ConfigurationDocument.self, from: configuration)
    } catch {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    guard document.theme.autoSwitch != true else {
      throw HerdrAdapterError.automaticThemeSwitching
    }

    let lines = configuration.components(separatedBy: "\n")
    var arrayDepth = 0
    var multilineQuote: TOMLMultilineQuote?
    var section = ConfigurationSection.other
    var themeHeaders = [Int]()
    var customHeaders = [Int]()
    var nameIndices = [Int]()
    var customIndices = [String: Int]()
    var customValues = [String: String]()

    for (index, rawLine) in lines.enumerated() {
      let startsAtTopLevel = arrayDepth == 0 && multilineQuote == nil
      let line = scanTOMLLine(
        rawLine,
        arrayDepth: &arrayDepth,
        multilineQuote: &multilineQuote
      ).trimmingCharacters(in: .whitespacesAndNewlines)

      if startsAtTopLevel, line.hasPrefix("[") {
        switch line {
        case "[theme]":
          section = .theme
          themeHeaders.append(index)
        case "[theme.custom]":
          section = .custom
          customHeaders.append(index)
        default:
          section = .other
        }
        continue
      }
      guard startsAtTopLevel, !line.isEmpty else { continue }

      switch section {
      case .theme:
        let parts = line.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "name" {
          guard parseEditableStringAssignment(rawLine, expectedKey: "name") != nil else {
            throw HerdrAdapterError.invalidThemeConfiguration
          }
          nameIndices.append(index)
        }
      case .custom:
        guard let assignment = parseEditableStringAssignment(rawLine),
          customKeySet.contains(assignment.key),
          SRGBColor(rawValue: assignment.value) != nil,
          customIndices[assignment.key] == nil
        else {
          throw HerdrAdapterError.invalidThemeConfiguration
        }
        customIndices[assignment.key] = index
        customValues[assignment.key] = assignment.value.lowercased()
      case .other:
        continue
      }
    }

    guard themeHeaders.count == 1,
      customHeaders.count <= 1,
      nameIndices.count <= 1,
      document.theme.name == nil || nameIndices.count == 1,
      (document.theme.custom != nil) == (customHeaders.count == 1),
      (document.theme.custom ?? [:]).mapValues({ $0.lowercased() }) == customValues
    else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }

    return ParsedConfiguration(
      themeHeaderIndex: themeHeaders[0],
      customHeaderIndex: customHeaders.first,
      nameIndex: nameIndices.first,
      customIndices: customIndices,
      selection: document.theme.name,
      custom: customValues
    )
  }

  private static func parseEditableStringAssignment(
    _ rawLine: String,
    expectedKey: String? = nil
  ) -> (key: String, value: String)? {
    var arrayDepth = 0
    var multilineQuote: TOMLMultilineQuote?
    let line = scanTOMLLine(
      rawLine,
      arrayDepth: &arrayDepth,
      multilineQuote: &multilineQuote
    )
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let key = parts[0].trimmingCharacters(in: .whitespaces)
    guard TOMLSourceIndex.isBareKey(key),
      expectedKey == nil || key == expectedKey
    else { return nil }

    let value = parts[1].trimmingCharacters(in: .whitespaces)
    guard value.first == "\"" else { return nil }
    let contentAndTail = value.dropFirst()
    guard let closingQuote = contentAndTail.firstIndex(of: "\"") else { return nil }
    let content = contentAndTail[..<closingQuote]
    guard !content.contains("\\") else { return nil }
    let tail = contentAndTail[contentAndTail.index(after: closingQuote)...]
      .trimmingCharacters(in: .whitespaces)
    guard tail.isEmpty else { return nil }
    return (key, String(content))
  }

  package static func replacingManagedSurface(
    in configuration: String,
    parsed: ParsedConfiguration,
    with desired: ManagedSurface
  ) throws -> String {
    guard let name = desired.name else { throw HerdrAdapterError.invalidOwnership }
    let newline = tomlPreferredNewline(in: configuration)
    let replacement = "name = \"\(name)\""
    var updated = configuration
    if let nameIndex = parsed.nameIndex {
      let lines = tomlPhysicalLines(updated)
      guard nameIndex < lines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      let line = lines[nameIndex]
      let current = String(updated[line.contentRange])
      let indentation = current.prefix { $0 == " " || $0 == "\t" }
      updated.replaceSubrange(
        line.contentRange,
        with: String(indentation) + replacement + commentSuffix(in: current)
      )
    } else {
      let lines = tomlPhysicalLines(updated)
      guard parsed.themeHeaderIndex < lines.count else {
        throw HerdrAdapterError.invalidThemeConfiguration
      }
      let header = lines[parsed.themeHeaderIndex]
      let insertion =
        (header.terminator.isEmpty ? newline : "") + replacement + newline
      updated.insert(contentsOf: insertion, at: header.fullRange.upperBound)
    }

    let afterName = try parseConfiguration(updated)
    let namedLines = tomlPhysicalLines(updated)
    for index in afterName.customIndices.values.sorted(by: >) {
      guard index < namedLines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      updated.removeSubrange(namedLines[index].fullRange)
    }

    guard !desired.custom.isEmpty else {
      return updated
    }

    let keys: [String]
    switch Set(desired.custom.keys) {
    case legacyCustomKeySet: keys = legacyCustomKeys
    case customKeySet: keys = customKeys
    default: throw HerdrAdapterError.invalidGeneratedTheme
    }
    let reparsed = try parseConfiguration(updated)
    let customLines =
      keys.map { key in
        "\(key) = \"\(desired.custom[key]!)\""
      }.joined(separator: newline) + newline
    if let header = reparsed.customHeaderIndex {
      let lines = tomlPhysicalLines(updated)
      guard header < lines.count else { throw HerdrAdapterError.invalidThemeConfiguration }
      let headerLine = lines[header]
      let insertion = (headerLine.terminator.isEmpty ? newline : "") + customLines
      updated.insert(contentsOf: insertion, at: headerLine.fullRange.upperBound)
      return updated
    }

    if !updated.hasSuffix("\n"), !updated.hasSuffix("\r") { updated.append(newline) }
    if !updated.hasSuffix(newline + newline) { updated.append(newline) }
    updated += "[theme.custom]" + newline + customLines
    return updated
  }

  private static func commentSuffix(in line: String) -> String {
    guard let equals = line.firstIndex(of: "=") else { return "" }
    let value = line[line.index(after: equals)...]
    guard let opening = value.firstIndex(of: "\"") else { return "" }
    let tail = value[value.index(after: opening)...]
    guard let closing = tail.firstIndex(of: "\"") else { return "" }
    let remainder = tail[tail.index(after: closing)...]
    guard let comment = remainder.firstIndex(of: "#") else { return "" }
    return " " + remainder[comment...]
  }
}
