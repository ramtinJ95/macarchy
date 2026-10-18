import AppKit
import UniformTypeIdentifiers

/// Reports a menu- or shortcut-launched command's outcome, which has no visible terminal.
@MainActor
func showNativeAlert(title: String, message: String, style: NSAlert.Style = .critical) {
  _ = runNativeAlert { alert in
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
  }
}

/// Lets a menu-launched command pick one of `choices` and press one of `actions`, the buttons
/// before Cancel; nil when cancelled.
@MainActor
func showNativeChoice(
  title: String, message: String, choices: [String], selected: Int?,
  actions: [String] = ["Choose"]
) -> (choice: Int, action: Int)? {
  var popup: NSPopUpButton?
  let response = runNativeAlert { alert in
    let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
    // NSPopUpButton.addItem(withTitle:) drops an earlier item with the same title; inputs may
    // share a name, so the menu takes every item.
    for choice in choices {
      button.menu?.addItem(withTitle: choice, action: nil, keyEquivalent: "")
    }
    if let selected { button.selectItem(at: selected) }
    alert.messageText = title
    alert.informativeText = message
    for action in actions { alert.addButton(withTitle: action) }
    alert.addButton(withTitle: "Cancel")
    alert.accessoryView = button
    popup = button
  }
  let action = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
  guard actions.indices.contains(action), let popup else { return nil }
  return (popup.indexOfSelectedItem, action)
}

/// Lets a menu-launched command pick one file of `types`; nil when cancelled.
@MainActor
func showNativeOpenPanel(message: String, types: [UTType]) -> URL? {
  launchNativeApp()
  let panel = NSOpenPanel()
  panel.message = message
  panel.allowedContentTypes = types
  panel.canChooseFiles = true
  panel.canChooseDirectories = false
  panel.allowsMultipleSelection = false
  NSApplication.shared.activate(ignoringOtherApps: true)
  return panel.runModal() == .OK ? panel.url : nil
}

@MainActor
private func runNativeAlert(_ configure: (NSAlert) -> Void) -> NSApplication.ModalResponse {
  launchNativeApp()
  let alert = NSAlert()
  configure(alert)
  NSApplication.shared.activate(ignoringOtherApps: true)
  return alert.runModal()
}

@MainActor
private func launchNativeApp() {
  let app = NSApplication.shared
  _ = app.setActivationPolicy(.accessory)
  app.finishLaunching()
}
