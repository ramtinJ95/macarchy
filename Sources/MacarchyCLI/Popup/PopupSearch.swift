import Foundation

/// A popup's search field: case- and diacritic-insensitive terms, each of which a match contains.
enum PopupSearch {
  private static let locale = Locale(identifier: "en_US_POSIX")

  static func terms(_ query: String) -> [String] {
    fold(query)
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
  }

  /// Whether `fields` contain every term; an empty query matches everything.
  static func matches(_ terms: [String], fields: [String]) -> Bool {
    guard !terms.isEmpty else { return true }
    let searchable = fold(fields.joined(separator: "\n"))
    return terms.allSatisfy(searchable.contains)
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
  }
}
