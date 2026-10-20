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
  @Test func editShortcutsReachTheStandardEditingActions() throws {
    // Menu items dispatch through NSApp, which stays nil until the shared application exists.
    _ = NSApplication.shared
    let menu = popupMainMenu()
    // The popup targets the responder chain. Retargeting only observes dispatch.
    let recorder = EditActionRecorder()
    for item in menu.items.flatMap({ $0.submenu?.items ?? [] }) { item.target = recorder }
    func key(_ text: String, _ modifiers: NSEvent.ModifierFlags, _ code: UInt16) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: text,
          charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    for event in try [
      key("a", .command, 0), key("c", .command, 8), key("v", .command, 9),
      key("x", .command, 7), key("z", .command, 6), key("Z", [.command, .shift], 6),
    ] {
      #expect(menu.performKeyEquivalent(with: event))
    }
    #expect(recorder.received == ["selectAll:", "copy:", "paste:", "cut:", "undo:", "redo:"])
    let plainText = try key("a", [], 0)
    #expect(!menu.performKeyEquivalent(with: plainText))

    let editor = ActionMenuFieldEditor()
    editor.isFieldEditor = true
    editor.string = "old query"
    editor.setSelectedRange(NSRange(location: 9, length: 0))
    #expect(
      NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: editor, from: nil))
    #expect(editor.selectedRange() == NSRange(location: 0, length: 9))
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
    (.screenshot, ["capture", "screenshot", "--alert-on-error"]),
    (.annotate, ["capture", "annotate", "--alert-on-error"]),
    (.ocr, ["capture", "ocr", "--alert-on-error"]),
    (.prepareImage, ["image", "choose", "--alert-on-error"]),
    (.clipboardHistory, ["clipboard", "open", "--alert-on-error"]),
    (.clearClipboardHistory, ["clipboard", "clear", "--confirm", "--alert-on-error"]),
    (.keepAwake, ["keep-awake", "toggle", "--alert-on-error"]),
    (.startScreensaver, ["saver", "start", "--alert-on-error"]),
    (.toggleIdleScreensaver, ["saver", "idle", "toggle", "--alert-on-error"]),
    (.toggleScreensaverPause, ["saver", "toggle-pause", "--alert-on-error"]),
    (.chooseMicrophone, ["mic", "choose", "--alert-on-error"]),
    (.toggleMicrophone, ["mic", "toggle", "--alert-on-error"]),
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

  @Test func searchSelectionAndEmptyDispatch() throws {
    var state = ActionMenuState()
    #expect(state.notice == "Configure · Appearance · Capture · Clipboard · Controls · Maintenance")
    #expect(state.selectedAction == .profile(.portable))
    state.move(by: 1)
    #expect(state.selectedAction == .profile(.machine))
    state.move(by: 1)
    #expect(state.selectedAction == .profile(.keybindings))
    state.move(by: -20)
    #expect(state.selectedAction == .profile(.portable))
    state.search("  WALLPAPER colors ")
    #expect(state.actions == [.appearance])
    #expect(state.notice == "Configure · Appearance · Capture · Clipboard · Controls · Maintenance")
    state.search("missing")
    #expect(state.selectedAction == nil)
    #expect(state.notice == "No matching actions")
    state.move(by: 1)
    #expect(state.selectedAction == nil)
    state.search("shortcuts")
    #expect(state.selectedAction == .keybindings)
    state.search("capture region")
    #expect(state.selectedAction == .screenshot)
    #expect(state.actions == [.screenshot, .ocr])
    state.search("OCR")
    #expect(state.actions == [.ocr])
    state.search("flameshot annotation")
    #expect(state.actions == [.annotate])
    for query in ["prepare image", "compress", "jpeg", "strip metadata", "resize png"] {
      state.search(query)
      #expect(state.actions == [.prepareImage], Comment(rawValue: query))
    }
    state.search("capture image")
    #expect(state.actions == [.screenshot, .prepareImage])
    #expect(ActionMenuAction.prepareImage.category == "Capture")
    #expect(ActionMenuAction.prepareImage.title == "Prepare an image")
    let ocr = try #require(ActionMenuAction.allCases.firstIndex(of: .ocr))
    #expect(ActionMenuAction.allCases[ocr + 1] == .prepareImage)
    for query in ["clipboard history", "maccy", "paste", "copy"] {
      state.search(query)
      #expect(
        state.actions == [.clipboardHistory, .clearClipboardHistory], Comment(rawValue: query))
    }
    for query in ["clear", "wipe", "secret", "password"] {
      state.search(query)
      #expect(state.actions == [.clearClipboardHistory], Comment(rawValue: query))
    }
    #expect(ActionMenuAction.clipboardHistory.category == "Clipboard")
    #expect(ActionMenuAction.clearClipboardHistory.category == "Clipboard")
    #expect(ActionMenuAction.clipboardHistory.title == "Clipboard history")
    #expect(ActionMenuAction.clearClipboardHistory.title == "Clear clipboard history")
    #expect(
      Array(ActionMenuAction.allCases[(ocr + 1)...(ocr + 3)])
        == [.prepareImage, .clipboardHistory, .clearClipboardHistory])
    for query in ["keep awake", "caffeinate", "always on"] {
      state.search(query)
      #expect(state.actions == [.keepAwake], Comment(rawValue: query))
    }
    state.search("idle lock")
    #expect(state.actions == [.keepAwake, .toggleScreensaverPause])
    #expect(ActionMenuAction.keepAwake.category == "Controls")
    #expect(ActionMenuAction.keepAwake.title == "Toggle keep-awake")
    for query in ["screensaver", "saver", "idle"] {
      state.search(query)
      #expect(
        state.actions == [
          .keepAwake, .startScreensaver, .toggleIdleScreensaver, .toggleScreensaverPause,
        ],
        Comment(rawValue: query))
    }
    for query in ["start screensaver", "ttfx", "animation"] {
      state.search(query)
      #expect(state.actions == [.startScreensaver], Comment(rawValue: query))
    }
    state.search("away")
    #expect(
      state.actions == [.startScreensaver, .toggleIdleScreensaver, .toggleScreensaverPause])
    for query in ["activation", "idle timeout"] {
      state.search(query)
      #expect(state.actions == [.toggleIdleScreensaver], Comment(rawValue: query))
    }
    for query in ["pause", "resume", "screensaver pause", "away lock"] {
      state.search(query)
      #expect(state.actions == [.toggleScreensaverPause], Comment(rawValue: query))
    }
    #expect(ActionMenuAction.startScreensaver.category == "Controls")
    #expect(ActionMenuAction.startScreensaver.title == "Start screensaver")
    #expect(ActionMenuAction.toggleScreensaverPause.category == "Controls")
    #expect(ActionMenuAction.toggleScreensaverPause.title == "Toggle screensaver pause")
    #expect(ActionMenuAction.toggleIdleScreensaver.category == "Controls")
    #expect(ActionMenuAction.toggleIdleScreensaver.title == "Toggle idle screensaver")
    let keepAwake = try #require(ActionMenuAction.allCases.firstIndex(of: .keepAwake))
    #expect(
      Array(ActionMenuAction.allCases[(keepAwake + 1)...(keepAwake + 3)])
        == [.startScreensaver, .toggleIdleScreensaver, .toggleScreensaverPause])
    for query in ["choose microphone", "input device", "select mic"] {
      state.search(query)
      #expect(state.actions == [.chooseMicrophone], Comment(rawValue: query))
    }
    for query in ["mute", "unmute", "microphone privacy"] {
      state.search(query)
      #expect(state.actions == [.toggleMicrophone], Comment(rawValue: query))
    }
    state.search("microphone")
    #expect(state.actions == [.chooseMicrophone, .toggleMicrophone])
    #expect(ActionMenuAction.chooseMicrophone.category == "Controls")
    #expect(ActionMenuAction.toggleMicrophone.category == "Controls")
    #expect(ActionMenuAction.chooseMicrophone.title == "Choose microphone")
    #expect(ActionMenuAction.toggleMicrophone.title == "Toggle microphone mute")
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
    let capture = try #require(bindings.first { $0.binding.identity == "ctrl+alt-c" })
    #expect(capture.binding.command == "macarchy capture screenshot --alert-on-error")
    #expect(KeybindingsPopupRow(capture).category == "Capture")
    let annotate = try #require(bindings.first { $0.binding.identity == "ctrl+alt+shift-c" })
    #expect(annotate.binding.command == "macarchy capture annotate --alert-on-error")
    #expect(KeybindingsPopupRow(annotate).category == "Capture")
  }
}

@MainActor
private final class EditActionRecorder: NSObject {
  private(set) var received: [String] = []
  @objc func undo(_ sender: Any?) { received.append("undo:") }
  @objc func redo(_ sender: Any?) { received.append("redo:") }
  @objc func cut(_ sender: Any?) { received.append("cut:") }
  @objc func copy(_ sender: Any?) { received.append("copy:") }
  @objc func paste(_ sender: Any?) { received.append("paste:") }
  @objc func selectAll(_ sender: Any?) { received.append("selectAll:") }
}
