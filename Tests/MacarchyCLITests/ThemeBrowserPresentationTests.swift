import Foundation
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserPresentationTests {
  private let left = ThemeBrowserDisplayLayout.Display(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
  private let right = ThemeBrowserDisplayLayout.Display(
    frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

  @Test func everyDisplayGetsABackdropAndThePointersDisplayGetsThePicker() throws {
    let layout = try #require(
      ThemeBrowserDisplayLayout(displays: [left, right], pointer: CGPoint(x: 2000, y: 500)))

    #expect(layout.backdrops == [left.frame, right.frame])
    #expect(layout.pickerDisplay == right.visibleFrame)
    #expect(
      layout.picker
        == CGRect(x: 1440 + (1920 - 720) / 2, y: (1055 - 640) / 2.0, width: 720, height: 640))
  }

  @Test func aRemovedDisplayLosesItsBackdropAndThePickerMoves() throws {
    let before = try #require(
      ThemeBrowserDisplayLayout(displays: [left, right], pointer: CGPoint(x: 2000, y: 500)))
    // The right display is unplugged; the pointer is now on no display.
    let after = try #require(
      ThemeBrowserDisplayLayout(displays: [left], pointer: CGPoint(x: 2000, y: 500)))

    #expect(before.backdrops.count == 2)
    #expect(after.backdrops == [left.frame])
    #expect(after.pickerDisplay == left.visibleFrame)
    #expect(left.visibleFrame.contains(after.picker))
    #expect(ThemeBrowserDisplayLayout(displays: [], pointer: .zero) == nil)
  }

  @Test func thePickerShrinksToFitASmallDisplay() throws {
    let small = ThemeBrowserDisplayLayout.Display(
      frame: CGRect(x: 0, y: 0, width: 640, height: 480),
      visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 455))

    let layout = try #require(
      ThemeBrowserDisplayLayout(displays: [small], pointer: CGPoint(x: 10, y: 10)))

    #expect(layout.picker.size == CGSize(width: 640 - 96, height: 455 - 96))
  }

  @Test func typingSelectsTheFirstMatchAndClearingKeepsTheSelection() throws {
    var state = ThemeBrowserState(content: try content())
    let all = state.visibleItems.map(\.id)
    state.selectTheme(id: "tokyo-night")

    state.filter("k")
    let kMatches = state.visibleItems.map(\.id)
    #expect(kMatches.count < all.count)
    #expect(state.selectedThemeID == kMatches.first)

    state.filter("kanagawa w")
    #expect(state.visibleItems.map(\.id) == ["kanagawa-wave"])
    #expect(state.selectedThemeID == "kanagawa-wave")

    state.filter("kanagawa")
    #expect(state.selectedThemeID == state.visibleItems.first?.id)

    state.selectTheme(id: "kanagawa-wave")
    state.filter("")
    #expect(state.visibleItems.map(\.id) == all)
    #expect(state.selectedThemeID == "kanagawa-wave")
  }

  private func content() throws -> ThemeBrowserContent {
    let packages = try ThemeRepository(builtInRoot: builtInThemes).packages()
    var loader = ThemeBrowserCommandLoader(
      loadMetadata: { _ in packages.map(\.metadata) },
      loadPreferences: { _ in [:] },
      loadActiveManifest: { _ in nil },
      loadPersonalBackgrounds: { _, _ in [:] },
      renderPreview: { ThemePreviewRenderer().render(metadata: $0) }
    )
    loader.loadFavorites = { _, _ in
      ThemeFavorites.Resolved(themeIDs: [], notices: [], readable: true)
    }
    return try loader.load(
      repository: ThemeRepository(builtInRoot: builtInThemes),
      stateRoot: URL(filePath: "/test/state", directoryHint: .isDirectory))
  }

  private var builtInThemes: URL {
    repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
  }
}
