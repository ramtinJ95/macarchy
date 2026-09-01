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
  func sharedPortableProfileAcceptsTypedDesktopAndTopBarSelections() throws {
    let source = URL(filePath: "/fixtures/profile.toml")
    let text = """
      schema_version = 1
      [keybindings]
      disabled = ["alt-k"]
      [desktop]
      provider = "yabai-skhd"
      [yabai]
      layout = "stack"
      window_gap = 9
      [top_bar]
      provider = "disabled"
      [sketchybar]
      left = ["clock", "spaces"]
      right = []
      hook = "sketchybar.sh"
      """

    let portable = try PortableProfileLoader().decode(text, source: source)
    let keybindings = try loader.decode(text, source: source)

    #expect(portable.desktop.provider == .yabaiSkhd)
    #expect(portable.desktop.yabai.layout == "stack")
    #expect(portable.desktop.yabai.windowGap == 9)
    #expect(portable.topBar == .disabled)
    #expect(portable.sketchyBar.left == [.clock, .spaces])
    #expect(portable.sketchyBar.right == [])
    #expect(portable.sketchyBar.hookURL == URL(filePath: "/fixtures/sketchybar.sh"))
    #expect(keybindings.disabledIdentities == ["alt-k"])
  }

  @Test
  func rejectsUnknownProvidersAndUnsafeYabaiControls() {
    let source = URL(filePath: "/fixtures/profile.toml")
    let invalid: [(String, String)] = [
      (
        "schema_version = 1\n[desktop]\nprovider = \"arbitrary-command\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[yabai]\nsplit_ratio = 1.0\n",
        "must be between 0.1 and 0.9"
      ),
      (
        "schema_version = 1\n[yabai]\nhook = \"/tmp/yabairc\"\n",
        "must be a relative path"
      ),
      (
        "schema_version = 1\n[top_bar]\nprovider = \"custom\"\n",
        "unsupported provider"
      ),
      (
        "schema_version = 1\n[sketchybar]\nleft = [\"clock\", \"clock\"]\n",
        "module must be unique"
      ),
      (
        "schema_version = 1\n[sketchybar]\nright = [\"weather\"]\n",
        "weather"
      ),
      (
        "schema_version = 1\n[sketchybar]\nhook = \"/tmp/sketchybar.sh\"\n",
        "must be a relative path"
      ),
    ]

    for (document, expected) in invalid {
      do {
        _ = try PortableProfileLoader().decode(document, source: source)
        Issue.record("Expected invalid profile: \(expected)")
      } catch {
        #expect(String(describing: error).contains(expected))
      }
    }
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
