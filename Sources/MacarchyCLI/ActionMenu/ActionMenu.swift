import AppKit
import ArgumentParser
import Foundation
import ThemeCore

/// One menu row: its group, what it is called and searched by, and the command it starts.
/// Adding an action is one declaration here plus its place in `allCases`, the menu order.
struct ActionMenuAction: CaseIterable, Equatable, Sendable {
  enum Command: Equatable, Sendable {
    /// A standalone viewer, launched detached with its keyboard shortcut's arguments.
    case viewer([String])
    /// A hidden menu command, run in a menu terminal with the selected profiles appended.
    case terminal(MenuTerminal.Kind, [String])

    /// A viewer that shows its failure in an alert, since a menu launch has no terminal.
    static func alertingViewer(_ arguments: [String]) -> Self {
      .viewer(arguments + [MacarchyInvocation.alertOnError])
    }
  }

  let category: String
  let title: String
  let searchText: String
  let command: Command

  static var allCases: [Self] {
    ProfileEditAction.allCases.map(Self.profile)
      + [.neovim] + MenuConfigurationAction.allCases.map(Self.configuration)
      + [
        .appearance, .undoTheme, .keybindings, .screenshot, .annotate, .ocr, .prepareImage,
        .clipboardHistory, .clearClipboardHistory, .keepAwake, .startScreensaver,
        .toggleIdleScreensaver, .toggleScreensaverPause, .chooseMicrophone, .toggleMicrophone,
      ]
      + MaintenanceAction.allCases.map(Self.maintenance)
  }

  static func profile(_ action: ProfileEditAction) -> Self {
    Self(
      category: "Configure", title: action.title,
      searchText: "configure \(action.title) edit".lowercased(),
      command: .terminal(.profile, [MenuProfileEditor.commandName, action.rawValue]))
  }

  static let neovim = Self(
    category: "Configure", title: "Neovim",
    searchText: "configure neovim nvim editor lua native",
    command: .terminal(.profile, [MenuNeovimEditor.commandName]))

  static func configuration(_ action: MenuConfigurationAction) -> Self {
    Self(
      category: "Configure", title: action.title,
      searchText: "configure \(action.title) \(action.rawValue) settings edit".lowercased(),
      command: .terminal(.profile, [MenuConfigurationEditor.commandName, action.rawValue]))
  }

  static let appearance = Self(
    category: "Appearance", title: "Themes & backgrounds",
    searchText: "appearance themes backgrounds wallpaper colors picker",
    command: .viewer(MacarchyInvocation.themeBrowse))

  static let undoTheme = Self(
    category: "Appearance", title: "Undo last theme change",
    searchText: "appearance undo revert previous theme background",
    command: .alertingViewer(MacarchyInvocation.themeUndo))

  static let keybindings = Self(
    category: "Appearance", title: "Keybindings",
    searchText: "appearance keybindings shortcuts bindings help",
    command: .viewer(MacarchyInvocation.keybindingsShowEffective))

  static let screenshot = Self(
    category: "Capture", title: "Screenshot to clipboard",
    searchText: "capture screenshot clipboard region window image",
    command: .alertingViewer(MacarchyInvocation.captureScreenshot))

  static let annotate = Self(
    category: "Capture", title: "Annotate screenshot",
    searchText: "capture screenshot clipboard annotate annotation flameshot draw arrow",
    command: .alertingViewer(MacarchyInvocation.captureAnnotate))

  static let ocr = Self(
    category: "Capture", title: "Copy text from region",
    searchText: "capture text region ocr recognize clipboard english",
    command: .alertingViewer(MacarchyInvocation.captureOCR))

  static let prepareImage = Self(
    category: "Capture", title: "Prepare an image",
    searchText:
      "capture image prepare convert compress resize jpeg png share small metadata strip",
    command: .alertingViewer(MacarchyInvocation.imageChoose))

  static let clipboardHistory = Self(
    category: "Clipboard", title: "Clipboard history",
    searchText: "clipboard history maccy paste copy open recall",
    command: .alertingViewer(MacarchyInvocation.clipboardOpen))

  static let clearClipboardHistory = Self(
    category: "Clipboard", title: "Clear clipboard history",
    searchText: "clipboard clear history maccy paste copy wipe delete pinned secret password",
    command: .alertingViewer(MacarchyInvocation.clipboardClearConfirmed))

  static let keepAwake = Self(
    category: "Controls", title: "Toggle keep-awake",
    searchText:
      "controls toggle keep awake keep-awake caffeinate sleep display idle always on screensaver lock",
    command: .alertingViewer(MacarchyInvocation.keepAwakeToggle))

  static let startScreensaver = Self(
    category: "Controls", title: "Start screensaver",
    searchText:
      "controls start screensaver saver ttfx animation animated text fullscreen idle away",
    command: .alertingViewer(MacarchyInvocation.saverStart))

  static let toggleIdleScreensaver = Self(
    category: "Controls", title: "Toggle idle screensaver",
    searchText: "controls toggle idle screensaver saver away activation timeout",
    command: .alertingViewer(MacarchyInvocation.saverIdleToggle))

  static let toggleScreensaverPause = Self(
    category: "Controls", title: "Toggle screensaver pause",
    searchText: "controls toggle screensaver saver pause resume idle away lock",
    command: .alertingViewer(MacarchyInvocation.saverTogglePause))

  static let chooseMicrophone = Self(
    category: "Controls", title: "Choose microphone",
    searchText: "controls choose select microphone mic input device default audio",
    command: .alertingViewer(MacarchyInvocation.microphoneChoose))

  static let toggleMicrophone = Self(
    category: "Controls", title: "Toggle microphone mute",
    searchText: "controls toggle microphone mic mute unmute silence input privacy",
    command: .alertingViewer(MacarchyInvocation.microphoneToggle))

  static func maintenance(_ action: MaintenanceAction) -> Self {
    Self(
      category: "Maintenance", title: action.title,
      searchText:
        "maintenance \(action.title) \(action.arguments.joined(separator: " "))".lowercased(),
      command: .terminal(.maintenance, [MenuMaintenance.commandName, action.rawValue]))
  }
}

struct ActionMenuState {
  private(set) var actions = ActionMenuAction.allCases
  private(set) var selection: Int? = 0

  private static let categories: String = {
    var seen = Set<String>()
    return ActionMenuAction.allCases.map(\.category).filter { seen.insert($0).inserted }
      .joined(separator: " · ")
  }()

  var selectedAction: ActionMenuAction? {
    selection.map { actions[$0] }
  }

  var notice: String {
    actions.isEmpty ? "No matching actions" : Self.categories
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
    let root = StateLayout.defaultRoot(in: FileManager.default.homeDirectoryForCurrentUser)
    let theme = try loadPopupTheme(stateRoot: root, bundledThemesRoot: runtime.builtInThemesURL)
    let controller = try ActionMenuWindowController(theme: theme)
    let profileArguments = profiles.menuArguments
    try Self.runSession(
      showMenu: { try controller.run() },
      openViewer: { action in
        switch action.command {
        case .terminal(let kind, let arguments):
          _ = try MenuTerminal.launch(
            kind, arguments: arguments + profileArguments, theme: theme,
            executableURL: runtime.executableURL)
        case .viewer:
          _ = try Self.launchViewer(action, executableURL: runtime.executableURL)
        }
      },
      showFailure: { action, error in
        showNativeAlert(title: "Could not open \(action.title)", message: String(describing: error))
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
    guard case .viewer(let arguments) = action.command else {
      throw ValidationError(
        "Configuration and maintenance actions must launch through their menu terminal")
    }
    return try launchDetachedProcess(executableURL, arguments: arguments)
  }
}

enum ActionMenuError: Error, CustomStringConvertible, Sendable {
  case cannotActivateAccessoryApplication
  case noActiveDisplay

  var description: String {
    switch self {
    case .cannotActivateAccessoryApplication:
      "Cannot run the action menu as an accessory application"
    case .noActiveDisplay:
      "Cannot show the action menu without an active display"
    }
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
  private let notice = NSTextField(labelWithString: ActionMenuState().notice)
  private let hint = NSTextField(labelWithString: "")
  private let fieldEditor = ActionMenuFieldEditor()

  init(theme: NormalizedTheme) throws {
    self.theme = theme
    guard let screen = popupActiveScreen() else { throw ActionMenuError.noActiveDisplay }
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
    try runAccessoryPopup(
      self, focusing: table, cannotActivate: ActionMenuError.cannotActivateAccessoryApplication,
      beforeRun: { NSCursor.setHiddenUntilMouseMoves(false) })
    NSApplication.shared.delegate = nil
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
    notice.stringValue = state.notice
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
    fieldEditor.allowsUndo = true
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
