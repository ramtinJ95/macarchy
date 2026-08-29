import AppKit
import Foundation
import ImageIO
import Synchronization
import ThemeCore

@MainActor
private final class ThemeBrowserWindow: NSWindow {
  enum Navigation {
    case nextBackground
    case nextPreview
    case previousBackground
    case previousPreview
  }

  var navigate: ((Navigation) -> Void)?

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  override func sendEvent(_ event: NSEvent) {
    guard event.type == .keyDown else {
      super.sendEvent(event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let direction = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
    if direction != 0, modifiers.contains(.shift),
      modifiers.isDisjoint(with: [.command, .control, .option])
    {
      navigate?(direction < 0 ? .previousPreview : .nextPreview)
      return
    }
    if direction != 0, modifiers.isDisjoint(with: [.command, .control, .option]) {
      navigate?(direction < 0 ? .previousBackground : .nextBackground)
      return
    }
    super.sendEvent(event)
  }
}

@MainActor
private final class ThemeBrowserTableRowView: NSTableRowView {
  private var normalTextColor: NSColor
  private var selectedTextColor: NSColor
  private var selectedBackgroundColor: NSColor

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
    didSet {
      updateTextColor()
    }
  }

  func updatePalette(
    normalTextColor: NSColor,
    selectedTextColor: NSColor,
    selectedBackgroundColor: NSColor
  ) {
    self.normalTextColor = normalTextColor
    self.selectedTextColor = selectedTextColor
    self.selectedBackgroundColor = selectedBackgroundColor
    updateTextColor()
    needsDisplay = true
  }

  override func drawSelection(in dirtyRect: NSRect) {
    selectedBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
  }

  private func updateTextColor() {
    for case let cell as NSTableCellView in subviews {
      cell.textField?.textColor = isSelected ? selectedTextColor : normalTextColor
    }
  }
}

@MainActor
private final class ThemeBrowserWallpaperImageView: NSImageView {
  override func draw(_ dirtyRect: NSRect) {
    guard let image else {
      super.draw(dirtyRect)
      return
    }
    let imageAspect = image.size.width / image.size.height
    let boundsAspect = bounds.width / bounds.height
    let sourceRect: NSRect
    if imageAspect > boundsAspect {
      let width = image.size.height * boundsAspect
      sourceRect = NSRect(
        x: (image.size.width - width) / 2,
        y: 0,
        width: width,
        height: image.size.height
      )
    } else {
      let height = image.size.width / boundsAspect
      sourceRect = NSRect(
        x: 0,
        y: (image.size.height - height) / 2,
        width: image.size.width,
        height: height
      )
    }
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
      in: bounds,
      from: sourceRect,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: nil
    )
  }
}

private enum ThemeBrowserGalleryOutcome: Sendable {
  case loaded([ThemeBrowserPreview])
  case failed(String)
}

enum ThemeBrowserImageDecoder {
  static func thumbnail(data: Data, maximumPixelSize: Int) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      maximumPixelSize > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

private enum ThemeBrowserImageOutcome: Sendable {
  case failed
  case loaded(CGImage)
}

private struct ThemeBrowserBackgroundImageKey {
  let themeID: String
  let backgroundID: String

  var cacheKey: NSString {
    "\(themeID)\u{0}\(backgroundID)" as NSString
  }
}

private final class ThemeBrowserAsyncResult<Value: Sendable>: Sendable {
  private let storage = Mutex<Value?>(nil)

  func complete(_ value: Value) {
    storage.withLock { $0 = value }
  }

  func value() -> Value? {
    storage.withLock { $0 }
  }
}

@MainActor
final class ThemeBrowserWindowController: NSWindowController, NSApplicationDelegate,
  NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate
{
  static let windowTitle = "Macarchy Themes"

  private let content: ThemeBrowserContent
  private let galleryLoader: ThemeBrowserGalleryLoader
  private let launchSelection:
    (ThemeBrowserSelection) throws -> ThemeBrowserApplyProcessLauncher.RunningProcess

  private var browserState: ThemeBrowserState
  private var previews: [ThemeBrowserPreview] = []
  private var previewIndex = 0
  private var galleryTask: Task<Void, Never>?
  private var galleryResult: ThemeBrowserAsyncResult<ThemeBrowserGalleryOutcome>?
  private var galleryTimer: Timer?
  private var galleryThemeID: String?
  private var backgroundImageTask: Task<Void, Never>?
  private var backgroundImageResult: ThemeBrowserAsyncResult<ThemeBrowserImageOutcome>?
  private var backgroundImageTimer: Timer?
  private var backgroundImageKey: ThemeBrowserBackgroundImageKey?
  private let backgroundImageCache = NSCache<NSString, NSImage>()
  private var applyProcess: ThemeBrowserApplyProcessLauncher.RunningProcess?
  private var applyTimer: Timer?
  private var isApplying = false

  private let rootView = NSView()
  private let sidebar = NSStackView()
  private let searchField = NSSearchField()
  private let countLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let themeScrollView = NSScrollView()
  private let themeNameLabel = NSTextField(labelWithString: "")
  private let previewImageView = NSImageView()
  private let previewLabel = NSTextField(labelWithString: "")
  private let previousPreviewButton = NSButton(title: "Previous", target: nil, action: nil)
  private let nextPreviewButton = NSButton(title: "Next", target: nil, action: nil)
  private let backgroundImageView = ThemeBrowserWallpaperImageView()
  private let backgroundLabel = NSTextField(labelWithString: "")
  private let backgroundPicker = NSPopUpButton()
  private let previousBackgroundButton = NSButton(title: "Previous", target: nil, action: nil)
  private let nextBackgroundButton = NSButton(title: "Next", target: nil, action: nil)
  private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let keyboardHelp = NSTextField(
    labelWithString: "↑↓ theme   ←→ wallpaper   ⇧←→ preview   ↩ apply   esc close"
  )

  init(
    content: ThemeBrowserContent,
    galleryLoader: ThemeBrowserGalleryLoader = .live,
    launchSelection:
      @escaping (ThemeBrowserSelection) throws -> ThemeBrowserApplyProcessLauncher.RunningProcess
  ) throws {
    self.content = content
    self.galleryLoader = galleryLoader
    self.launchSelection = launchSelection
    browserState = ThemeBrowserState(content: content)
    backgroundImageCache.countLimit = 24
    backgroundImageCache.totalCostLimit = 96 * 1_024 * 1_024

    guard let visibleFrame = Self.activeScreen()?.visibleFrame else {
      throw ThemeBrowserError.noActiveDisplay
    }
    let width = min(720, visibleFrame.width - 96)
    let height = min(640, visibleFrame.height - 96)
    let frame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height
    )
    let window = ThemeBrowserWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = Self.windowTitle
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    super.init(window: window)
    window.delegate = self
    window.navigate = { [weak self] navigation in
      switch navigation {
      case .previousBackground:
        self?.moveBackground(by: -1)
      case .nextBackground:
        self?.moveBackground(by: 1)
      case .previousPreview:
        self?.movePreview(by: -1)
      case .nextPreview:
        self?.movePreview(by: 1)
      }
    }
    configureContent(in: window)
    if let initialRow = browserState.visibleItems.firstIndex(where: {
      $0.id == browserState.selectedThemeID
    }) {
      selectVisibleRow(initialRow)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func run() throws {
    let application = NSApplication.shared
    guard application.setActivationPolicy(.accessory) else {
      throw ThemeBrowserError.cannotActivateAccessoryApplication
    }
    application.delegate = self
    application.finishLaunching()
    showWindow(nil)
    application.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(searchField)
    application.run()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func windowDidResignKey(_ notification: Notification) {
    if !isApplying { window?.close() }
  }

  func windowWillClose(_ notification: Notification) {
    galleryTask?.cancel()
    galleryTimer?.invalidate()
    backgroundImageTask?.cancel()
    backgroundImageTimer?.invalidate()
    applyTimer?.invalidate()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    browserState.visibleItems.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    let item = browserState.visibleItems[row]
    let identifier = NSUserInterfaceItemIdentifier("theme-cell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeThemeCell(identifier: identifier)
    cell.textField?.stringValue = item.displayName
    cell.textField?.toolTip = "\(item.id) · \(item.appearance.rawValue)"
    if let selectedItem {
      cell.textField?.textColor =
        row == tableView.selectedRow
        ? selectedItem.package.terminal.selectionForeground.nsColor
        : selectedItem.package.semantic.text.nsColor
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    guard let selectedItem else { return nil }
    return ThemeBrowserTableRowView(
      normalTextColor: selectedItem.package.semantic.text.nsColor,
      selectedTextColor: selectedItem.package.terminal.selectionForeground.nsColor,
      selectedBackgroundColor: selectedItem.package.terminal.selectionBackground.nsColor
    )
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard browserState.visibleItems.indices.contains(tableView.selectedRow) else { return }
    selectTheme(id: browserState.visibleItems[tableView.selectedRow].id)
  }

  func controlTextDidChange(_ notification: Notification) {
    browserState.updateSearch(searchField.stringValue)
    tableView.reloadData()
    if let selectedIndex = browserState.visibleItems.firstIndex(where: {
      $0.id == browserState.selectedThemeID
    }) {
      selectVisibleRow(selectedIndex)
    } else {
      tableView.deselectAll(nil)
    }
    updateCount()
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)):
      moveThemeSelection(by: 1)
      return true
    case #selector(NSResponder.moveUp(_:)):
      moveThemeSelection(by: -1)
      return true
    case #selector(NSResponder.pageDown(_:)):
      moveThemeSelection(by: visiblePageRowCount)
      return true
    case #selector(NSResponder.pageUp(_:)):
      moveThemeSelection(by: -visiblePageRowCount)
      return true
    case #selector(NSResponder.moveLeft(_:)):
      moveBackground(by: -1)
      return true
    case #selector(NSResponder.moveRight(_:)):
      moveBackground(by: 1)
      return true
    case #selector(NSResponder.moveLeftAndModifySelection(_:)):
      movePreview(by: -1)
      return true
    case #selector(NSResponder.moveRightAndModifySelection(_:)):
      movePreview(by: 1)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      applySelectedTheme(nil)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      window?.close()
      return true
    default:
      return false
    }
  }

  @objc private func showPreviousPreview(_ sender: Any?) {
    movePreview(by: -1)
  }

  @objc private func showNextPreview(_ sender: Any?) {
    movePreview(by: 1)
  }

  @objc private func showPreviousBackground(_ sender: Any?) {
    moveBackground(by: -1)
  }

  @objc private func showNextBackground(_ sender: Any?) {
    moveBackground(by: 1)
  }

  @objc private func chooseBackground(_ sender: Any?) {
    guard let item = selectedItem,
      item.backgrounds.indices.contains(backgroundPicker.indexOfSelectedItem)
    else { return }
    browserState.selectBackground(id: item.backgrounds[backgroundPicker.indexOfSelectedItem].id)
    updateBackgroundPresentation(item: item)
  }

  @objc private func applySelectedTheme(_ sender: Any?) {
    guard !isApplying, let item = selectedItem else { return }
    isApplying = true
    setControlsEnabled(false)
    statusLabel.textColor = item.package.semantic.accent.nsColor
    statusLabel.stringValue = "Applying \(item.displayName)…"
    statusLabel.toolTip = nil
    do {
      applyProcess = try launchSelection(browserState.selection)
      applyTimer = Timer.scheduledTimer(
        timeInterval: 0.1,
        target: self,
        selector: #selector(checkApplyProcess(_:)),
        userInfo: nil,
        repeats: true
      )
    } catch {
      isApplying = false
      setControlsEnabled(true)
      statusLabel.textColor = item.package.semantic.error.nsColor
      statusLabel.stringValue = "Could not start theme activation: \(error)"
      statusLabel.toolTip = String(describing: error)
    }
  }

  @objc private func checkApplyProcess(_ timer: Timer) {
    guard let applyProcess else {
      finishApply(timer: timer, status: nil)
      return
    }
    guard !applyProcess.isRunning() else { return }
    finishApply(timer: timer, status: applyProcess.terminationStatus())
  }

  private func finishApply(timer: Timer, status: Int32?) {
    timer.invalidate()
    applyTimer = nil
    applyProcess = nil
    isApplying = false
    setControlsEnabled(true)
    guard let item = selectedItem else { return }
    if status == 0 {
      statusLabel.textColor = item.package.semantic.accent.nsColor
      statusLabel.stringValue = "Applied \(item.displayName). Choose another or press Esc to close."
      statusLabel.toolTip = nil
    } else {
      statusLabel.textColor = item.package.semantic.error.nsColor
      statusLabel.stringValue =
        "Theme activation failed\(status.map { " (exit \($0))" } ?? ""). See the test log for details."
      statusLabel.toolTip = "/tmp/macarchy-theme-browser-test.log"
    }
  }

  private func configureContent(in window: NSWindow) {
    rootView.wantsLayer = true
    window.contentView = rootView

    searchField.placeholderString = "Search installed themes"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 13)
    searchField.controlSize = .small
    countLabel.font = .systemFont(ofSize: 11)

    let themeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
    themeColumn.title = "Theme"
    themeColumn.width = 200
    tableView.addTableColumn(themeColumn)
    tableView.headerView = nil
    tableView.rowHeight = 30
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = false
    tableView.delegate = self
    tableView.dataSource = self
    themeScrollView.documentView = tableView
    themeScrollView.hasVerticalScroller = true
    themeScrollView.autohidesScrollers = true
    themeScrollView.borderType = .noBorder
    themeScrollView.drawsBackground = false
    tableView.backgroundColor = .clear

    sidebar.addArrangedSubview(searchField)
    sidebar.addArrangedSubview(countLabel)
    sidebar.addArrangedSubview(themeScrollView)
    sidebar.orientation = .vertical
    sidebar.alignment = .leading
    sidebar.spacing = 8
    sidebar.wantsLayer = true
    sidebar.layer?.cornerRadius = 8
    themeScrollView.setContentHuggingPriority(.init(1), for: .vertical)
    themeScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    themeNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    themeNameLabel.lineBreakMode = .byTruncatingTail
    themeNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    previewImageView.imageScaling = .scaleProportionallyUpOrDown
    previewImageView.wantsLayer = true
    previewImageView.layer?.cornerRadius = 8
    previewImageView.layer?.masksToBounds = true
    previewImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    previewLabel.font = .systemFont(ofSize: 11)
    previewLabel.alignment = .center
    previewLabel.lineBreakMode = .byTruncatingMiddle
    previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    configureButton(previousPreviewButton, action: #selector(showPreviousPreview(_:)))
    configureButton(nextPreviewButton, action: #selector(showNextPreview(_:)))
    previousPreviewButton.title = "‹"
    nextPreviewButton.title = "›"
    let previewControls = NSStackView(views: [
      previousPreviewButton, previewLabel, nextPreviewButton,
    ])
    previewControls.orientation = .horizontal
    previewControls.alignment = .centerY
    previewControls.distribution = .fill
    previewControls.spacing = 8
    let headerSpacer = NSView()
    headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let header = NSStackView(views: [themeNameLabel, headerSpacer, previewControls])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8

    backgroundImageView.imageScaling = .scaleProportionallyUpOrDown
    backgroundImageView.wantsLayer = true
    backgroundImageView.layer?.cornerRadius = 8
    backgroundImageView.layer?.masksToBounds = true
    backgroundImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    backgroundImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    backgroundImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    backgroundLabel.font = .systemFont(ofSize: 11)
    backgroundLabel.lineBreakMode = .byTruncatingTail
    configureButton(previousBackgroundButton, action: #selector(showPreviousBackground(_:)))
    configureButton(nextBackgroundButton, action: #selector(showNextBackground(_:)))
    previousBackgroundButton.title = "‹"
    nextBackgroundButton.title = "›"
    backgroundPicker.target = self
    backgroundPicker.action = #selector(chooseBackground(_:))
    backgroundPicker.controlSize = .small
    backgroundPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let backgroundControls = NSStackView(views: [
      previousBackgroundButton, backgroundPicker, nextBackgroundButton,
    ])
    backgroundControls.orientation = .horizontal
    backgroundControls.alignment = .centerY
    backgroundControls.spacing = 8

    applyButton.target = self
    applyButton.action = #selector(applySelectedTheme(_:))
    applyButton.bezelStyle = .rounded
    applyButton.controlSize = .small
    applyButton.keyEquivalent = "\r"
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.maximumNumberOfLines = 2

    keyboardHelp.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
    keyboardHelp.lineBreakMode = .byTruncatingTail
    keyboardHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let bottomSpacer = NSView()
    bottomSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let bottomBar = NSStackView(views: [
      keyboardHelp, bottomSpacer, applyButton,
    ])
    bottomBar.orientation = .horizontal
    bottomBar.alignment = .centerY
    bottomBar.spacing = 8

    let detail = NSStackView(views: [
      header, previewImageView, backgroundImageView, backgroundControls, backgroundLabel,
      statusLabel, bottomBar,
    ])
    detail.orientation = .vertical
    detail.alignment = .leading
    detail.spacing = 8
    detail.setContentHuggingPriority(.init(1), for: .horizontal)
    backgroundImageView.setContentHuggingPriority(.init(1), for: .vertical)
    for view in [
      header, previewImageView, backgroundControls, backgroundLabel, statusLabel, bottomBar,
    ] {
      view.setContentHuggingPriority(.defaultHigh, for: .vertical)
      view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    let rootStack = NSStackView(views: [sidebar, detail])
    rootStack.orientation = .horizontal
    rootStack.alignment = .top
    rootStack.distribution = .fill
    rootStack.spacing = 16
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(rootStack)

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
      rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
      rootStack.topAnchor.constraint(
        equalTo: rootView.safeAreaLayoutGuide.topAnchor,
        constant: 8
      ),
      rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
      sidebar.widthAnchor.constraint(equalToConstant: 220),
      sidebar.heightAnchor.constraint(equalTo: rootStack.heightAnchor),
      detail.heightAnchor.constraint(equalTo: rootStack.heightAnchor),
      searchField.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
      searchField.heightAnchor.constraint(equalToConstant: 28),
      countLabel.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
      themeScrollView.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
      header.widthAnchor.constraint(equalTo: detail.widthAnchor),
      previewImageView.widthAnchor.constraint(equalTo: detail.widthAnchor),
      previewImageView.heightAnchor.constraint(equalToConstant: 88),
      backgroundImageView.widthAnchor.constraint(equalTo: detail.widthAnchor),
      backgroundImageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
      backgroundLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
      backgroundControls.widthAnchor.constraint(equalTo: detail.widthAnchor),
      statusLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
      statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
      bottomBar.widthAnchor.constraint(equalTo: detail.widthAnchor),
      applyButton.widthAnchor.constraint(equalToConstant: 84),
    ])

    updateCount()
  }

  private func configureButton(_ button: NSButton, action: Selector) {
    button.target = self
    button.action = action
    button.bezelStyle = .rounded
    button.controlSize = .small
  }

  private func makeThemeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private var selectedItem: ThemeBrowserItem? {
    content.item(id: browserState.selectedThemeID)
  }

  private func selectTheme(id: String) {
    guard let item = content.item(id: id) else { return }
    browserState.selectTheme(id: id)
    window?.appearance = NSAppearance(named: item.appearance == .dark ? .darkAqua : .aqua)
    window?.backgroundColor = item.package.semantic.background.nsColor
    rootView.layer?.backgroundColor = item.package.semantic.background.nsColor.cgColor
    sidebar.layer?.backgroundColor = item.package.semantic.surface.nsColor.cgColor
    themeNameLabel.stringValue = "\(item.displayName) · \(item.appearance.rawValue)"
    themeNameLabel.textColor = item.package.semantic.text.nsColor
    countLabel.textColor = item.package.semantic.mutedText.nsColor
    previewLabel.textColor = item.package.semantic.mutedText.nsColor
    backgroundLabel.textColor = item.package.semantic.mutedText.nsColor
    statusLabel.textColor = item.package.semantic.mutedText.nsColor
    keyboardHelp.textColor = item.package.semantic.mutedText.nsColor
    statusLabel.stringValue = "Browsing is local. Only Apply changes the active theme."
    updateVisibleThemeRowPalette(item: item)
    previews = [item.generatedPreview]
    previewIndex = 0
    updatePreviewPresentation()
    configureBackgrounds(item: item)
    loadGallery(for: item)
  }

  private func loadGallery(for item: ThemeBrowserItem) {
    galleryTask?.cancel()
    galleryTimer?.invalidate()
    let result = ThemeBrowserAsyncResult<ThemeBrowserGalleryOutcome>()
    galleryResult = result
    galleryThemeID = item.id
    previewLabel.stringValue = "Generated palette · loading gallery…"
    let loader = galleryLoader
    galleryTask = Task.detached(priority: .userInitiated) {
      guard !Task.isCancelled else { return }
      do {
        result.complete(.loaded(try loader.load(item: item)))
      } catch {
        result.complete(.failed(String(describing: error)))
      }
    }
    galleryTimer = Timer.scheduledTimer(
      timeInterval: 0.05,
      target: self,
      selector: #selector(checkGalleryResult(_:)),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func checkGalleryResult(_ timer: Timer) {
    guard let outcome = galleryResult?.value() else { return }
    timer.invalidate()
    galleryTask = nil
    galleryTimer = nil
    galleryResult = nil
    defer { galleryThemeID = nil }
    guard
      let galleryThemeID,
      browserState.selectedThemeID == galleryThemeID,
      let item = selectedItem
    else { return }
    switch outcome {
    case .loaded(let imported):
      previews = [item.generatedPreview] + imported
      previewIndex = min(previewIndex, previews.count - 1)
      updatePreviewPresentation()
    case .failed(let reason):
      previews = [item.generatedPreview]
      previewIndex = 0
      updatePreviewPresentation()
      statusLabel.textColor = item.package.semantic.error.nsColor
      statusLabel.stringValue = "Imported preview gallery failed validation: \(reason)"
    }
  }

  private func movePreview(by offset: Int) {
    guard previews.count > 1 else { return }
    previewIndex = (previewIndex + offset + previews.count) % previews.count
    updatePreviewPresentation()
  }

  private func updatePreviewPresentation() {
    guard previews.indices.contains(previewIndex), let item = selectedItem else { return }
    let preview = previews[previewIndex]
    previewImageView.image = NSImage(data: preview.data)
    if previewImageView.image == nil {
      statusLabel.textColor = item.package.semantic.error.nsColor
      statusLabel.stringValue = ThemeBrowserError.cannotRenderPreview(themeID: item.id).description
    }
    previewLabel.stringValue = "\(previewIndex + 1) of \(previews.count) · \(preview.label)"
    let navigable = previews.count > 1
    previousPreviewButton.isEnabled = navigable
    nextPreviewButton.isEnabled = navigable
  }

  private func configureBackgrounds(item: ThemeBrowserItem) {
    backgroundPicker.removeAllItems()
    for background in item.backgrounds {
      backgroundPicker.addItem(withTitle: background.id)
      backgroundPicker.lastItem?.toolTip = background.path
    }
    guard !item.backgrounds.isEmpty else {
      backgroundImageView.image = nil
      backgroundLabel.stringValue = "No backgrounds · wallpaper remains unmanaged"
      backgroundLabel.toolTip = nil
      backgroundPicker.isEnabled = false
      previousBackgroundButton.isEnabled = false
      nextBackgroundButton.isEnabled = false
      return
    }
    let selectedID = browserState.selection.backgroundID ?? item.backgrounds[0].id
    browserState.selectBackground(id: selectedID)
    let index = item.backgrounds.firstIndex(where: { $0.id == selectedID }) ?? 0
    backgroundPicker.selectItem(at: index)
    updateBackgroundPresentation(item: item)
  }

  private func moveBackground(by offset: Int) {
    guard let item = selectedItem, !item.backgrounds.isEmpty else { return }
    browserState.moveBackground(by: offset)
    let selectedID = browserState.selection.backgroundID
    let next = item.backgrounds.firstIndex(where: { $0.id == selectedID }) ?? 0
    backgroundPicker.selectItem(at: next)
    updateBackgroundPresentation(item: item)
  }

  private func updateBackgroundPresentation(item: ThemeBrowserItem) {
    guard let backgroundID = browserState.selection.backgroundID,
      let background = item.backgrounds.first(where: { $0.id == backgroundID })
    else { return }
    let index = item.backgrounds.firstIndex(where: { $0.id == backgroundID }) ?? 0
    backgroundLabel.stringValue =
      "\(index + 1) of \(item.backgrounds.count) · \(background.id) · \(background.format.rawValue)"
    backgroundLabel.toolTip = background.path
    backgroundPicker.isEnabled = true
    let navigable = item.backgrounds.count > 1
    previousBackgroundButton.isEnabled = navigable
    nextBackgroundButton.isEnabled = navigable
    loadBackgroundImage(item: item, backgroundID: backgroundID)
  }

  private func loadBackgroundImage(item: ThemeBrowserItem, backgroundID: String) {
    backgroundImageTask?.cancel()
    backgroundImageTimer?.invalidate()
    let key = ThemeBrowserBackgroundImageKey(themeID: item.id, backgroundID: backgroundID)
    backgroundImageKey = key
    if let cached = backgroundImageCache.object(forKey: key.cacheKey) {
      backgroundImageView.image = cached
      return
    }
    backgroundImageView.image = nil
    guard let data = item.backgroundData(id: backgroundID) else {
      showBackgroundDecodeFailure(item: item, backgroundID: backgroundID)
      return
    }
    let result = ThemeBrowserAsyncResult<ThemeBrowserImageOutcome>()
    backgroundImageResult = result
    backgroundImageTask = Task.detached(priority: .userInitiated) {
      do {
        try await Task.sleep(for: .milliseconds(75))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      let image = ThemeBrowserImageDecoder.thumbnail(data: data, maximumPixelSize: 1_200)
      result.complete(image.map(ThemeBrowserImageOutcome.loaded) ?? .failed)
    }
    backgroundImageTimer = Timer.scheduledTimer(
      timeInterval: 0.03,
      target: self,
      selector: #selector(checkBackgroundImageResult(_:)),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func checkBackgroundImageResult(_ timer: Timer) {
    guard let outcome = backgroundImageResult?.value() else { return }
    timer.invalidate()
    backgroundImageTask = nil
    backgroundImageTimer = nil
    backgroundImageResult = nil
    guard
      let key = backgroundImageKey,
      browserState.selectedThemeID == key.themeID,
      browserState.selection.backgroundID == key.backgroundID,
      let item = selectedItem
    else { return }
    switch outcome {
    case .loaded(let image):
      let decoded = NSImage(
        cgImage: image,
        size: NSSize(width: image.width, height: image.height)
      )
      backgroundImageCache.setObject(
        decoded,
        forKey: key.cacheKey,
        cost: image.bytesPerRow * image.height
      )
      backgroundImageView.image = decoded
    case .failed:
      showBackgroundDecodeFailure(item: item, backgroundID: key.backgroundID)
    }
  }

  private func showBackgroundDecodeFailure(item: ThemeBrowserItem, backgroundID: String) {
    statusLabel.textColor = item.package.semantic.error.nsColor
    statusLabel.stringValue =
      "Cannot render background '\(backgroundID)' for theme '\(item.id)'"
  }

  private func moveThemeSelection(by offset: Int) {
    guard !browserState.visibleItems.isEmpty else { return }
    let previousID = browserState.selectedThemeID
    browserState.moveTheme(by: offset)
    guard browserState.selectedThemeID != previousID else { return }
    guard
      let row = browserState.visibleItems.firstIndex(where: {
        $0.id == browserState.selectedThemeID
      })
    else { return }
    selectVisibleRow(row)
  }

  private func selectVisibleRow(_ row: Int) {
    guard browserState.visibleItems.indices.contains(row) else { return }
    if tableView.selectedRow == row {
      selectTheme(id: browserState.visibleItems[row].id)
    } else {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      tableView.scrollRowToVisible(row)
    }
  }

  private var visiblePageRowCount: Int {
    max(Int(tableView.visibleRect.height / tableView.rowHeight) - 1, 1)
  }

  private func updateCount() {
    if browserState.visibleItems.count == content.items.count {
      countLabel.stringValue = "\(content.items.count) installed themes"
    } else {
      countLabel.stringValue =
        "\(browserState.visibleItems.count) of \(content.items.count) installed themes"
    }
  }

  private func updateVisibleThemeRowPalette(item: ThemeBrowserItem) {
    for row in 0..<tableView.numberOfRows {
      guard
        let rowView = tableView.rowView(atRow: row, makeIfNecessary: false)
          as? ThemeBrowserTableRowView
      else { continue }
      rowView.updatePalette(
        normalTextColor: item.package.semantic.text.nsColor,
        selectedTextColor: item.package.terminal.selectionForeground.nsColor,
        selectedBackgroundColor: item.package.terminal.selectionBackground.nsColor
      )
    }
  }

  private func setControlsEnabled(_ enabled: Bool) {
    searchField.isEnabled = enabled
    tableView.isEnabled = enabled
    applyButton.isEnabled = enabled
    if let item = selectedItem {
      backgroundPicker.isEnabled = enabled && !item.backgrounds.isEmpty
      previousBackgroundButton.isEnabled = enabled && item.backgrounds.count > 1
      nextBackgroundButton.isEnabled = enabled && item.backgrounds.count > 1
    }
    previousPreviewButton.isEnabled = enabled && previews.count > 1
    nextPreviewButton.isEnabled = enabled && previews.count > 1
  }

  private static func activeScreen() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
  }
}
