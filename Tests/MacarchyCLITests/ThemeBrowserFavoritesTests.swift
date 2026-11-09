import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserFavoritesTests {
  @Test func loaderListsFavoritesFirstAndReportsPrunedFavorites() throws {
    let packages = try ThemeRepository(builtInRoot: themesRoot).packages()
    var loader = ThemeBrowserCommandLoader(
      loadMetadata: { _ in packages.map(\.metadata) },
      loadPreferences: { _ in [:] },
      loadActiveManifest: { _ in nil },
      loadPersonalBackgrounds: { _, _ in [:] },
      renderPreview: { ThemePreviewRenderer().render(metadata: $0) }
    )
    loader.loadFavorites = { _, installed in
      #expect(installed == Set(packages.map(\.id)))
      return ThemeFavorites.Resolved(
        themeIDs: ["tokyo-night", "kanagawa-wave"],
        notices: ["Removed favorite 'gone', which is no longer installed."],
        readable: true)
    }

    let content = try loader.load(
      repository: ThemeRepository(builtInRoot: themesRoot),
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory))

    let repositoryOrder = packages.map(\.id)
    let favorites = repositoryOrder.filter { ["tokyo-night", "kanagawa-wave"].contains($0) }
    #expect(Array(content.items.map(\.id).prefix(2)) == favorites)
    #expect(content.items.map(\.id).count == packages.count)
    #expect(content.items.filter(\.isFavorite).map(\.id) == favorites)
    #expect(content.initialThemeID == favorites[0])
    #expect(content.notices == ["Removed favorite 'gone', which is no longer installed."])
  }

  private var themesRoot: URL {
    repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
  }
}
