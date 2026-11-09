import Foundation

/// One generated extension is shared by all four editors; no extension code executes.
package struct VSCodeTheme: Sendable {
  package static let packagePath = "generated/vscode/package.json"
  package static let themePath = "generated/vscode/themes/macarchy-color-theme.json"
  package static let paths = [packagePath, themePath]
  package let package: Data
  package let theme: Data
  package let version: String

  package static func render(package: ThemePackage) throws -> Self {
    try render(
      appearance: package.appearance, semantic: package.semantic, terminal: package.terminal)
  }

  package static func active(root: URL) throws -> Self {
    let manifest = try ThemeGenerationReader(root: root).activeManifest()
    let normalized = try manifest.normalizedTheme(root: root)
    let rendered = try render(
      appearance: normalized.appearance, semantic: normalized.semantic,
      terminal: normalized.terminal)
    if manifest.artifacts[packagePath] != nil || manifest.artifacts[themePath] != nil {
      // Declared artifacts must be intact, never silently repaired as legacy output.
      for (path, expected) in [(packagePath, rendered.package), (themePath, rendered.theme)] {
        guard
          try BoundedRegularFile.read(at: manifest.artifactURL(root: root, path: path)).data
            == expected
        else {
          throw GenerationIntegrityError(
            reason: "VS Code extension artifact disagrees with the active theme")
        }
      }
    }
    return rendered
  }

  static func render(
    appearance: ThemeAppearance, semantic s: SemanticColors, terminal t: TerminalColors
  ) throws -> Self {
    var colors: [String: String] = [
      "foreground": s.text.rawValue, "descriptionForeground": s.mutedText.rawValue,
      "focusBorder": s.accent.rawValue, "errorForeground": s.error.rawValue,
      "editor.background": s.background.rawValue, "editor.foreground": s.text.rawValue,
      "editor.lineHighlightBackground": s.surface.rawValue,
      "editor.selectionBackground": s.selection.rawValue,
      "editorCursor.foreground": t.cursor.rawValue,
      "editorLineNumber.foreground": s.mutedText.rawValue,
      "editorLineNumber.activeForeground": s.accent.rawValue,
      "editorError.foreground": s.error.rawValue,
      "editorWarning.foreground": s.warning.rawValue, "editorInfo.foreground": s.info.rawValue,
      "activityBar.background": s.surface.rawValue, "activityBar.foreground": s.text.rawValue,
      "sideBar.background": s.surface.rawValue, "sideBar.foreground": s.text.rawValue,
      "panel.background": s.surface.rawValue, "panel.border": s.border.rawValue,
      "statusBar.background": s.surface.rawValue, "statusBar.foreground": s.text.rawValue,
      "statusBar.noFolderBackground": s.surface.rawValue,
      "titleBar.activeBackground": s.surface.rawValue, "titleBar.activeForeground": s.text.rawValue,
      "titleBar.inactiveBackground": s.surface.rawValue,
      "editorGroupHeader.tabsBackground": s.surface.rawValue,
      "tab.activeBackground": s.background.rawValue, "tab.activeForeground": s.text.rawValue,
      "tab.inactiveBackground": s.surface.rawValue, "tab.inactiveForeground": s.mutedText.rawValue,
      "input.background": s.overlay.rawValue, "input.foreground": s.text.rawValue,
      "input.border": s.border.rawValue, "button.background": s.accent.rawValue,
      "button.foreground": s.background.rawValue,
      "list.activeSelectionBackground": s.selection.rawValue,
      "list.hoverBackground": s.overlay.rawValue,
      "gitDecoration.addedResourceForeground": s.success.rawValue,
      "gitDecoration.modifiedResourceForeground": s.warning.rawValue,
      "gitDecoration.deletedResourceForeground": s.error.rawValue,
      "terminal.background": t.background.rawValue, "terminal.foreground": t.foreground.rawValue,
      "terminalCursor.foreground": t.cursor.rawValue,
      "terminal.selectionBackground": s.selection.rawValue,
    ]
    let hues = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    for (index, color) in t.ansi.enumerated() {
      colors["terminal.ansi\(index < 8 ? "" : "Bright")\(hues[index % 8])"] = color.rawValue
    }
    let scopes = [
      ("comment", s.mutedText.rawValue), ("string", t.ansi[2].rawValue),
      ("keyword, storage", t.ansi[5].rawValue), ("entity.name.function", t.ansi[4].rawValue),
      ("entity.name.type, support.type", t.ansi[3].rawValue),
      ("constant.numeric", t.ansi[6].rawValue),
      ("constant.language", t.ansi[1].rawValue), ("variable", s.text.rawValue),
    ]
    let theme = try json([
      "name": "Macarchy", "type": appearance.rawValue, "colors": colors,
      "tokenColors": scopes.map {
        ["scope": $0.0, "settings": ["foreground": $0.1]] as [String: Any]
      },
    ])
    let version = "1.0.\(UInt32(sha256Digest(theme).prefix(8), radix: 16)!)"
    let package = try json([
      "name": "macarchy-theme", "publisher": "macarchy", "displayName": "Macarchy",
      "version": version, "engines": ["vscode": "^1.50.0"], "categories": ["Themes"],
      "contributes": [
        "themes": [
          [
            "id": "Macarchy", "label": "Macarchy",
            "uiTheme": appearance == .dark ? "vs-dark" : "vs",
            "path": "./themes/macarchy-color-theme.json",
          ]
        ]
      ],
    ])
    return Self(package: package, theme: theme, version: version)
  }

  private static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      + Data("\n".utf8)
  }

  package var outputs: [ConsumerRenderedOutput] {
    [.init(path: Self.packagePath, data: package), .init(path: Self.themePath, data: theme)]
  }
}
