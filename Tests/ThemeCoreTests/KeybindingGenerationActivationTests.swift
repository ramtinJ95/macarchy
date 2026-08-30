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

  @Test
  func startupRecoveryRemovesOnlyValidatedStagingAndPointerResidue() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let keybindings = root.appending(path: "keybindings", directoryHint: .isDirectory)
    let generations = keybindings.appending(path: "generations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true)
    let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"
    let staging = generations.appending(
      path: ".staging-\(generationID)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try Data("partial".utf8).write(to: staging.appending(path: "skhdrc"))
    let pointer = ".current-\(generationID)-11111111-2222-3333-4444-555555555555"
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: pointer).path,
      withDestinationPath: "generations/\(generationID)"
    )

    try KeybindingGenerationActivator(stateRoot: root).recoverResidue()

    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(!FileManager.default.fileExists(atPath: keybindings.appending(path: pointer).path))
  }

  @Test
  func retentionRefusesUnknownInventoryWithoutDeletingKnownArtifacts() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let activator = KeybindingGenerationActivator(stateRoot: root)
    let first = try activator.stage(try composition())
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: first.generationURL.path
      )
    }
    let second = try activator.stage(try composition())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: first.generationURL.path
    )
    try Data("unknown".utf8).write(to: first.generationURL.appending(path: "unknown.txt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: first.generationURL.path
    )

    #expect(throws: KeybindingGenerationActivationError.self) {
      try activator.retainGenerations([second.manifest.generationID])
    }
    #expect(
      FileManager.default.fileExists(
        atPath: first.generationURL.appending(path: "manifest.json").path))
    #expect(
      FileManager.default.fileExists(atPath: first.generationURL.appending(path: "skhdrc").path))
  }

  @Test
  func removingAnAlreadyAbsentOwnedGenerationIsIdempotent() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let activator = KeybindingGenerationActivator(stateRoot: root)
    let staged = try activator.stage(try composition())
    try activator.removeGeneration(staged.manifest.generationID)

    try activator.removeGeneration(staged.manifest.generationID)
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
