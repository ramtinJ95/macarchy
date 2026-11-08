import AppKit

/// Shows `controller`'s window as the key window of an accessory application, which has no Dock
/// icon, and runs the application until it stops.
@MainActor
func runAccessoryPopup(
  _ controller: NSWindowController & NSApplicationDelegate,
  focusing firstResponder: NSResponder,
  cannotActivate: any Error
) throws {
  let application = NSApplication.shared
  guard
    application.activationPolicy() == .accessory
      || application.setActivationPolicy(.accessory)
  else {
    throw cannotActivate
  }
  application.mainMenu = popupMainMenu()
  application.delegate = controller
  application.finishLaunching()
  controller.showWindow(nil)
  application.activate(ignoringOtherApps: true)
  controller.window?.makeKeyAndOrderFront(nil)
  controller.window?.makeFirstResponder(firstResponder)
  application.run()
}

/// The screen under the pointer, where a popup opens.
@MainActor
func popupActiveScreen() -> NSScreen? {
  let pointer = NSEvent.mouseLocation
  return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
}
