import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ActionMenuThemeTests {
  private let themes = [
    ThemeMenuEntry(
      id: "kanagawa-wave", displayName: "Kanagawa Wave", appearance: .dark, isFavorite: true),
    ThemeMenuEntry(
      id: "tokyo-night", displayName: "Tokyo Night", appearance: .dark, isFavorite: false),
  ]

  @Test func withoutAQueryOnlyFavoritesFollowTheAppearanceActions() throws {
    let state = ActionMenuState(themes: themes)

    let favorite = try #require(state.actions.firstIndex { $0.theme != nil })
    #expect(state.actions.filter { $0.theme != nil }.map(\.title) == ["★ Kanagawa Wave"])
    #expect(state.actions[favorite - 1] == .keybindings)
    #expect(state.actions[favorite + 1].category != "Appearance")
    #expect(
      state.actions[favorite].command
        == .alertingViewer(["theme", "set", "kanagawa-wave"]))
  }

  @Test func aQuerySearchesEveryThemeByWordPrefix() {
    var state = ActionMenuState(themes: themes)

    state.search("tok ni")
    #expect(state.actions.map(\.title) == ["Tokyo Night"])
    #expect(state.selection == 0)

    state.search("dark")
    #expect(state.actions.compactMap(\.theme?.id) == ["kanagawa-wave", "tokyo-night"])

    state.search("okyo")
    #expect(state.actions.isEmpty)
    #expect(state.notice == "No matching actions")
  }

  @Test func actionsKeepTheirSubstringSearch() {
    var state = ActionMenuState(themes: themes)

    state.search("saver")

    #expect(state.actions.contains(.keepAwake))
    #expect(state.actions.allSatisfy { $0.theme == nil })
  }

  @Test func aFailedThemeListIsNamedInTheNotice() {
    struct Unreadable: Error, CustomStringConvertible {
      var description: String { "themes unreadable" }
    }

    let notice = ActionMenu.themeNotice(.failure(Unreadable()))
    let state = ActionMenuState(themes: [], themeNotice: notice)

    #expect(state.notice == "Themes are not listed: themes unreadable")
    #expect(ActionMenu.themeNotice(.success([])) == nil)
  }

  @Test func loadListsInstalledThemesWithFavoritesFirst() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-menu-themes-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try ThemeFavoritesStore(root: root).persist(["tokyo-night"])

    let entries = try ThemeMenuEntry.load(
      stateRoot: root, builtInThemes: repositoryRoot.appending(path: "Themes")
    ).get()

    #expect(entries.first?.id == "tokyo-night")
    #expect(entries.first?.isFavorite == true)
    #expect(entries.dropFirst().allSatisfy { !$0.isFavorite })
  }
}
