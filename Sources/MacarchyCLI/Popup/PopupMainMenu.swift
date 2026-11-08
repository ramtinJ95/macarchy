import AppKit

// Accessory popups never show a menu bar, but AppKit still resolves Command key
// equivalents through the main menu. Without these items, Command-A, C, V, X
// and Z never reach the search field's editor.
@MainActor
func popupMainMenu() -> NSMenu {
  let edit = NSMenu(title: "Edit")
  for (title, action, key) in [
    ("Undo", Selector(("undo:")), "z"),
    ("Redo", Selector(("redo:")), "Z"),
    ("Cut", #selector(NSText.cut(_:)), "x"),
    ("Copy", #selector(NSText.copy(_:)), "c"),
    ("Paste", #selector(NSText.paste(_:)), "v"),
    ("Select All", #selector(NSText.selectAll(_:)), "a"),
  ] {
    edit.addItem(withTitle: title, action: action, keyEquivalent: key)
  }
  let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
  editItem.submenu = edit
  let main = NSMenu()
  main.addItem(editItem)
  return main
}
