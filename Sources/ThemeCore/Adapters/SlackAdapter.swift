public struct SlackAdapter: Sendable {
  public static let id = "slack"
  package static let outputPath = "generated/slack.txt"
  package static let rendererVersion = 1
  package static let importInstructions =
    "Slack: Preferences > Appearance > Custom theme > Theme colors > Import theme."

  public init() {}

  package static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    let terminal = package.terminal
    return [
      semantic.background,
      semantic.surface,
      semantic.accent,
      terminal.selectionForeground,
      semantic.overlay,
      semantic.text,
      semantic.success,
      semantic.error,
      semantic.surface,
      semantic.text,
    ].map(\.rawValue).joined(separator: ",") + "\n"
  }
}
