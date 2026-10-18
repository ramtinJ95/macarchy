import AppKit

/// Reports a menu- or shortcut-launched command's outcome, which has no visible terminal.
@MainActor
func showNativeAlert(title: String, message: String, style: NSAlert.Style = .critical) {
  let app = NSApplication.shared
  _ = app.setActivationPolicy(.accessory)
  app.finishLaunching()
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = message
  alert.alertStyle = style
  app.activate(ignoringOtherApps: true)
  alert.runModal()
}
