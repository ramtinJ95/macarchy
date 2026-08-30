import AppKit
import Foundation
import ThemeCore

private let keybindingSearchLocale = Locale(identifier: "en_US_POSIX")

struct KeybindingsPopupRow: Sendable {
  let identity: String
  let chord: String
  let label: String
  let category: String
  let command: String
  let aliases: [String]
  let commandSource: String?
  let metadataSource: String?

  init(_ presented: SkhdPresentedBinding) {
    identity = presented.binding.identity
    chord = presented.binding.chord
    label = presented.metadata?.label ?? presented.binding.command
    category = presented.metadata?.category ?? "Uncatalogued"
    command = presented.binding.command
    aliases = presented.metadata?.aliases ?? []
    commandSource = nil
    metadataSource = nil
  }

  init(_ effective: EffectiveKeybinding) {
    identity = effective.binding.identity
    chord = effective.binding.chord
    label = effective.metadata?.label ?? effective.binding.command
    category = effective.metadata?.category ?? "Uncatalogued"
    command = effective.binding.command
    aliases = effective.metadata?.aliases ?? []
    commandSource = effective.commandSource.rawValue
    metadataSource = effective.metadataSource?.rawValue
  }

  fileprivate func matches(_ terms: [String]) -> Bool {
    guard !terms.isEmpty else { return true }
    let searchable = ([identity, chord, label, category, command] + aliases)
      .joined(separator: "\n")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: keybindingSearchLocale)
    return terms.allSatisfy(searchable.contains)
  }
}

struct KeybindingsPopupContent: Sendable {
  let rows: [KeybindingsPopupRow]
  let theme: NormalizedTheme

  func filteredRows(query: String) -> [KeybindingsPopupRow] {
    let terms =
      query
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: keybindingSearchLocale
      )
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
    return rows.filter { $0.matches(terms) }
  }
}

enum KeybindingsShowError: Error, CustomStringConvertible, Sendable {
  case cannotReadConfiguration(URL, String)
  case invalidConfiguration(URL, [SkhdDiagnostic])
  case invalidCatalog(URL, String)
  case invalidEffectiveConfiguration([KeybindingCompositionDiagnostic])
  case invalidGeneratedConfiguration(String)
  case invalidActiveTheme(String)
  case cannotActivateAccessoryApplication
  case noActiveDisplay

  var description: String {
    switch self {
    case .cannotReadConfiguration(let source, let reason):
      "Cannot read skhd configuration at \(source.path): \(reason)"
    case .invalidConfiguration(let source, let diagnostics):
      diagnostics.map { diagnostic in
        let location = diagnostic.line.map { "\(source.path):\($0)" } ?? source.path
        return "\(location): \(diagnostic.message)"
      }.joined(separator: "\n")
    case .invalidCatalog(let source, let reason):
      "Cannot load keybinding catalog at \(source.path): \(reason)"
    case .invalidEffectiveConfiguration(let diagnostics):
      diagnostics.map { diagnostic in
        let location = diagnostic.line.map { "\(diagnostic.source):\($0)" } ?? diagnostic.source
        return "\(location): \(diagnostic.message)"
      }.joined(separator: "\n")
    case .invalidGeneratedConfiguration(let reason):
      "Cannot inspect the current generated keybindings: \(reason)"
    case .invalidActiveTheme(let reason):
      "Cannot load the active Macarchy theme: \(reason)"
    case .cannotActivateAccessoryApplication:
      "Cannot run the keybindings popup as an accessory application"
    case .noActiveDisplay:
      "Cannot show keybindings without an active display"
    }
  }
}

struct KeybindingsShowCommandLoader: Sendable {
  let read: @Sendable (URL) throws -> String
  let loadCatalog: @Sendable (URL) throws -> SkhdKeybindingCatalog
  let loadTheme: @Sendable (URL) throws -> NormalizedTheme

  static let live = KeybindingsShowCommandLoader(
    read: readSkhdConfiguration,
    loadCatalog: { try SkhdKeybindingCatalogLoader().load(at: $0) },
    loadTheme: loadActiveTheme
  )

  func load(
    configurationURL: URL,
    catalogURL: URL,
    stateRoot: URL
  ) throws -> KeybindingsPopupContent {
    let configuration: String
    do {
      configuration = try read(configurationURL)
    } catch {
      throw KeybindingsShowError.cannotReadConfiguration(
        configurationURL,
        String(describing: error)
      )
    }

    let parsed = SkhdConfigurationParser().parse(configuration)
    guard parsed.diagnostics.isEmpty else {
      throw KeybindingsShowError.invalidConfiguration(configurationURL, parsed.diagnostics)
    }

    let catalog: SkhdKeybindingCatalog
    do {
      catalog = try loadCatalog(catalogURL)
    } catch {
      let reason =
        (error as? SkhdCatalogError)?.diagnosticMessage
        ?? String(describing: error)
      throw KeybindingsShowError.invalidCatalog(catalogURL, reason)
    }

    let theme: NormalizedTheme
    do {
      theme = try loadTheme(stateRoot)
    } catch {
      throw KeybindingsShowError.invalidActiveTheme(String(describing: error))
    }
    let correlation = SkhdKeybindingCatalogLoader().correlate(
      bindings: parsed.bindings,
      catalog: catalog
    )
    return KeybindingsPopupContent(
      rows: correlation.bindings.map(KeybindingsPopupRow.init),
      theme: theme
    )
  }

  func load(
    effectiveState: KeybindingEffectiveState,
    stateRoot: URL
  ) throws -> KeybindingsPopupContent {
    guard !effectiveState.configuration.isBlocked else {
      throw KeybindingsShowError.invalidEffectiveConfiguration(
        effectiveState.configuration.diagnostics
      )
    }
    guard effectiveState.generation.status != .invalid else {
      throw KeybindingsShowError.invalidGeneratedConfiguration(
        effectiveState.generation.message ?? "current generation is invalid"
      )
    }
    let theme: NormalizedTheme
    do {
      theme = try loadTheme(stateRoot)
    } catch {
      throw KeybindingsShowError.invalidActiveTheme(String(describing: error))
    }
    return KeybindingsPopupContent(
      rows: effectiveState.attributedBindings.map(KeybindingsPopupRow.init),
      theme: theme
    )
  }
}

private func loadActiveTheme(stateRoot: URL) throws -> NormalizedTheme {
  let manifest = try ReconciliationStatusStore(root: stateRoot).activeManifest()
  let themeURL = stateRoot.appending(
    path: "generations/\(manifest.generationID)/theme.json"
  )
  let theme = try JSONDecoder().decode(
    NormalizedTheme.self,
    from: BoundedRegularFile.read(at: themeURL).data
  )
  guard
    theme.generationID == manifest.generationID,
    theme.themeID == manifest.themeID,
    theme.schemaVersion == manifest.themeSchemaVersion
  else {
    throw ReconciliationStatusError.invalidActiveGeneration(
      "theme.json does not match the active manifest"
    )
  }
  return theme
}

@MainActor
private final class KeybindingsPopupWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    close()
  }
}

@MainActor
private final class KeybindingsPopupTableRowView: NSTableRowView {
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

@MainActor
final class KeybindingsPopupWindowController: NSWindowController, NSApplicationDelegate,
  NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate
{
  static let windowTitle = "Macarchy Keybindings"

  private let content: KeybindingsPopupContent
  private var visibleRows: [KeybindingsPopupRow]
  private let searchField = NSSearchField()
  private let countLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let commandLabel = NSTextField(wrappingLabelWithString: "")

  init(content: KeybindingsPopupContent) throws {
    self.content = content
    visibleRows = content.rows

    guard let visibleFrame = Self.activeScreen()?.visibleFrame else {
      throw KeybindingsShowError.noActiveDisplay
    }
    let width = min(760, visibleFrame.width - 48)
    let height = min(600, visibleFrame.height - 48)
    let frame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height
    )
    let window = KeybindingsPopupWindow(
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
    window.appearance = NSAppearance(
      named: content.theme.appearance == .dark ? .darkAqua : .aqua
    )
    super.init(window: window)
    window.delegate = self
    configureContent(in: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func run() throws {
    let application = NSApplication.shared
    guard application.setActivationPolicy(.accessory) else {
      throw KeybindingsShowError.cannotActivateAccessoryApplication
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
    window?.close()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    visibleRows.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let tableColumn else { return nil }
    let item = visibleRows[row]
    let value: String
    let font: NSFont
    switch tableColumn.identifier.rawValue {
    case "shortcut":
      value = item.chord
      font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    case "category":
      value = item.category
      font = .systemFont(ofSize: 13)
    default:
      value = item.label
      font = .systemFont(ofSize: 13, weight: .medium)
    }

    let identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn.identifier.rawValue)")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier: identifier)
    cell.textField?.stringValue = value
    cell.textField?.font = font
    cell.textField?.textColor =
      row == tableView.selectedRow
      ? content.theme.terminal.selectionForeground.nsColor
      : content.theme.semantic.text.nsColor
    cell.toolTip = value
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = KeybindingsPopupTableRowView(
      normalTextColor: content.theme.semantic.text.nsColor,
      selectedTextColor: content.theme.terminal.selectionForeground.nsColor,
      selectedBackgroundColor: content.theme.terminal.selectionBackground.nsColor
    )
    return view
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateCommandDetail()
  }

  func controlTextDidChange(_ notification: Notification) {
    visibleRows = content.filteredRows(query: searchField.stringValue)
    tableView.reloadData()
    selectFirstVisibleRow()
    updateCount()
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)
      return true
    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)
      return true
    case #selector(NSResponder.pageDown(_:)):
      moveSelection(by: visiblePageRowCount)
      return true
    case #selector(NSResponder.pageUp(_:)):
      moveSelection(by: -visiblePageRowCount)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      window?.close()
      return true
    default:
      return false
    }
  }

  private func configureContent(in window: NSWindow) {
    let background = content.theme.semantic.background.nsColor
    let surface = content.theme.semantic.surface.nsColor
    let text = content.theme.semantic.text.nsColor
    let muted = content.theme.semantic.mutedText.nsColor

    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = background.cgColor
    window.contentView = root

    let title = NSTextField(labelWithString: Self.windowTitle)
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = text

    countLabel.font = .systemFont(ofSize: 12)
    countLabel.textColor = muted

    searchField.placeholderString = "Search shortcuts, actions, categories, or commands"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 14)

    let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
    shortcutColumn.title = "Shortcut"
    shortcutColumn.width = 170
    shortcutColumn.minWidth = 130
    let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
    actionColumn.title = "Action"
    actionColumn.width = 360
    actionColumn.minWidth = 220
    let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
    categoryColumn.title = "Category"
    categoryColumn.width = 160
    categoryColumn.minWidth = 110
    tableView.addTableColumn(shortcutColumn)
    tableView.addTableColumn(actionColumn)
    tableView.addTableColumn(categoryColumn)
    tableView.headerView = NSTableHeaderView()
    tableView.rowHeight = 34
    tableView.intercellSpacing = NSSize(width: 12, height: 2)
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = false
    tableView.backgroundColor = surface
    tableView.delegate = self
    tableView.dataSource = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.backgroundColor = surface
    scrollView.borderType = .noBorder
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = 10
    scrollView.layer?.borderWidth = 1
    scrollView.layer?.borderColor = content.theme.semantic.border.nsColor.cgColor

    commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    commandLabel.textColor = muted
    commandLabel.maximumNumberOfLines = 2
    commandLabel.lineBreakMode = .byTruncatingTail

    let notice = NSTextField(labelWithString: "Informational only — listed commands are never run.")
    notice.font = .systemFont(ofSize: 11)
    notice.textColor = content.theme.semantic.accent.nsColor

    let stack = NSStackView(views: [
      title, countLabel, searchField, scrollView, commandLabel, notice,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setCustomSpacing(16, after: countLabel)
    stack.setCustomSpacing(14, after: searchField)
    root.addSubview(stack)

    for view in [title, countLabel, searchField, scrollView, commandLabel, notice] {
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
      searchField.heightAnchor.constraint(equalToConstant: 36),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])

    updateCount()
    selectFirstVisibleRow()
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func updateCount() {
    if visibleRows.count == content.rows.count {
      countLabel.stringValue = "\(content.rows.count) configured shortcuts"
    } else {
      countLabel.stringValue = "\(visibleRows.count) of \(content.rows.count) configured shortcuts"
    }
  }

  private func selectFirstVisibleRow() {
    guard !visibleRows.isEmpty else {
      tableView.deselectAll(nil)
      updateCommandDetail()
      return
    }
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    tableView.scrollRowToVisible(0)
    updateCommandDetail()
  }

  private func moveSelection(by offset: Int) {
    guard !visibleRows.isEmpty else { return }
    let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
    let next = min(max(current + offset, 0), visibleRows.count - 1)
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  private var visiblePageRowCount: Int {
    max(Int(tableView.visibleRect.height / tableView.rowHeight) - 1, 1)
  }

  private func updateCommandDetail() {
    guard visibleRows.indices.contains(tableView.selectedRow) else {
      commandLabel.stringValue = "No matching shortcuts"
      commandLabel.toolTip = nil
      return
    }
    let command = visibleRows[tableView.selectedRow].command
    let row = visibleRows[tableView.selectedRow]
    let sources = [
      row.commandSource.map { "command=\($0)" },
      row.metadataSource.map { "metadata=\($0)" },
    ].compactMap { $0 }
    let source = sources.isEmpty ? "" : " [\(sources.joined(separator: ", "))]"
    commandLabel.stringValue = "Configured command\(source): \(command)"
    commandLabel.toolTip = command
  }

  private static func activeScreen() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
  }
}

extension SRGBColor {
  @MainActor
  var nsColor: NSColor {
    let value = Int(rawValue.dropFirst(), radix: 16)!
    return NSColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255,
      green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255,
      alpha: 1
    )
  }
}
