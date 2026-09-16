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
    let driver = NativeMenuDriver(action: action)
    let select = driver.schedule(#selector(NativeMenuDriver.select), after: 0.3)
    let timeout = driver.schedule(#selector(NativeMenuDriver.timeout), after: 5)
    defer {
      select.invalidate()
      timeout.invalidate()
    }
    let root = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let package = try ThemePackageLoader().load(
      packageURL: root.appending(path: "Themes/catppuccin-mocha"))
    let theme = NormalizedTheme(package: package, generationID: "native-menu-test")
    let controller = try ActionMenuWindowController(theme: theme)
    var launched = false
    try ActionMenu.runSession(
      showMenu: { try controller.run() },
      openViewer: { selected in
        #expect(selected == action)
        #expect(controller.window?.isVisible == false)
        let process = try ActionMenu.launchViewer(
          selected, executableURL: URL(filePath: "/usr/bin/true"))
        #expect(process.arguments == action.arguments)
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
  let action: ActionMenuAction

  init(action: ActionMenuAction) {
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
    guard
      let window = NSApplication.shared.windows.first(where: {
        $0.title == ActionMenuWindowController.windowTitle && $0.isVisible
      })
    else {
      Issue.record("Menu did not open")
      return
    }
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
    NSApplication.shared.windows.first {
      $0.title == ActionMenuWindowController.windowTitle && $0.isVisible
    }?.close()
  }
}
