import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SketchyBarModuleDependencyTests {
  @Test func mediaRequiresItsPackageOnlyWhenSelectedByEffectiveLayout() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-module-dependencies-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Desktop/sketchybar/defaults.toml")
    let defaults = root.appending(path: "defaults.toml")
    let text = try String(contentsOf: source, encoding: .utf8)
      .replacingOccurrences(of: #"(?m)^left = .*$"#, with: "left = []", options: .regularExpression)
      .replacingOccurrences(
        of: #"(?m)^center = .*$"#, with: "center = []", options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?m)^right = .*$"#, with: "right = [\"clock\", \"media\", \"apple\", \"toggle\"]",
        options: .regularExpression)
    try text.write(to: defaults, atomically: true, encoding: .utf8)
    let dependencies = DependencyProfile.personal(homeDirectory: root)
    for (override, expected) in [
      ("", true), ("[sketchybar]\nright = []\n", false),
      ("[top_bar]\nprovider = \"disabled\"\n", false),
    ] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n" + override, source: root.appending(path: "profile.toml"))
      let capabilities = try dependencies.selectedForSetup(profile, defaultsURL: defaults)
      #expect(capabilities.contains { $0.id == "nowplaying-cli" } == expected)
      #expect(capabilities.contains { $0.id == "apple-menu-helper" } == expected)
      #expect(capabilities.contains { $0.id == "native-menu-toggle" } == expected)
      if expected {
        let requirement = try #require(capabilities.first { $0.id == "nowplaying-cli" })
        #expect(requirement.remediation.homebrewPackage?.name == "nowplaying-cli")
        let helper = try #require(capabilities.first { $0.id == "apple-menu-helper" })
        #expect(helper.remediation.homebrewPackage == nil)
        #expect(helper.requirement.contains("manual Accessibility"))
      }
    }
  }
}
