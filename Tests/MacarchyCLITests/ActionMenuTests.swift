import AppKit
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
  @Test func cancellationDoesNotLaunchOrReportFailure() throws {
    try ActionMenu.runSession(
      showMenu: { nil },
      openViewer: { _ in Issue.record("Cancelled menu dispatched") },
      showFailure: { _, _ in Issue.record("Cancellation reported failure") })
  }

  @Test(arguments: [
    (ActionMenuAction.appearance, ["theme", "browse"]),
    (.keybindings, ["keybindings", "show", "--effective"]),
  ])
  func launchUsesExactExecutableAndShortcutArguments(
    action: ActionMenuAction, arguments: [String]
  ) throws {
    let executable = URL(filePath: "/usr/bin/true")
    let process = try ActionMenu.launchViewer(action, executableURL: executable)
    #expect(process.executableURL == executable)
    #expect(process.arguments == arguments)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @MainActor
  @Test func missingExecutableReportsRealLaunchFailure() throws {
    let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var reportedError: NSError?
    do {
      try ActionMenu.runSession(
        showMenu: { .appearance },
        openViewer: { _ = try ActionMenu.launchViewer($0, executableURL: missing) },
        showFailure: { action, error in
          #expect(action == .appearance)
          reportedError = error as NSError
        })
      Issue.record("Launch failure was swallowed")
    } catch {
      let reported = try #require(reportedError)
      #expect((error as NSError) == reported)
    }
  }

  @Test func searchSelectionAndEmptyDispatch() {
    var state = ActionMenuState()
    #expect(state.selectedAction == .profile(.portable))
    state.move(by: 1)
    #expect(state.selectedAction == .profile(.machine))
    state.move(by: 1)
    #expect(state.selectedAction == .profile(.keybindings))
    state.move(by: -20)
    #expect(state.selectedAction == .profile(.portable))
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
