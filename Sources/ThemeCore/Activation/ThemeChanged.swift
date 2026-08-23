public struct ThemeChanged: Sendable {
  public static let darwinNotificationName =
    "io.github.ramtinj95.macarchy.theme-changed"

  public let generationID: String
  public let themeID: String

  init(manifest: GenerationManifest) {
    generationID = manifest.generationID
    themeID = manifest.themeID
  }
}
