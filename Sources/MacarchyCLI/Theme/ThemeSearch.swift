import ThemeCore

/// Theme search in `theme list --search`, the theme browser and the action menu: every query
/// word must start a word of the theme's name, identifier or appearance, ignoring case and
/// accents. Words are split at anything that is not a letter or digit, so "tok ni" finds
/// "tokyo-night" and "rose" finds "Rosé Pine".
struct ThemeSearch: Sendable {
  private let words: [String]

  init(_ query: String) {
    words = Self.words(query)
  }

  var isEmpty: Bool { words.isEmpty }

  func matches(id: String, displayName: String, appearance: ThemeAppearance) -> Bool {
    guard !words.isEmpty else { return true }
    let themeWords = [id, displayName, appearance.rawValue].flatMap(Self.words)
    return words.allSatisfy { word in themeWords.contains { $0.hasPrefix(word) } }
  }

  private static func words(_ text: String) -> [String] {
    PopupSearch.fold(text)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }
}

/// Theme lists show favorites first; each group keeps the order it was given.
func favoritesFirst<Item>(
  _ items: [Item], favorites: Set<String>, id: (Item) -> String
) -> [Item] {
  items.filter { favorites.contains(id($0)) } + items.filter { !favorites.contains(id($0)) }
}
