import Foundation

public struct GeneratedThemePreview: Equatable, Sendable {
  public static let width = 720
  public static let height = 450

  public let data: Data
  public let mediaType = "image/svg+xml"

  init(data: Data) {
    self.data = data
  }
}

public struct ThemePreviewRenderer: Sendable {
  public init() {}

  public func render(package: ThemePackage) -> GeneratedThemePreview {
    let semantic = package.semantic
    let terminal = package.terminal
    let swatches = terminal.ansi.enumerated().map { index, color in
      let x = 64 + (index % 8) * 74
      let y = 354 + (index / 8) * 30
      return
        "  <rect x=\"\(x)\" y=\"\(y)\" width=\"58\" height=\"18\" rx=\"5\" fill=\"\(color.rawValue)\"/>"
    }.joined(separator: "\n")
    let svg = """
      <svg xmlns="http://www.w3.org/2000/svg" width="720" height="450" viewBox="0 0 720 450">
        <rect width="720" height="450" fill="\(semantic.background.rawValue)"/>
        <rect x="28" y="28" width="664" height="394" rx="20" fill="\(semantic.surface.rawValue)" stroke="\(semantic.border.rawValue)" stroke-width="2"/>
        <circle cx="62" cy="58" r="7" fill="\(semantic.error.rawValue)"/>
        <circle cx="84" cy="58" r="7" fill="\(semantic.warning.rawValue)"/>
        <circle cx="106" cy="58" r="7" fill="\(semantic.success.rawValue)"/>
        <rect x="52" y="88" width="176" height="232" rx="12" fill="\(semantic.overlay.rawValue)"/>
        <rect x="72" y="112" width="112" height="12" rx="6" fill="\(semantic.accent.rawValue)"/>
        <rect x="72" y="146" width="132" height="9" rx="4" fill="\(semantic.text.rawValue)"/>
        <rect x="72" y="170" width="96" height="9" rx="4" fill="\(semantic.mutedText.rawValue)"/>
        <rect x="72" y="194" width="118" height="9" rx="4" fill="\(semantic.mutedText.rawValue)"/>
        <rect x="72" y="238" width="136" height="54" rx="9" fill="\(semantic.selection.rawValue)"/>
        <rect x="254" y="88" width="414" height="232" rx="12" fill="\(terminal.background.rawValue)"/>
        <rect x="278" y="116" width="128" height="10" rx="5" fill="\(terminal.foreground.rawValue)"/>
        <rect x="278" y="140" width="300" height="28" rx="5" fill="\(terminal.selectionBackground.rawValue)"/>
        <rect x="290" y="149" width="190" height="10" rx="5" fill="\(terminal.selectionForeground.rawValue)"/>
        <rect x="278" y="188" width="216" height="10" rx="5" fill="\(semantic.info.rawValue)"/>
        <rect x="278" y="214" width="174" height="10" rx="5" fill="\(semantic.success.rawValue)"/>
        <rect x="278" y="240" width="248" height="10" rx="5" fill="\(semantic.warning.rawValue)"/>
        <rect x="278" y="266" width="192" height="10" rx="5" fill="\(semantic.error.rawValue)"/>
        <rect x="278" y="292" width="12" height="16" fill="\(terminal.cursor.rawValue)"/>
      \(swatches)
      </svg>
      """ + "\n"
    return GeneratedThemePreview(data: Data(svg.utf8))
  }
}
