import Foundation
import Testing

@testable import ThemeCore

struct YabaiGenerationTests {
  @Test
  func publishesSelectsReusesAndValidatesCanonicalGeneration() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-yabai-generation-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    let composition = try YabaiConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile
    )
    let activator = YabaiGenerationActivator(stateRoot: root)

    let prepared = try activator.prepare(composition)
    #expect(prepared.created)
    try activator.select(prepared)

    let inspection = YabaiGenerationInspector(stateRoot: root).inspect()
    #expect(inspection.status == .current)
    #expect(inspection.generationID == prepared.manifest.generationID)
    #expect(inspection.manifest?.inputDigest == composition.inputDigest)
    #expect(inspection.manifest?.renderedDigest == composition.renderedDigest)

    let reused = try activator.prepare(composition)
    #expect(!reused.created)
    #expect(reused.manifest.generationID == prepared.manifest.generationID)
  }

  @Test
  func renderedArtifactDriftInvalidatesCurrentGeneration() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-yabai-generation-drift-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    let composition = try YabaiConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile
    )
    let activator = YabaiGenerationActivator(stateRoot: root)
    let prepared = try activator.prepare(composition)
    try activator.select(prepared)
    let configuration = root.appending(
      path: "desktop/yabai/generations/\(prepared.manifest.generationID)/yabairc"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: configuration.path)
    try Data("drift\n".utf8).write(to: configuration)

    #expect(YabaiGenerationInspector(stateRoot: root).inspect().status == .invalid)
  }

  private var defaultsURL: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Desktop/yabai/defaults.toml")
  }
}
