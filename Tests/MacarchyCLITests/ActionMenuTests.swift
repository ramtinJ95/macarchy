import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ActionMenuTests {
  @Test func eachOpeningLoadsTheCurrentCanonicalPalette() throws {
    let themes = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Themes")
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let file as URL in files {
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
      }
      try? FileManager.default.removeItem(at: root)
    }
    // Real generation/manifest publication, isolated from live consumers and
    // Darwin notifications. The popup must not cache the previous palette.
    let activator = ThemeActivator(root: root, faultInjector: { _ in })
    var accents: [SRGBColor] = []
    for id in ["catppuccin-mocha", "tokyo-night"] {
      let package = try ThemePackageLoader().load(packageURL: themes.appending(path: id))
      let manifest = try activator.activate(package: package)
      let theme = try loadPopupTheme(stateRoot: root, bundledThemesRoot: themes)
      #expect(theme.generationID == manifest.generationID)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let expected = NormalizedTheme(package: package, generationID: manifest.generationID)
      #expect(try encoder.encode(theme) == encoder.encode(expected))
      accents.append(theme.semantic.accent)
    }
    #expect(accents[0] != accents[1])
  }

  @MainActor
  @Test func vimKeysAreListOnlyAndSlashFocusesSearch() throws {
    let table = ActionMenuTable()
    var moves: [Int] = []
    var searches = 0
    var opens = 0
    table.moveSelection = { moves.append($0) }
    table.beginSearch = { searches += 1 }
    table.openSelection = { opens += 1 }
    for (character, keyCode) in [("j", 38), ("k", 40), ("/", 44), ("\r", 36)] {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(keyCode)))
      table.keyDown(with: event)
    }
    #expect(moves == [1, -1])
    #expect(searches == 1)
    #expect(opens == 1)

    // The search field gets a native text editor, not the list key handler.
    let editor = ActionMenuFieldEditor()
    editor.isFieldEditor = true
    editor.insertText("hjkl/", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.string == "hjkl/")
    #expect(moves == [1, -1])
    #expect(searches == 1)
  }

  @MainActor
  @Test func handoffWaitsForMenuAndCancellationDoesNotDispatch() async throws {
    var events: [String] = []
    try await ActionMenu.runSession(
      showMenu: {
        events.append("menu closed")
        return .appearance
      },
      openViewer: { action in events.append(action.rawValue) },
      showFailure: { _, _ in Issue.record("Unexpected launch failure") })
    #expect(events == ["menu closed", "appearance"])
    try await ActionMenu.runSession(
      showMenu: { nil },
      openViewer: { _ in Issue.record("Cancelled menu dispatched") },
      showFailure: { _, _ in Issue.record("Cancellation reported failure") })
  }

  @MainActor
  @Test func viewerFailureIsReportedAndPropagated() async throws {
    struct LaunchFailure: Error {}
    var reported = false
    do {
      try await ActionMenu.runSession(
        showMenu: { .keybindings },
        openViewer: { _ in throw LaunchFailure() },
        showFailure: { action, error in
          #expect(action == .keybindings)
          #expect(error is LaunchFailure)
          reported = true
        })
      Issue.record("Launch failure was swallowed")
    } catch is LaunchFailure {
      #expect(reported)
    }
  }

  @Test func searchSelectionAndEmptyDispatch() {
    var state = ActionMenuState()
    #expect(state.selectedAction == .appearance)
    state.move(by: 1)
    #expect(state.selectedAction == .keybindings)
    state.move(by: 1)
    #expect(state.selectedAction == .keybindings)
    state.move(by: -20)
    #expect(state.selectedAction == .appearance)
    state.search("  WALLPAPER colors ")
    #expect(state.actions == [.appearance])
    state.search("missing")
    #expect(state.selectedAction == nil)
    state.move(by: 1)
    #expect(state.selectedAction == nil)
    state.search("shortcuts")
    #expect(state.selectedAction == .keybindings)
    state.select(row: -1)
    #expect(state.selectedAction == nil)
    state.search("")
    #expect(state.actions == ActionMenuAction.allCases)
  }

  @Test func registeredCommandAndViewerRoutes() throws {
    #expect(try Macarchy.parseAsRoot(["menu"]) is ActionMenu)
    _ = try Theme.Browse.parse(Array(ActionMenuAction.appearance.arguments.dropFirst(2)))
    let viewer = try Keybindings.Show.parse(
      Array(ActionMenuAction.keybindings.arguments.dropFirst(2)))
    #expect(viewer.inspection.effective)
    #expect(ActionMenuAction.appearance.arguments == ["theme", "browse"])
  }

  @Test func curatedMenuShortcutPreservesViewersAndMetadata() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let state = KeybindingEffectiveStateInspector().inspect(
      resourcesRoot: root.appending(path: "Keybindings"),
      profileURL: temporary.appending(path: "profile.toml"), profileRequired: false,
      stateRoot: temporary)
    let bindings = state.presentedBindings
    let menu = try #require(bindings.first { $0.binding.command == "macarchy menu" })
    #expect(menu.binding.identity == "ctrl+alt-space")
    #expect(KeybindingsPopupRow(menu).category == "Macarchy")
    #expect(bindings.contains { $0.binding.command == "macarchy keybindings show --effective" })
    #expect(bindings.contains { $0.binding.command == "macarchy theme browse" })
  }
}
