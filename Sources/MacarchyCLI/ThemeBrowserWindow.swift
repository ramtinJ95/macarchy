import AppKit
import Foundation
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
    if direction != 0, modifiers.contains(.option) {
      navigate?(direction < 0 ? .previousBackground : .nextBackground)
      return
    }
    if direction != 0, modifiers.contains(.control) {
      navigate?(direction < 0 ? .previousPreview : .nextPreview)
      return
    }
    super.sendEvent(event)
  }
}

private enum ThemeBrowserGalleryOutcome: Sendable {
  case loaded([ThemeBrowserPreview])
  case failed(String)
}

@MainActor
final class ThemeBrowserWindowController: NSWindowController, NSApplicationDelegate,
  NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate
{
  static let windowTitle = "Macarchy Themes"

  private let content: ThemeBrowserContent
  private let galleryLoader: ThemeBrowserGalleryLoader
  private let applySelection:
    @Sendable (_ themeID: String, _ backgroundID: String?) async throws
      -> (output: String, succeeded: Bool)

  private var browserState: ThemeBrowserState
  private var previews: [ThemeBrowserPreview] = []
  private var previewIndex = 0
  private var galleryTask: Task<Void, Never>?
  private var isApplying = false
  private(set) var execution: (output: String, succeeded: Bool)?

  private let rootView = NSView()
  private let searchField = NSSearchField()
  private let countLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let themeNameLabel = NSTextField(labelWithString: "")
  private let previewImageView = NSImageView()
  private let previewLabel = NSTextField(labelWithString: "")
  private let previousPreviewButton = NSButton(title: "Previous", target: nil, action: nil)
  private let nextPreviewButton = NSButton(title: "Next", target: nil, action: nil)
  private let backgroundImageView = NSImageView()
  private let backgroundLabel = NSTextField(labelWithString: "")
  private let backgroundPicker = NSPopUpButton()
  private let previousBackgroundButton = NSButton(title: "Previous", target: nil, action: nil)
  private let nextBackgroundButton = NSButton(title: "Next", target: nil, action: nil)
  private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  init(
    content: ThemeBrowserContent,
    galleryLoader: ThemeBrowserGalleryLoader = .live,
    applySelection:
      @escaping @Sendable (
        _ themeID: String,
        _ backgroundID: String?
      ) async throws -> (output: String, succeeded: Bool)
  ) throws {
    self.content = content
    self.galleryLoader = galleryLoader
    self.applySelection = applySelection
    browserState = ThemeBrowserState(content: content)

    guard let visibleFrame = Self.activeScreen()?.visibleFrame else {
      throw ThemeBrowserError.noActiveDisplay
    }
    let width = min(1_140, visibleFrame.width - 48)
    let height = min(780, visibleFrame.height - 48)
    let frame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height
    )
    let window = ThemeBrowserWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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
    selectTheme(id: browserState.selectedThemeID)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func run() throws -> (output: String, succeeded: Bool)? {
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
    return execution
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func windowDidResignKey(_ notification: Notification) {
    if !isApplying { window?.close() }
  }

  func windowWillClose(_ notification: Notification) {
    galleryTask?.cancel()
    NSApplication.shared.stop(nil)
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
    return cell
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
    case #selector(NSResponder.insertNewline(_:)):
      applySelectedTheme(nil)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      if !isApplying { window?.close() }
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
    let backgroundID = browserState.selection.backgroundID
    let themeID = item.id
    Task { @MainActor [weak self, applySelection] in
      guard let self else { return }
      do {
        execution = try await applySelection(themeID, backgroundID)
      } catch {
        execution = ("Theme '\(themeID)' was not activated: \(error)", false)
      }
      galleryTask?.cancel()
      window?.close()
    }
  }

  private func configureContent(in window: NSWindow) {
    rootView.wantsLayer = true
    window.contentView = rootView

    let title = NSTextField(labelWithString: Self.windowTitle)
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    searchField.placeholderString = "Search installed themes"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 14)
    countLabel.font = .systemFont(ofSize: 12)

    let themeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
    themeColumn.title = "Theme"
    themeColumn.width = 250
    tableView.addTableColumn(themeColumn)
    tableView.headerView = nil
    tableView.rowHeight = 38
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = false
    tableView.delegate = self
    tableView.dataSource = self
    let themeScrollView = NSScrollView()
    themeScrollView.documentView = tableView
    themeScrollView.hasVerticalScroller = true
    themeScrollView.autohidesScrollers = true
    themeScrollView.borderType = .noBorder

    let keyboardHelp = NSTextField(
      wrappingLabelWithString:
        "Type to search · ↑↓ themes · ⌥←→ backgrounds · ⌃←→ previews · Enter applies · Escape closes"
    )
    keyboardHelp.font = .systemFont(ofSize: 11)

    let sidebar = NSStackView(views: [
      title, countLabel, searchField, themeScrollView, keyboardHelp,
    ])
    sidebar.orientation = .vertical
    sidebar.alignment = .leading
    sidebar.spacing = 10
    sidebar.setCustomSpacing(16, after: countLabel)
    sidebar.setCustomSpacing(14, after: searchField)

    themeNameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    previewImageView.imageScaling = .scaleProportionallyUpOrDown
    previewImageView.wantsLayer = true
    previewImageView.layer?.cornerRadius = 12
    previewImageView.layer?.masksToBounds = true
    previewLabel.font = .systemFont(ofSize: 12)
    previewLabel.alignment = .center
    configureButton(previousPreviewButton, action: #selector(showPreviousPreview(_:)))
    configureButton(nextPreviewButton, action: #selector(showNextPreview(_:)))
    let previewControls = NSStackView(views: [
      previousPreviewButton, previewLabel, nextPreviewButton,
    ])
    previewControls.orientation = .horizontal
    previewControls.alignment = .centerY
    previewControls.distribution = .fill
    previewControls.spacing = 10

    let backgroundTitle = NSTextField(labelWithString: "Background")
    backgroundTitle.font = .systemFont(ofSize: 15, weight: .semibold)
    backgroundImageView.imageScaling = .scaleProportionallyUpOrDown
    backgroundImageView.wantsLayer = true
    backgroundImageView.layer?.cornerRadius = 10
    backgroundImageView.layer?.masksToBounds = true
    backgroundLabel.font = .systemFont(ofSize: 12)
    configureButton(previousBackgroundButton, action: #selector(showPreviousBackground(_:)))
    configureButton(nextBackgroundButton, action: #selector(showNextBackground(_:)))
    backgroundPicker.target = self
    backgroundPicker.action = #selector(chooseBackground(_:))
    let backgroundControls = NSStackView(views: [
      previousBackgroundButton, backgroundPicker, nextBackgroundButton,
    ])
    backgroundControls.orientation = .horizontal
    backgroundControls.alignment = .centerY
    backgroundControls.spacing = 10

    applyButton.target = self
    applyButton.action = #selector(applySelectedTheme(_:))
    applyButton.bezelStyle = .rounded
    applyButton.keyEquivalent = "\r"
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.maximumNumberOfLines = 2

    let detail = NSStackView(views: [
      themeNameLabel, previewImageView, previewControls, backgroundTitle, backgroundImageView,
      backgroundLabel, backgroundControls, statusLabel, applyButton,
    ])
    detail.orientation = .vertical
    detail.alignment = .leading
    detail.spacing = 10
    detail.setCustomSpacing(16, after: previewControls)

    let rootStack = NSStackView(views: [sidebar, detail])
    rootStack.orientation = .horizontal
    rootStack.alignment = .top
    rootStack.spacing = 24
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(rootStack)

    for view in [title, countLabel, searchField, themeScrollView, keyboardHelp] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
    }
    for view in [
      themeNameLabel, previewImageView, previewControls, backgroundTitle, backgroundImageView,
      backgroundLabel, backgroundControls, statusLabel, applyButton,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
      rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
      rootStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
      rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
      sidebar.widthAnchor.constraint(equalToConstant: 280),
      searchField.heightAnchor.constraint(equalToConstant: 36),
      themeScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),
      detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
      previewImageView.widthAnchor.constraint(equalTo: detail.widthAnchor),
      previewImageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
      previewControls.widthAnchor.constraint(equalTo: detail.widthAnchor),
      backgroundImageView.widthAnchor.constraint(equalTo: detail.widthAnchor),
      backgroundImageView.heightAnchor.constraint(equalToConstant: 170),
      backgroundLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
      backgroundControls.widthAnchor.constraint(equalTo: detail.widthAnchor),
      statusLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
      applyButton.widthAnchor.constraint(equalToConstant: 110),
    ])

    updateCount()
  }

  private func configureButton(_ button: NSButton, action: Selector) {
    button.target = self
    button.action = action
    button.bezelStyle = .rounded
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
    let selectedRow = browserState.visibleItems.firstIndex(where: { $0.id == id })
    if let selectedRow, tableView.selectedRow != selectedRow {
      tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
      tableView.scrollRowToVisible(selectedRow)
    }
    window?.appearance = NSAppearance(named: item.appearance == .dark ? .darkAqua : .aqua)
    rootView.layer?.backgroundColor = item.package.semantic.background.nsColor.cgColor
    themeNameLabel.stringValue = "\(item.displayName) · \(item.appearance.rawValue)"
    themeNameLabel.textColor = item.package.semantic.text.nsColor
    countLabel.textColor = item.package.semantic.mutedText.nsColor
    previewLabel.textColor = item.package.semantic.mutedText.nsColor
    backgroundLabel.textColor = item.package.semantic.mutedText.nsColor
    statusLabel.textColor = item.package.semantic.mutedText.nsColor
    statusLabel.stringValue = "Browsing is local. Only Apply changes the active theme."
    previews = [item.generatedPreview]
    previewIndex = 0
    updatePreviewPresentation()
    configureBackgrounds(item: item)
    loadGallery(for: item)
  }

  private func loadGallery(for item: ThemeBrowserItem) {
    galleryTask?.cancel()
    let selectedID = item.id
    previewLabel.stringValue = "Generated palette · loading gallery…"
    let loader = galleryLoader
    galleryTask = Task { @MainActor [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) {
        do {
          return ThemeBrowserGalleryOutcome.loaded(try loader.load(item: item))
        } catch {
          return ThemeBrowserGalleryOutcome.failed(String(describing: error))
        }
      }.value
      guard let self, !Task.isCancelled, browserState.selectedThemeID == selectedID else { return }
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
    let navigable = previews.count > 1 && !isApplying
    previousPreviewButton.isEnabled = navigable
    nextPreviewButton.isEnabled = navigable
  }

  private func configureBackgrounds(item: ThemeBrowserItem) {
    backgroundPicker.removeAllItems()
    for background in item.backgrounds {
      backgroundPicker.addItem(withTitle: "\(background.id) · \(background.path)")
    }
    guard !item.backgrounds.isEmpty else {
      backgroundImageView.image = nil
      backgroundLabel.stringValue = "No backgrounds · wallpaper remains unmanaged"
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
    backgroundImageView.image = item.backgroundData(id: backgroundID).flatMap(NSImage.init(data:))
    backgroundLabel.stringValue =
      "\(background.id) · \(background.format.rawValue) · \(background.path)"
    backgroundPicker.isEnabled = !isApplying
    let navigable = item.backgrounds.count > 1 && !isApplying
    previousBackgroundButton.isEnabled = navigable
    nextBackgroundButton.isEnabled = navigable
  }

  private func moveThemeSelection(by offset: Int) {
    guard !browserState.visibleItems.isEmpty else { return }
    browserState.moveTheme(by: offset)
    guard
      let row = browserState.visibleItems.firstIndex(where: {
        $0.id == browserState.selectedThemeID
      })
    else { return }
    selectVisibleRow(row)
  }

  private func selectVisibleRow(_ row: Int) {
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    selectTheme(id: browserState.visibleItems[row].id)
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
