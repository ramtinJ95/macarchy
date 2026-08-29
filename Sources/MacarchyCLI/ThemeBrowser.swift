import Foundation
import ThemeCore

private let themeBrowserSearchLocale = Locale(identifier: "en_US_POSIX")

struct ThemeBrowserPreview: Sendable {
  enum Kind: Sendable {
    case generated
    case imported
  }

  let kind: Kind
  let label: String
  let data: Data
}

struct ThemeBrowserItem: Sendable {
  let package: ThemePackage
  let generatedPreview: ThemeBrowserPreview
  let initialBackgroundID: String?

  var id: String { package.id }
  var displayName: String { package.displayName }
  var appearance: ThemeAppearance { package.appearance }
  var backgrounds: [ThemeBackground] { package.backgrounds }

  func backgroundData(id: String) -> Data? {
    guard let background = package.backgrounds.first(where: { $0.id == id }) else { return nil }
    return package.data(for: background)
  }

  fileprivate func matches(_ terms: [String]) -> Bool {
    guard !terms.isEmpty else { return true }
    let searchable = [package.id, package.displayName, package.appearance.rawValue]
      .joined(separator: "\n")
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: themeBrowserSearchLocale)
    return terms.allSatisfy(searchable.contains)
  }
}

struct ThemeBrowserContent: Sendable {
  let items: [ThemeBrowserItem]
  let initialThemeID: String

  func filteredItems(query: String) -> [ThemeBrowserItem] {
    let terms =
      query
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: themeBrowserSearchLocale
      )
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
    return items.filter { $0.matches(terms) }
  }

  func item(id: String) -> ThemeBrowserItem? {
    items.first { $0.id == id }
  }
}

struct ThemeBrowserSelection: Equatable, Sendable {
  let themeID: String
  let backgroundID: String?
}

struct ThemeBrowserState: Sendable {
  let content: ThemeBrowserContent
  private(set) var visibleItems: [ThemeBrowserItem]
  private(set) var selectedThemeID: String
  private var selectedBackgroundIDs: [String: String]

  init(content: ThemeBrowserContent) {
    self.content = content
    visibleItems = content.items
    selectedThemeID = content.initialThemeID
    selectedBackgroundIDs = Dictionary(
      uniqueKeysWithValues: content.items.compactMap { item in
        item.initialBackgroundID.map { (item.id, $0) }
      }
    )
  }

  var selection: ThemeBrowserSelection {
    ThemeBrowserSelection(
      themeID: selectedThemeID,
      backgroundID: selectedBackgroundIDs[selectedThemeID]
    )
  }

  mutating func updateSearch(_ query: String) {
    visibleItems = content.filteredItems(query: query)
    if !visibleItems.contains(where: { $0.id == selectedThemeID }), let first = visibleItems.first {
      selectedThemeID = first.id
    }
  }

  mutating func selectTheme(id: String) {
    guard content.item(id: id) != nil else { return }
    selectedThemeID = id
  }

  mutating func moveTheme(by offset: Int) {
    guard !visibleItems.isEmpty else { return }
    let current = visibleItems.firstIndex(where: { $0.id == selectedThemeID }) ?? 0
    let next = min(max(current + offset, 0), visibleItems.count - 1)
    selectedThemeID = visibleItems[next].id
  }

  mutating func selectBackground(id: String) {
    guard
      let item = content.item(id: selectedThemeID),
      item.backgrounds.contains(where: { $0.id == id })
    else { return }
    selectedBackgroundIDs[selectedThemeID] = id
  }

  mutating func moveBackground(by offset: Int) {
    guard let item = content.item(id: selectedThemeID), !item.backgrounds.isEmpty else { return }
    let currentID = selectedBackgroundIDs[selectedThemeID]
    let current = item.backgrounds.firstIndex(where: { $0.id == currentID }) ?? 0
    let next = (current + offset + item.backgrounds.count) % item.backgrounds.count
    selectedBackgroundIDs[selectedThemeID] = item.backgrounds[next].id
  }
}

enum ThemeBrowserError: Error, CustomStringConvertible, Sendable {
  case noThemes
  case cannotActivateAccessoryApplication
  case cannotRenderPreview(themeID: String)
  case noActiveDisplay

  var description: String {
    switch self {
    case .noThemes:
      "No valid themes are installed"
    case .cannotActivateAccessoryApplication:
      "Cannot run the theme browser as an accessory application"
    case .cannotRenderPreview(let themeID):
      "Cannot render the preview for theme '\(themeID)'"
    case .noActiveDisplay:
      "Cannot show the theme browser without an active display"
    }
  }
}

struct ThemeBrowserCommandLoader: Sendable {
  let loadPackages: @Sendable (ThemeRepository) throws -> [ThemePackage]
  let loadPreferences: @Sendable (URL) throws -> [String: String]
  let loadActiveManifest: @Sendable (URL) throws -> GenerationManifest?
  let renderPreview: @Sendable (ThemePackage) -> GeneratedThemePreview

  static let live = ThemeBrowserCommandLoader(
    loadPackages: { try $0.packages() },
    loadPreferences: { try BackgroundPreferenceStore(root: $0).load() },
    loadActiveManifest: { root in
      do {
        return try ReconciliationStatusStore(root: root).activeManifest()
      } catch ReconciliationStatusError.noActiveGeneration {
        return nil
      }
    },
    renderPreview: { ThemePreviewRenderer().render(package: $0) }
  )

  func load(repository: ThemeRepository, stateRoot: URL) throws -> ThemeBrowserContent {
    let packages = try loadPackages(repository)
    guard !packages.isEmpty else { throw ThemeBrowserError.noThemes }
    let preferences = try loadPreferences(stateRoot)
    let activeManifest = try loadActiveManifest(stateRoot)

    let items = packages.map { package in
      let activeBackgroundID =
        activeManifest?.themeID == package.id
        ? activeManifest?.background?.id
        : nil
      let preferredID = activeBackgroundID ?? preferences[package.id]
      let initialBackgroundID =
        package.backgrounds.first(where: { $0.id == preferredID })?.id
        ?? package.backgrounds.first?.id
      let preview = renderPreview(package)
      return ThemeBrowserItem(
        package: package,
        generatedPreview: ThemeBrowserPreview(
          kind: .generated,
          label: "Generated palette",
          data: preview.data
        ),
        initialBackgroundID: initialBackgroundID
      )
    }
    let packageIDs = Set(packages.map(\.id))
    let initialThemeID =
      activeManifest.map(\.themeID).flatMap { packageIDs.contains($0) ? $0 : nil }
      ?? packages[0].id
    return ThemeBrowserContent(items: items, initialThemeID: initialThemeID)
  }
}

struct ThemeBrowserGalleryLoader: Sendable {
  let loadAssets: @Sendable (ThemePackage) throws -> [ThemePreviewAsset]

  static let live = ThemeBrowserGalleryLoader(
    loadAssets: { try ImportedThemePreviewLoader().load(package: $0) }
  )

  func load(item: ThemeBrowserItem) throws -> [ThemeBrowserPreview] {
    try loadAssets(item.package).map { asset in
      ThemeBrowserPreview(
        kind: .imported,
        label: asset.sourcePath,
        data: asset.data
      )
    }
  }
}
