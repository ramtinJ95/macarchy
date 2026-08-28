package enum TextMateThemeArtifact {
  // These values remain compatible with existing manifests and canonical links.
  static let rendererID = "bat"
  static let rendererVersion = 1
  package static let outputPath = "generated/bat.tmTheme"
  package static let yaziOutputPath = "generated/yazi.tmTheme"
  package static let themeName = "Macarchy Current"

  static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    let ansi = package.terminal.ansi

    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>name</key>
        <string>\(themeName)</string>
        <key>semanticClass</key>
        <string>theme.\(package.appearance.rawValue).macarchy-current</string>
        <key>uuid</key>
        <string>7f833cb6-f61d-4da1-902c-018674a54d53</string>
        <key>settings</key>
        <array>
          <dict>
            <key>settings</key>
            <dict>
              <key>background</key><string>\(semantic.background.rawValue)</string>
              <key>foreground</key><string>\(semantic.text.rawValue)</string>
              <key>caret</key><string>\(package.terminal.cursor.rawValue)</string>
              <key>selection</key><string>\(semantic.selection.rawValue)80</string>
              <key>lineHighlight</key><string>\(semantic.surface.rawValue)</string>
              <key>invisibles</key><string>\(semantic.overlay.rawValue)</string>
            </dict>
          </dict>
          <dict>
            <key>name</key><string>Comments</string>
            <key>scope</key><string>comment</string>
            <key>settings</key>
            <dict>
              <key>foreground</key><string>\(semantic.mutedText.rawValue)</string>
              <key>fontStyle</key><string>italic</string>
            </dict>
          </dict>
      \(scope("Strings", "string", ansi[2]))
      \(scope("Numbers and constants", "constant.numeric, constant.language", ansi[6]))
      \(scope("Keywords", "keyword, storage.type, storage.modifier", semantic.accent))
      \(scope("Functions", "entity.name.function, support.function", ansi[4]))
      \(scope("Types", "entity.name.type, entity.name.class, support.type", semantic.info))
      \(scope("Variables", "variable, variable.other", semantic.text))
      \(scope("Parameters", "variable.parameter", semantic.warning))
      \(scope("Tags", "entity.name.tag", semantic.error))
      \(scope("Attributes", "entity.other.attribute-name", semantic.warning))
      \(scope("Invalid", "invalid, invalid.illegal", semantic.error))
        </array>
      </dict>
      </plist>

      """
  }

  private static func scope(
    _ name: String,
    _ selector: String,
    _ color: SRGBColor
  ) -> String {
    return """
          <dict>
            <key>name</key><string>\(name)</string>
            <key>scope</key><string>\(selector)</string>
            <key>settings</key>
            <dict>
              <key>foreground</key><string>\(color.rawValue)</string>
            </dict>
          </dict>
      """
  }
}
