import AppKit

/// Reports a menu- or shortcut-launched command's outcome, which has no visible terminal.
@MainActor
func showNativeAlert(title: String, message: String, style: NSAlert.Style = .critical) {
  _ = runNativeAlert { alert in
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
  }
}

/// Lets a menu-launched command pick one of `choices`; nil when cancelled.
@MainActor
func showNativeChoice(title: String, message: String, choices: [String], selected: Int?) -> Int? {
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
    alert.addButton(withTitle: "Choose")
    alert.addButton(withTitle: "Cancel")
    alert.accessoryView = button
    popup = button
  }
  guard response == .alertFirstButtonReturn, let popup else { return nil }
  return popup.indexOfSelectedItem
}

@MainActor
private func runNativeAlert(_ configure: (NSAlert) -> Void) -> NSApplication.ModalResponse {
  let app = NSApplication.shared
  _ = app.setActivationPolicy(.accessory)
  app.finishLaunching()
  let alert = NSAlert()
  configure(alert)
  app.activate(ignoringOtherApps: true)
  return alert.runModal()
}
