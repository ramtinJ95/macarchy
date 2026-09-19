import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuNeovimEditorTests {
  @Test func nativeTargetPreservesRootAndInitLinksAndRepairableLua() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let root = fixture.root.appending(path: "native")
    let alias = fixture.root.appending(path: "linked-native")
    let initSource = fixture.root.appending(path: "personal-init.lua")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try "invalid Lua to repair\n".write(to: initSource, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "init.lua"), withDestinationURL: initSource)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[neovim]\nnative_configuration = \"linked-native\"\n",
      source: fixture.profile)
    let target = try MenuNeovimEditor.editTarget(
      profile: profile, homeDirectory: fixture.home, stateRoot: fixture.state)
    #expect(target.declaredRoot.path == alias.path)
    #expect(target.physicalRoot.path == root.resolvingSymlinksInPath().path)
    #expect(Array(target.editorArguments.suffix(2)) == ["--", target.physicalRoot.path])
    #expect(target.notice.contains("next instance"))
    #expect(try String(contentsOf: initSource, encoding: .utf8) == "invalid Lua to repair\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == root.path)

    try FileManager.default.removeItem(at: root.appending(path: "init.lua"))
    let generated = fixture.state.appending(path: "private.lua")
    try "return {}".write(to: generated, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "init.lua"), withDestinationURL: generated)
    #expect(throws: (any Error).self) {
      try MenuNeovimEditor.editTarget(
        profile: profile, homeDirectory: fixture.home, stateRoot: fixture.state)
    }
  }

  @Test func menuFindsNativeEditor() {
    var menu = ActionMenuState()
    menu.search("configure nvim")
    #expect(menu.selectedAction == .neovim)
    #expect(menu.actions.count == 1)
  }
}
