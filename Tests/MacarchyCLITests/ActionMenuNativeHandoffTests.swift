import AppKit
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@MainActor
@Suite(.serialized)
struct ActionMenuNativeHandoffTests {
  // Run alone in a foreground desktop session: these production viewers exit
  // on focus loss. Require the Swift Testing completion summary, not just exit 0.
  // Async dispatch/error handling is covered separately in ActionMenuTests.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_ACTION_MENU_NATIVE"] == "1"),
    arguments: ActionMenuAction.allCases)
  func selectedViewerOpensAfterNativeMenuCloses(action: ActionMenuAction) throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: root.appending(path: "Themes/catppuccin-mocha"))
    let theme = NormalizedTheme(package: package, generationID: "native-menu-test")
    let controller = try ActionMenuWindowController(theme: theme)
    let driver = NativeMenuDriver(controller: controller, action: action)
    let select = driver.schedule(#selector(NativeMenuDriver.select), after: 0.3)
    let timeout = driver.schedule(#selector(NativeMenuDriver.timeout), after: 3)
    defer {
      select.invalidate()
      timeout.invalidate()
    }

    let selected = try #require(try controller.run())
    #expect(selected == action)
    #expect(controller.window?.isVisible == false)
    select.invalidate()
    timeout.invalidate()
    let observe = driver.schedule(#selector(NativeMenuDriver.observeViewer), after: 0.3)
    defer { observe.invalidate() }
    switch selected {
    case .keybindings:
      let viewer = try KeybindingsPopupWindowController(
        content: KeybindingsPopupContent(
          rows: [], theme: theme, heading: KeybindingsPopupWindowController.windowTitle,
          stateMessage: "Native handoff regression", rowDescription: "bindings",
          commandDescription: "command"))
      driver.viewer = viewer
      try viewer.run()
    case .appearance:
      let content = try ThemeBrowserCommandLoader.live.load(
        repository: ThemeRepository(builtInRoot: root.appending(path: "Themes")),
        stateRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
      let viewer = try ThemeBrowserWindowController(
        content: content,
        saveScreenSaverSelection: { _ in throw UnexpectedMutation() },
        deleteSelection: { _ in
          Issue.record("Unexpected deletion")
          return .failed("Mutation disabled in native handoff test")
        },
        reloadContent: { content },
        launchSelection: { _ in throw UnexpectedMutation() })
      driver.viewer = viewer
      try viewer.run()
    }
    #expect(driver.sawViewer)
  }

  private struct UnexpectedMutation: Error {}
}

@MainActor
private final class NativeMenuDriver: NSObject {
  let controller: ActionMenuWindowController
  let action: ActionMenuAction
  var viewer: NSWindowController?
  var sawViewer = false

  init(controller: ActionMenuWindowController, action: ActionMenuAction) {
    self.controller = controller
    self.action = action
  }

  func schedule(_ selector: Selector, after interval: TimeInterval) -> Timer {
    let timer = Timer(
      timeInterval: interval, target: self, selector: selector,
      userInfo: nil, repeats: false)
    RunLoop.main.add(timer, forMode: .default)
    return timer
  }

  @objc func select() {
    guard let window = controller.window else { return }
    if action == .keybindings { send("j", keyCode: 38, window: window) }
    send("\r", keyCode: 36, window: window)
  }

  private func send(_ text: String, keyCode: UInt16, window: NSWindow) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode)
    else {
      Issue.record("Could not create native selection event")
      return
    }
    NSApplication.shared.sendEvent(event)
  }

  @objc func timeout() {
    Issue.record("Menu did not return after selection")
    controller.window?.close()
  }

  @objc func observeViewer() {
    sawViewer = viewer?.window?.isVisible == true
    // Stop the test-owned viewer without its normal terminate-process behavior.
    // No Apply/delete action, global event injection or permission API is used.
    NSApplication.shared.delegate = controller
    if let browser = viewer as? ThemeBrowserWindowController {
      browser.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
    viewer?.window?.delegate = nil
    viewer?.window?.close()
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
  }
}
