import Foundation

public enum SlackAdapter: Sendable {
  public static let id = "slack"
  package static let outputPath = "generated/slack.txt"
  package static let rendererVersion = 2
  package static let minimumVersion = "4.51.191"
  package static let liveBundleURL = URL(filePath: "/Applications/Slack.app")
  package static let importInstructions =
    "Slack: Preferences > Appearance > Custom theme > Theme colors > Import theme."

  package static func render(package: ThemePackage) -> String {
    let semantic = package.semantic
    return [
      semantic.background,
      semantic.accent,
      semantic.success,
      semantic.error,
    ].map(\.rawValue).joined(separator: ",") + "\n"
  }

  package static func isValidRendererV2Payload(_ payload: String) -> Bool {
    let value = payload.hasSuffix("\n") ? String(payload.dropLast()) : payload
    let colors = value.split(separator: ",", omittingEmptySubsequences: false)
    return colors.count == 4
      && colors.allSatisfy { color in
        color.count == 7 && color.first == "#"
          && color.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
      }
  }
}
