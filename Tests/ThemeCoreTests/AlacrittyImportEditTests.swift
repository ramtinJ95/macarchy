import Foundation
import TOMLDecoder
import Testing

@testable import ThemeCore

struct AlacrittyImportEditTests {
  @Test func introducedTableWithNewUserSettingsCannotBeRemoved() throws {
    let source = Data("[font]\nsize = 12\n".utf8)
    let edit = try AlacrittyImportEdit.adopting(source, themePath: "/theme")
    let managed = try edit.apply(to: source) + Data("live_config_reload = false\n".utf8)
    try edit.validateManaged(managed)
    #expect(throws: AlacrittyImportEdit.Failure.tableInUse) { try edit.restore(managed) }
  }
  @Test(arguments: [
    "", "# keep\n", "# keep\n\n\n", "[font]\nsize = 14\n",
    "[general] # keep\n[font]\nsize = 14\n", "[general]",
    "[general]\nimport = [] # keep\n", "[general]\nimport = [ 'user.toml' ]\n",
    "[general]\nimport = [\"user.toml\", ] # keep\n",
    "[general]\nimport = [\n  # before\n  'user.toml' # after\n]\n",
    "[general]\nimport = [\n  'user.toml', # after\n  # closing\n]\n[font]\nsize = 12\n",
    "[general]\r\nimport = [\r\n\t'user.toml',\r\n]\r\n",
    "[general]\nimport = [\n# empty\n]\n",
    "[general]\nimport = [\n'user.toml']\n",
    "[general]\nimport = [\"file#with]comma,.toml\", 'other.toml']\n",
  ])
  func arrayEditsRestoreByteForByte(original: String) throws {
    let data = Data(original.utf8)
    let edit = try AlacrittyImportEdit.adopting(data, themePath: "/home/test/state/theme.toml")
    let managed = try edit.apply(to: data)
    #expect(try edit.restore(managed) == data)
    #expect(
      try AlacrittyImportEdit.imports(String(decoding: managed, as: UTF8.self)).last
        == edit.themePath)
    #expect(edit.hasValidShape)
  }

  @Test func arrayStyleAndCommentsArePreserved() throws {
    let input = "[general]\nimport = [\n  'first.toml' # keep\n]\n"
    let edit = try AlacrittyImportEdit.adopting(Data(input.utf8), themePath: "/theme")
    #expect(
      String(decoding: try edit.apply(to: Data(input.utf8)), as: UTF8.self)
        == "[general]\nimport = [\n  'first.toml', # keep\n  \"/theme\"\n]\n")
    let single = "[general]\nimport = ['first.toml', ] # keep\n"
    let one = try AlacrittyImportEdit.adopting(Data(single.utf8), themePath: "/theme")
    #expect(
      String(decoding: try one.apply(to: Data(single.utf8)), as: UTF8.self)
        == "[general]\nimport = ['first.toml', \"/theme\", ] # keep\n")
  }

  @Test(arguments: [
    "general.import = []\n", "general = { import = [] }\n",
    "import = []\n[general]\n", "[general]\nimport = 'wrong'\n",
    "[general]\nimport = [1]\n", "[general]\nimport = ['/theme']\n",
    "[general]\nimport = []\nimport = []\n", "[general]\nimport = [true]\n",
  ])
  func unsafeShapesRefuseWithoutEditing(text: String) {
    #expect(throws: AlacrittyImportEdit.Failure.self) {
      try AlacrittyImportEdit.adopting(Data(text.utf8), themePath: "/theme")
    }
  }

  @Test(arguments: ["edit", "move", "remove", "duplicate"])
  func ownedElementDriftIsNotRestored(kind: String) throws {
    let data = Data("[general]\nimport = ['user']\n".utf8)
    let edit = try AlacrittyImportEdit.adopting(data, themePath: "/theme")
    let managed = String(decoding: try edit.apply(to: data), as: UTF8.self)
    let changed: String
    switch kind {
    case "edit": changed = managed.replacingOccurrences(of: "/theme", with: "/other")
    case "move": changed = "\n" + managed
    case "remove": changed = String(decoding: data, as: UTF8.self)
    default:
      changed = managed.replacingOccurrences(of: "\"/theme\"", with: "\"/theme\", \"/theme\"")
    }
    #expect(throws: (any Error).self) { try edit.restore(Data(changed.utf8)) }
  }

  @Test func laterUserImportIsPreservedOnRestore() throws {
    let source = Data("[general]\nimport = ['first']\n".utf8)
    let edit = try AlacrittyImportEdit.adopting(source, themePath: "/theme")
    let managed = String(decoding: try edit.apply(to: source), as: UTF8.self)
      .replacingOccurrences(of: "\"/theme\"]", with: "\"/theme\", 'later']")
    #expect(
      String(decoding: try edit.restore(Data(managed.utf8)), as: UTF8.self)
        == "[general]\nimport = ['first', 'later']\n")
  }

  @Test(arguments: ["# keep", "# keep\n", "[general]"])
  func appendedUserTablesSurviveRemovalOfAnIntroducedTable(original: String) throws {
    let source = Data(original.utf8)
    let edit = try AlacrittyImportEdit.adopting(source, themePath: "/theme")
    let managed = try edit.apply(to: source) + Data("[font]\nsize = 12\n".utf8)
    let restored = try edit.restore(managed)
    #expect(
      restored == source + Data((original.hasSuffix("\n") ? "" : "\n").utf8)
        + Data("[font]\nsize = 12\n".utf8))
    #expect(try TOMLTable(source: restored).table(forKey: "font").integer(forKey: "size") == 12)
    #expect(try edit.restore(edit.apply(to: source)) == source)
  }

}
