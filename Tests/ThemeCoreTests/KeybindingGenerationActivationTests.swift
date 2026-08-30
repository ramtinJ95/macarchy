import Foundation
import Testing

@testable import ThemeCore

struct KeybindingGenerationActivationTests {
  @Test
  func stagesSealsSelectsAndRollsBackAFirstGeneration() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let composition = try composition()
    let activator = KeybindingGenerationActivator(stateRoot: root)

    let staged = try activator.stage(composition)
    #expect(KeybindingGenerationInspector().inspect(stateRoot: root).status == .missing)
    try activator.select(staged)

    let current = KeybindingGenerationInspector().inspect(stateRoot: root)
    #expect(current.status == .current)
    #expect(current.generationID == staged.manifest.generationID)
    #expect(current.inputDigest == composition.inputDigest)
    #expect(current.renderedDigest == composition.renderedDigest)

    try activator.restoreCurrent(generationID: nil)
    #expect(KeybindingGenerationInspector().inspect(stateRoot: root).status == .missing)
    try activator.removeGeneration(staged.manifest.generationID)
    #expect(!FileManager.default.fileExists(atPath: staged.generationURL.path))
  }

  @Test
  func pointerFailureLeavesAValidUnselectedGenerationAndNoTemporaryPointer() throws {
    struct Injected: Error {}
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let activator = KeybindingGenerationActivator(
      stateRoot: root,
      faultInjector: { checkpoint in
        if checkpoint == .currentReady { throw Injected() }
      }
    )
    let staged = try activator.stage(try composition())

    #expect(throws: Injected.self) {
      try activator.select(staged)
    }
    #expect(KeybindingGenerationInspector().inspect(stateRoot: root).status == .missing)
    let keybindings = root.appending(path: "keybindings", directoryHint: .isDirectory)
    let inventory = try FileManager.default.contentsOfDirectory(atPath: keybindings.path)
    #expect(inventory == ["generations"])
  }

  private func composition() throws -> KeybindingComposition {
    let metadata = try SkhdKeybindingCatalogLoader().decode(
      """
      schema_version = 1
      [[bindings]]
      identity = "alt-j"
      label = "Focus below"
      category = "Test"
      order = 1
      """,
      source: URL(filePath: "/package/metadata.toml")
    )
    return KeybindingComposer().compose(
      defaultsText: "alt - j : focus south\n",
      defaultsSource: URL(filePath: "/package/defaults.skhdrc"),
      defaultCatalog: metadata,
      defaultMetadataSource: URL(filePath: "/package/metadata.toml"),
      profile: .empty,
      overrideText: nil,
      userCatalog: nil
    )
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-generation-activation-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
