import Foundation

private struct Contract: Decodable {
  let schemaVersion: Int
  let generationID: String
  let themeID: String
  let appearance: String
  let semantic: Semantic
  let terminal: Terminal

  struct Semantic: Decodable {
    let background: String
    let surface: String
    let overlay: String
    let border: String
    let text: String
    let mutedText: String
    let accent: String
    let selection: String
    let info: String
    let success: String
    let warning: String
    let error: String

    enum CodingKeys: String, CodingKey {
      case background, surface, overlay, border, text, accent, selection
      case mutedText = "muted_text"
      case info, success, warning, error
    }
  }

  struct Terminal: Decodable {
    let foreground: String
    let background: String
    let cursor: String
    let selectionForeground: String
    let selectionBackground: String
    let ansi: [String]

    enum CodingKeys: String, CodingKey {
      case foreground, background, cursor, ansi
      case selectionForeground = "selection_foreground"
      case selectionBackground = "selection_background"
    }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case themeID = "theme_id"
    case appearance, semantic, terminal
  }

  var colors: [String] {
    [
      semantic.background, semantic.surface, semantic.overlay, semantic.border, semantic.text,
      semantic.mutedText, semantic.accent, semantic.selection, semantic.info, semantic.success,
      semantic.warning, semantic.error, terminal.foreground, terminal.background, terminal.cursor,
      terminal.selectionForeground, terminal.selectionBackground,
    ] + terminal.ansi
  }
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: theme-contract-consumer <theme.json>\n".utf8))
  exit(64)
}

do {
  let contract = try JSONDecoder().decode(
    Contract.self,
    from: Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
  )
  guard contract.schemaVersion == 1 else {
    throw ConsumerError.unsupportedSchema(contract.schemaVersion)
  }
  guard contract.appearance == "dark" || contract.appearance == "light" else {
    throw ConsumerError.invalidAppearance(contract.appearance)
  }
  guard contract.terminal.ansi.count == 16 else {
    throw ConsumerError.invalidANSICount(contract.terminal.ansi.count)
  }
  if let invalidColor = contract.colors.first(where: { !isColor($0) }) {
    throw ConsumerError.invalidColor(invalidColor)
  }
  print("valid theme \(contract.themeID) generation \(contract.generationID)")
} catch {
  FileHandle.standardError.write(Data("invalid theme contract: \(error)\n".utf8))
  exit(65)
}

private enum ConsumerError: Error {
  case unsupportedSchema(Int)
  case invalidAppearance(String)
  case invalidANSICount(Int)
  case invalidColor(String)
}

private func isColor(_ value: String) -> Bool {
  value.count == 7 && value.first == "#" && value == value.lowercased()
    && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
}
