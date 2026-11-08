import AppKit
import ThemeCore

@MainActor
final class PopupFocusBorder: NSView {
  var accent: NSColor {
    didSet { updateFocus() }
  }

  init(accent: NSColor, width: CGFloat = CGFloat(BordersPalette.width)) {
    self.accent = accent
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = width
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func attach(to window: NSWindow) {
    guard let root = window.contentView else {
      preconditionFailure("Configure popup content before attaching its focus border")
    }
    frame = root.bounds
    autoresizingMask = [.width, .height]
    root.addSubview(self, positioned: .above, relativeTo: nil)
  }

  // The outline sits above the content but must never intercept its controls.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isOpaque: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let notifications = NotificationCenter.default
    notifications.removeObserver(self)
    if let window {
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
        notifications.addObserver(
          self, selector: #selector(focusChanged), name: name, object: window)
      }
    }
    updateFocus()
  }

  @objc private func focusChanged(_ notification: Notification) { updateFocus() }

  private func updateFocus() {
    layer?.borderColor = (window?.isKeyWindow == true ? accent : .clear).cgColor
  }

  deinit { NotificationCenter.default.removeObserver(self) }
}
