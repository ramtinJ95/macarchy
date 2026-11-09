import AppKit

/// Where the theme browser puts its windows: a backdrop over every display and the picker
/// centered on the display with the pointer, or the first display when the pointer is on none.
struct ThemeBrowserDisplayLayout: Equatable, Sendable {
  struct Display: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
  }

  static let pickerSize = CGSize(width: 720, height: 640)
  /// The smallest gap the picker leaves to its display's visible edges.
  static let pickerMargin: CGFloat = 48

  let backdrops: [CGRect]
  let picker: CGRect
  /// The visible frame of the picker's display, where the status panel also appears.
  let pickerDisplay: CGRect

  /// Nil when no display is connected.
  init?(displays: [Display], pointer: CGPoint) {
    guard
      let display = displays.first(where: { NSMouseInRect(pointer, $0.frame, false) })
        ?? displays.first
    else { return nil }
    let visible = display.visibleFrame
    let width = min(Self.pickerSize.width, visible.width - 2 * Self.pickerMargin)
    let height = min(Self.pickerSize.height, visible.height - 2 * Self.pickerMargin)
    backdrops = displays.map(\.frame)
    pickerDisplay = visible
    picker = CGRect(
      x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
  }

  @MainActor
  static func current() -> Self? {
    Self(
      displays: NSScreen.screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) },
      pointer: NSEvent.mouseLocation)
  }
}

/// Window levels that put the browser above full-screen apps and the menu bar: backdrops, then
/// the picker and its status panel.
enum ThemeBrowserLevel {
  static let backdrop = NSWindow.Level.statusBar
  static let picker = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
  /// Every Space, including full-screen apps, without becoming part of window cycling.
  static let collectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
  ]
}

/// A panel that shows on every Space without activating Macarchy and never takes key focus.
@MainActor
private final class ThemeBrowserOverlayPanel: NSPanel {
  var onClick: (() -> Void)?

  init(frame: CGRect, level: NSWindow.Level) {
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    self.level = level
    collectionBehavior = ThemeBrowserLevel.collectionBehavior
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    hasShadow = false
    isOpaque = false
    backgroundColor = .clear
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }
}

/// The selected theme's background, blurred, over every display behind the picker. A click on
/// it dismisses the browser.
@MainActor
final class ThemeBrowserBackdrops {
  private var panels: [ThemeBrowserOverlayPanel] = []
  private var imageViews: [ThemeBrowserWallpaperImageView] = []
  private var image: NSImage?
  private var color: NSColor = .black
  var onClick: () -> Void = {}

  /// Replaces the panels with one per backdrop frame in `layout`.
  func show(_ layout: ThemeBrowserDisplayLayout) {
    close()
    for frame in layout.backdrops {
      let panel = ThemeBrowserOverlayPanel(frame: frame, level: ThemeBrowserLevel.backdrop)
      panel.onClick = { [weak self] in self?.onClick() }
      let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
      root.wantsLayer = true
      let imageView = ThemeBrowserWallpaperImageView(frame: root.bounds)
      imageView.autoresizingMask = [.width, .height]
      imageView.imageScaling = .scaleProportionallyUpOrDown
      let blur = NSVisualEffectView(frame: root.bounds)
      blur.autoresizingMask = [.width, .height]
      blur.blendingMode = .withinWindow
      blur.material = .fullScreenUI
      blur.state = .active
      root.addSubview(imageView)
      root.addSubview(blur)
      panel.contentView = root
      panels.append(panel)
      imageViews.append(imageView)
      panel.orderFrontRegardless()
    }
    apply()
  }

  /// Shows `image` blurred, or `color` when the theme has no background to show.
  func update(image: NSImage?, color: NSColor) {
    self.image = image
    self.color = color
    apply()
  }

  func close() {
    for panel in panels { panel.close() }
    panels = []
    imageViews = []
  }

  private func apply() {
    for (panel, imageView) in zip(panels, imageViews) {
      panel.contentView?.layer?.backgroundColor = color.cgColor
      imageView.image = image
    }
  }
}

/// A small panel that reports the browser's apply result and then closes itself.
@MainActor
final class ThemeBrowserStatusPanel: NSObject {
  static let successDelay: TimeInterval = 1.5
  static let failureDelay: TimeInterval = 6

  private let panel: ThemeBrowserOverlayPanel
  private let label = NSTextField(wrappingLabelWithString: "")
  private var completion: (() -> Void)?

  init(display: CGRect) {
    let size = CGSize(width: 360, height: 64)
    panel = ThemeBrowserOverlayPanel(
      frame: CGRect(
        x: display.midX - size.width / 2, y: display.midY - size.height / 2,
        width: size.width, height: size.height),
      level: ThemeBrowserLevel.picker)
    super.init()
    let root = NSView(frame: CGRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.cornerRadius = 12
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    panel.contentView = root
  }

  func show(_ message: String, text: NSColor, background: NSColor) {
    label.stringValue = message
    label.textColor = text
    panel.contentView?.layer?.backgroundColor = background.cgColor
    panel.orderFrontRegardless()
  }

  /// Shows `message`, then closes the panel and calls `completion` after `delay`. The browser's
  /// event loop runs inside a main-actor job, so a run-loop timer, not a task, does the waiting.
  func finish(
    _ message: String, text: NSColor, delay: TimeInterval, completion: @escaping () -> Void
  ) {
    label.stringValue = message
    label.textColor = text
    self.completion = completion
    Timer.scheduledTimer(
      timeInterval: delay, target: self, selector: #selector(expire(_:)), userInfo: nil,
      repeats: false)
  }

  func close() {
    panel.close()
  }

  @objc private func expire(_ timer: Timer) {
    panel.close()
    let completion = self.completion
    self.completion = nil
    completion?()
  }
}
