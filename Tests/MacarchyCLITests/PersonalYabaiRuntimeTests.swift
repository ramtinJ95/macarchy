import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PersonalYabaiRuntimeTests {
  @Test(arguments: ["personal", "no-completion", "no-wallpaper", "accessibility", "managed"])
  func nativeInspectionSeparatesBehaviorFromIntegration(condition: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "yabai-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# personal\n".write(
      to: root.appending(path: "personal.sh"), atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      condition == "managed"
        ? "schema_version = 1\n"
        : "schema_version = 1\n[yabai]\nconfiguration = \"personal.sh\"\n",
      source: root.appending(path: "profile.toml"))
    let defaults = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Desktop/yabai/defaults.toml")
    let composition = try YabaiConfigurationComposer().compose(
      defaultsURL: defaults, profile: profile)
    let inspection = YabaiLifecycleController.inspectRuntime(
      composition,
      processEvidence: { (7, "/opt/homebrew/Cellar/yabai/7.1.25/bin/yabai") },
      accessibility: {
        if condition == "accessibility" { throw CocoaError(.fileReadNoPermission) }
      },
      query: { arguments in
        switch arguments {
        case ["-m", "rule", "--list"]:
          return .init(terminationStatus: 0, output: "[]")
        case ["-m", "signal", "--list"]:
          var signals: [[String: String]] = []
          if condition != "no-completion", let completion = composition.nativeReadyLabel {
            signals.append(["label": completion, "event": "application_launched", "action": "true"])
          }
          if condition != "no-wallpaper" {
            signals.append([
              "label": "macarchy-wallpaper", "event": "space_changed",
              "action": "macarchy reconcile wallpaper",
            ])
          }
          return .init(
            terminationStatus: 0,
            output: String(decoding: try JSONEncoder().encode(signals), as: UTF8.self))
        default:
          return .init(terminationStatus: 0, output: "personal setting")
        }
      })
    switch condition {
    case "personal":
      #expect(inspection.status == .partial)
      #expect(inspection.verifiedSettings.isEmpty && inspection.verifiedRuleLabels.isEmpty)
      #expect(inspection.wallpaperSignalVerified && inspection.processID == 7)
    case "accessibility": #expect(inspection.status == .blocked)
    default: #expect(inspection.status == .drifted)
    }
  }
}
