import AppKit
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@MainActor
@Suite(.serialized)
struct ActionMenuNativeHandoffTests {
  // Run alone in a foreground desktop session. This proves native selection,
  // close-before-launch and real process creation, not the child viewer's UI.
  // That final CLI journey still requires the supported-machine acceptance check.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_ACTION_MENU_NATIVE"] == "1"),
    arguments: ActionMenuAction.allCases)
  func nativeMenuClosesBeforeLaunchingStandaloneCommand(action: ActionMenuAction) throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: root.appending(path: "Themes/catppuccin-mocha"))
    let theme = NormalizedTheme(package: package, generationID: "native-menu-test")
    let controller = try ActionMenuWindowController(theme: theme)
    let driver = NativeMenuDriver(window: try #require(controller.window), action: action)
    let select = Timer.scheduledTimer(
      timeInterval: 0.3, target: driver, selector: #selector(NativeMenuDriver.select),
      userInfo: nil, repeats: false)
    let timeout = Timer.scheduledTimer(
      timeInterval: 5, target: driver, selector: #selector(NativeMenuDriver.timeout),
      userInfo: nil, repeats: false)
    defer {
      select.invalidate()
      timeout.invalidate()
    }
    var launched = false
    try ActionMenu.runSession(
      showMenu: { try controller.run() },
      openViewer: { selected in
        #expect(selected == action)
        #expect(controller.window?.isVisible == false)
        let process = try ActionMenu.launchViewer(
          selected, executableURL: URL(filePath: "/usr/bin/true"))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        launched = true
      },
      showFailure: { _, error in Issue.record("Native handoff failed: \(error)") })
    #expect(launched)
  }
}

@MainActor
private final class NativeMenuDriver: NSObject {
  let window: NSWindow
  let action: ActionMenuAction

  init(window: NSWindow, action: ActionMenuAction) {
    self.window = window
    self.action = action
  }

  @objc func select() {
    guard window.isVisible else {
      Issue.record("Menu did not open")
      return
    }
    if action == .keybindings { send("j", keyCode: 38) }
    send("\r", keyCode: 36)
  }

  private func send(_ text: String, keyCode: UInt16) {
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
    window.close()
  }
}
