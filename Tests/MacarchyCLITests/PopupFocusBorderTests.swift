import AppKit
import Testing

@testable import MacarchyCLI

@MainActor
struct PopupFocusBorderTests {
  @Test func outlineDoesNotInterceptPopupControls() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 100, height: 32))
    root.addSubview(button)
    let border = PopupFocusBorder(accent: .systemBlue)
    border.frame = root.bounds
    root.addSubview(border, positioned: .above, relativeTo: nil)

    #expect(root.hitTest(NSPoint(x: 50, y: 30)) === button)
    #expect(root.hitTest(NSPoint(x: 150, y: 100)) === root)
  }
}
