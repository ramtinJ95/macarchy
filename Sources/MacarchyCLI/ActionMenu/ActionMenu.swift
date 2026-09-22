import AppKit
import ArgumentParser
import Foundation
import ThemeCore

enum ActionMenuAction: CaseIterable, Equatable, Sendable {
  case appearance
  case keybindings
  case screenshot
  case annotate
  case profile(ProfileEditAction)
  case neovim
  case configuration(MenuConfigurationAction)
  case maintenance(MaintenanceAction)

  static var allCases: [Self] {
    ProfileEditAction.allCases.map(Self.profile)
      + [.neovim] + MenuConfigurationAction.allCases.map(Self.configuration)
      + [.appearance, .keybindings, .screenshot, .annotate]
      + MaintenanceAction.allCases.map(Self.maintenance)
  }

  var category: String {
    switch self {
    case .profile, .neovim, .configuration: "Configure"
    case .appearance, .keybindings: "Appearance"
    case .screenshot, .annotate: "Capture"
    case .maintenance: "Maintenance"
    }
  }

  var title: String {
    switch self {
    case .appearance: "Themes & backgrounds"
    case .keybindings: "Keybindings"
    case .screenshot: "Screenshot to clipboard"
    case .annotate: "Annotate screenshot"
    case .profile(let action): action.title
    case .neovim: "Neovim"
    case .configuration(let action): action.title
    case .maintenance(let action): action.title
    }
  }

  var searchText: String {
    switch self {
    case .appearance: "appearance themes backgrounds wallpaper colors picker"
    case .keybindings: "appearance keybindings shortcuts bindings help"
    case .screenshot: "capture screenshot clipboard region window image"
    case .annotate: "capture screenshot clipboard annotate annotation flameshot draw arrow"
    case .profile(let action): "configure \(action.title) edit".lowercased()
    case .neovim: "configure neovim nvim editor lua native"
    case .configuration(let action):
      "configure \(action.title) \(action.rawValue) settings edit".lowercased()
    case .maintenance(let action):
      "maintenance \(action.title) \(action.arguments.joined(separator: " "))".lowercased()
    }
  }
}

struct ActionMenuState {
  private(set) var actions = ActionMenuAction.allCases
  private(set) var selection: Int? = 0

  var selectedAction: ActionMenuAction? {
    selection.map { actions[$0] }
  }

  mutating func search(_ query: String) {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
    actions = ActionMenuAction.allCases.filter { action in
      terms.allSatisfy { action.searchText.contains($0) }
    }
    selection = actions.isEmpty ? nil : 0
  }

  mutating func move(by delta: Int) {
    guard let selection else { return }
    self.selection = min(max(selection + delta, 0), actions.count - 1)
  }

  mutating func select(row: Int) {
    selection = actions.indices.contains(row) ? row : nil
  }
}

struct ActionMenu: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "menu", abstract: "Search Macarchy actions in a native popup.")

  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  @MainActor
  mutating func run() async throws {
    let runtime = RuntimeEnvironment.live
    let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/macarchy")
    let theme = try loadPopupTheme(stateRoot: root, bundledThemesRoot: runtime.builtInThemesURL)
    let controller = try ActionMenuWindowController(theme: theme)
    let profileArguments = profiles.menuArguments
    try Self.runSession(
      showMenu: { try controller.run() },
      openViewer: { action in
        switch action {
        case .configuration(let operation):
          _ = try MenuTerminal.launch(
            .profile, arguments: ["_menu-config-edit", operation.rawValue] + profileArguments,
            theme: theme, executableURL: runtime.executableURL)
        case .neovim:
          _ = try MenuTerminal.launch(
            .profile, arguments: ["_menu-neovim-edit"] + profileArguments,
            theme: theme, executableURL: runtime.executableURL)
        case .profile(let operation):
          _ = try MenuTerminal.launch(
            .profile, arguments: ["_menu-profile-edit", operation.rawValue] + profileArguments,
            theme: theme, executableURL: runtime.executableURL)
        case .maintenance(let operation):
          _ = try MenuMaintenance.launch(
            operation, theme: theme, executableURL: runtime.executableURL,
            profileArguments: profileArguments)
        case .appearance, .keybindings, .screenshot, .annotate:
          _ = try Self.launchViewer(action, executableURL: runtime.executableURL)
        }
      },
      showFailure: { action, error in
        let alert = NSAlert()
        alert.messageText = "Could not open \(action.title)"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
      })
  }

  @MainActor
  static func runSession(
    showMenu: @MainActor () throws -> ActionMenuAction?,
    openViewer: @MainActor (ActionMenuAction) throws -> Void,
    showFailure: @MainActor (ActionMenuAction, any Error) -> Void
  ) throws {
    let action = try showMenu()
    guard let action else { return }
    do {
      // Launch synchronously before yielding to Swift's async-main executor:
      // stopping the AppKit loop can otherwise end the process at the next await.
      try openViewer(action)
    } catch {
      showFailure(action, error)
      throw error
    }
  }

  static func launchViewer(_ action: ActionMenuAction, executableURL: URL) throws -> Process {
    // Match the standalone viewer shortcuts. Use this exact binary rather than
    // PATH so development and installed menus launch their own matching version.
    let process = Process()
    process.executableURL = executableURL
    switch action {
    case .appearance: process.arguments = ["theme", "browse"]
    case .keybindings: process.arguments = ["keybindings", "show", "--effective"]
    case .screenshot: process.arguments = ["capture", "screenshot", "--alert-on-error"]
    case .annotate: process.arguments = ["capture", "annotate", "--alert-on-error"]
    case .maintenance, .profile, .neovim, .configuration:
      throw ValidationError(
        "Configuration and maintenance actions must launch through their menu terminal")
    }
    try process.run()
    return process
  }
}

@MainActor
private final class ActionMenuWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class ActionMenuTable: NSTableView {
  var openSelection: (() -> Void)?
  var moveSelection: ((Int) -> Void)?
  var beginSearch: (() -> Void)?
  var didFocus: (() -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { didFocus?() }
    return accepted
  }

  override func keyDown(with event: NSEvent) {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      super.keyDown(with: event)
      return
    }
    // These bindings exist only on the list responder, never the search editor.
    switch event.characters {
    case "j":
      moveSelection?(1)
      return
    case "k":
      moveSelection?(-1)
      return
    case "/":
      beginSearch?()
      return
    default: break
    }
    switch event.keyCode {
    case 36, 76: openSelection?()
    case 53: window?.close()
    case 125: moveSelection?(1)
    case 126: moveSelection?(-1)
    default: super.keyDown(with: event)
    }
  }
}

@MainActor
final class ActionMenuFieldEditor: NSTextView {
  override func keyDown(with event: NSEvent) {
    super.keyDown(with: event)
    // Native text editing normally hides the pointer on typing. Keep it visible
    // in this short-lived menu without changing global cursor preferences.
    NSCursor.setHiddenUntilMouseMoves(false)
  }
}

@MainActor
final class ActionMenuWindowController: NSWindowController, NSApplicationDelegate,
  NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate
{
  static let windowTitle = "Macarchy Actions"
  private let theme: NormalizedTheme
  private var state = ActionMenuState()
  private var dispatched: ActionMenuAction?
  private let search = NSSearchField()
  private let table = ActionMenuTable()
  private let notice = NSTextField(
    labelWithString: "Configure · Appearance · Capture · Maintenance")
  private let hint = NSTextField(labelWithString: "")
  private let fieldEditor = ActionMenuFieldEditor()

  init(theme: NormalizedTheme) throws {
    self.theme = theme
    let pointer = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
        ?? NSScreen.main
    else { throw KeybindingsShowError.noActiveDisplay }
    let visible = screen.visibleFrame
    let width = min(560, visible.width - 48)
    let height = min(510, visible.height - 48)
    let window = ActionMenuWindow(
      contentRect: NSRect(
        x: visible.midX - width / 2, y: visible.midY - height / 2,
        width: width, height: height),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = Self.windowTitle
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
    window.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
    super.init(window: window)
    window.delegate = self
    configure(window)
    PopupFocusBorder(accent: theme.semantic.accent.nsColor, width: 3).attach(to: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func run() throws -> ActionMenuAction? {
    let app = NSApplication.shared
    guard app.activationPolicy() == .accessory || app.setActivationPolicy(.accessory) else {
      throw KeybindingsShowError.cannotActivateAccessoryApplication
    }
    app.delegate = self
    app.finishLaunching()
    showWindow(nil)
    app.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(table)
    NSCursor.setHiddenUntilMouseMoves(false)
    app.run()
    app.delegate = nil
    return dispatched
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func windowDidResignKey(_ notification: Notification) { window?.close() }

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let client = client as? NSSearchField, client === search else { return nil }
    return fieldEditor
  }

  func windowWillClose(_ notification: Notification) {
    // Stop, not terminate: return the selection so the command can launch it.
    NSApplication.shared.stop(nil)
    if let event = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
    {
      NSApplication.shared.postEvent(event, atStart: true)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { state.actions.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: state.actions[row].title)
    let category = NSTextField(labelWithString: state.actions[row].category)
    category.font = .systemFont(ofSize: 11)
    category.textColor = theme.semantic.mutedText.nsColor
    category.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textColor =
      row == state.selection
      ? theme.semantic.background.nsColor : theme.semantic.text.nsColor
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.addSubview(category)
    cell.textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: category.leadingAnchor, constant: -12),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      category.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      category.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    PopupTableRowView(
      normalTextColor: theme.semantic.text.nsColor,
      selectedTextColor: theme.semantic.background.nsColor,
      selectedBackgroundColor: theme.semantic.accent.nsColor)
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    state.select(row: table.selectedRow)
  }

  func controlTextDidChange(_ notification: Notification) {
    state.search(search.stringValue)
    // reloadData can send selection notifications; retain the desired selection.
    let selection = state.selection
    table.reloadData()
    table.selectRowIndexes(
      selection.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
    notice.stringValue = state.actions.isEmpty ? "No matching actions" : "Appearance · Maintenance"
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    updateFocus(searching: true)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    updateFocus(searching: false)
  }

  private func updateFocus(searching: Bool) {
    search.layer?.borderColor =
      (searching ? theme.semantic.accent : theme.semantic.border).nsColor.cgColor
    search.layer?.borderWidth = searching ? 2 : 1
    hint.stringValue =
      searching
      ? "SEARCH · Type to filter   ↑↓ Select   Return Open   Esc Back"
      : "NAVIGATE · j/k or ↑↓ Select   / Search   Return Open   Esc Close"
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)): move(1)
    case #selector(NSResponder.moveUp(_:)): move(-1)
    case #selector(NSResponder.insertNewline(_:)): dispatch()
    case #selector(NSResponder.cancelOperation(_:)): window?.makeFirstResponder(table)
    default: return false
    }
    return true
  }

  private func move(_ delta: Int) {
    state.move(by: delta)
    if let selection = state.selection {
      table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
      table.scrollRowToVisible(selection)
    }
  }

  @objc private func dispatch() {
    guard let action = state.selectedAction else { return }
    dispatched = action
    window?.close()
  }

  private func configure(_ window: NSWindow) {
    window.backgroundColor = theme.semantic.background.nsColor
    let title = NSTextField(labelWithString: "Macarchy")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = theme.semantic.text.nsColor
    search.placeholderString = "/ to search actions"
    search.delegate = self
    search.textColor = theme.semantic.text.nsColor
    search.backgroundColor = theme.semantic.surface.nsColor
    search.drawsBackground = true
    search.focusRingType = .none
    search.wantsLayer = true
    search.layer?.cornerRadius = 6
    fieldEditor.isFieldEditor = true
    fieldEditor.insertionPointColor = theme.semantic.accent.nsColor
    fieldEditor.selectedTextAttributes = [
      .foregroundColor: theme.semantic.background.nsColor,
      .backgroundColor: theme.semantic.accent.nsColor,
    ]
    notice.textColor = theme.semantic.mutedText.nsColor
    let column = NSTableColumn(identifier: .init("action"))
    column.width = 500
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 44
    table.backgroundColor = theme.semantic.surface.nsColor
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.doubleAction = #selector(dispatch)
    table.openSelection = { [weak self] in self?.dispatch() }
    table.moveSelection = { [weak self] delta in self?.move(delta) }
    table.beginSearch = { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.search)
    }
    table.didFocus = { [weak self] in self?.updateFocus(searching: false) }
    table.allowsMultipleSelection = false
    table.allowsTypeSelect = false
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.backgroundColor = theme.semantic.surface.nsColor
    scroll.contentView.backgroundColor = theme.semantic.surface.nsColor
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = theme.semantic.text.nsColor
    let views: [NSView] = [title, search, notice, scroll, hint]
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    guard let root = window.contentView else { return }
    root.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
    ])
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    updateFocus(searching: false)
  }
}
