import Foundation
import Testing

@testable import ThemeCore

struct KeybindingProfileTests {
  private let loader = KeybindingProfileLoader()

  @Test
  func absentDefaultIsEmptyButAbsentExplicitProfileFails() throws {
    let missing = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-missing-profile-\(UUID().uuidString).toml"
    )

    #expect(try loader.load(at: missing, required: false) == .empty)
    #expect(throws: KeybindingProfileError.self) {
      _ = try loader.load(at: missing, required: true)
    }
  }

  @Test
  func relativeInputsResolveBesideTheResolvedProfileSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    let exposedDirectory = root.appending(
      path: "home/.config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exposedDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appending(path: "profile.toml")
    try """
    schema_version = 1
    [keybindings]
    override = "personal.skhdrc"
    metadata = "personal-metadata.toml"
    disabled = ["alt-k"]
    """.write(to: source, atomically: true, encoding: .utf8)
    let exposed = exposedDirectory.appending(path: "profile.toml")
    try FileManager.default.createSymbolicLink(at: exposed, withDestinationURL: source)

    let profile = try loader.load(at: exposed, required: true)

    #expect(profile.sourceURL == exposed.standardizedFileURL)
    #expect(profile.overrideURL == sourceDirectory.appending(path: "personal.skhdrc"))
    #expect(profile.metadataURL == sourceDirectory.appending(path: "personal-metadata.toml"))
    #expect(profile.disabledIdentities == ["alt-k"])
  }

  @Test
  func rejectsUnknownFieldsUnsafePathsAndInvalidDisabledIdentities() {
    let source = URL(filePath: "/fixtures/profile.toml")
    let invalid: [(String, String)] = [
      (
        "schema_version = 1\n[keybindings]\ncommand = \"open Calculator\"\n",
        "unknown key 'keybindings.command'"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"/tmp/skhdrc\"\n",
        "must be a relative path"
      ),
      (
        "schema_version = 1\n[keybindings]\noverride = \"../skhdrc\"\n",
        "must stay beside the profile"
      ),
      (
        "schema_version = 1\n[keybindings]\ndisabled = [\"shift+alt-j\"]\n",
        "is not a normalized skhd chord"
      ),
      (
        "schema_version = 1\n[keybindings]\ndisabled = [\"alt-j\", \"alt-j\"]\n",
        "must be unique"
      ),
    ]

    for (document, expected) in invalid {
      do {
        _ = try loader.decode(document, source: source)
        Issue.record("Expected invalid profile: \(expected)")
      } catch {
        #expect(String(describing: error).contains(expected))
      }
    }
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-profile-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
