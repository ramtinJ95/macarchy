import AppKit

@MainActor
final class PopupTableRowView: NSTableRowView {
  private let normalTextColor: NSColor
  private let selectedTextColor: NSColor
  private let selectedBackgroundColor: NSColor

  init(normalTextColor: NSColor, selectedTextColor: NSColor, selectedBackgroundColor: NSColor) {
    self.normalTextColor = normalTextColor
    self.selectedTextColor = selectedTextColor
    self.selectedBackgroundColor = selectedBackgroundColor
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override var isSelected: Bool {
    didSet { updateTextColors() }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    selectedBackgroundColor.setFill()
    dirtyRect.fill()
  }

  private func updateTextColors() {
    let color = isSelected ? selectedTextColor : normalTextColor
    for case let cell as NSTableCellView in subviews {
      cell.textField?.textColor = color
    }
  }
}
