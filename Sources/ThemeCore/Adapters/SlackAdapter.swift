public struct SlackAdapter: Sendable {
  public static let id = "slack"
  package static let outputPath = "generated/slack.txt"
  package static let rendererVersion = 2
  package static let importInstructions =
    "Slack: Preferences > Appearance > Custom theme > Theme colors > Import theme."

  public init() {}

  package static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    return [
      semantic.background,
      semantic.accent,
      semantic.success,
      semantic.error,
    ].map(\.rawValue).joined(separator: ",") + "\n"
  }
}
