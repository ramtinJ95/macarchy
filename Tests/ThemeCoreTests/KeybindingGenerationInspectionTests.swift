import Foundation
import Testing

@testable import ThemeCore

struct KeybindingGenerationInspectionTests {
  private let inspector = KeybindingGenerationInspector()
  private let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"

  @Test
  func missingStateIsExplicit() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(inspector.inspect(stateRoot: root) == .missing)
  }

  @Test
  func validatesCurrentManifestIdentityPermissionsAndArtifactDigest() throws {
    let root = try temporaryDirectory()
    let generation = try publishFixture(
      stateRoot: root,
      expectedConfiguration: "alt - j : default\n",
      actualConfiguration: "alt - j : default\n"
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: generation.path
      )
      try? FileManager.default.removeItem(at: root)
    }

    let inspection = inspector.inspect(stateRoot: root)

    #expect(inspection.status == .current)
    #expect(inspection.generationID == generationID)
    #expect(
      inspection.renderedDigest
        == sha256Digest(Data("alt - j : default\n".utf8))
    )
  }

  @Test
  func corruptCurrentArtifactBlocksInspection() throws {
    let root = try temporaryDirectory()
    let generation = try publishFixture(
      stateRoot: root,
      expectedConfiguration: "alt - j : default\n",
      actualConfiguration: "alt - j : drifted\n"
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: generation.path
      )
      try? FileManager.default.removeItem(at: root)
    }

    let inspection = inspector.inspect(stateRoot: root)

    #expect(inspection.status == .invalid)
    #expect(inspection.message?.contains("digest does not match") == true)
  }

  @Test
  func symlinkedKeybindingStateAncestorIsInvalid() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    let external = root.appending(path: "external/keybindings", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: stateRoot.appending(path: "keybindings", directoryHint: .isDirectory),
      withDestinationURL: external
    )

    let inspection = inspector.inspect(stateRoot: stateRoot)

    #expect(inspection.status == .invalid)
    #expect(inspection.message?.contains("pinned keybinding state") == true)
  }

  private func publishFixture(
    stateRoot: URL,
    expectedConfiguration: String,
    actualConfiguration: String
  ) throws -> URL {
    let keybindings = stateRoot.appending(
      path: "keybindings",
      directoryHint: .isDirectory
    )
    let generation = keybindings.appending(
      path: "generations/\(generationID)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    let expectedDigest = sha256Digest(Data(expectedConfiguration.utf8))
    let manifest = KeybindingGenerationManifest(
      generationID: generationID,
      inputDigest: sha256Digest(Data("input".utf8)),
      renderedDigest: expectedDigest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: generation.appending(path: "manifest.json"))
    try Data(actualConfiguration.utf8).write(to: generation.appending(path: "skhdrc"))
    for file in ["manifest.json", "skhdrc"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: generation.appending(path: file).path
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: generation.path
    )
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
    return generation
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-generation-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
