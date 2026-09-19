import Foundation
import Testing

@testable import MacarchyCLI

struct EnvironmentNeovimThemePreparationTests {
  @Test func preparesOnlyAbsentThemeLinksAndPreservesUserFiles() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let root = fixture.home.appending(path: ".config/nvim")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let initial = Data("-- arbitrary, even invalid Lua stays untouched\n".utf8)
    let lock = Data("{\"my-plugin\": {\"commit\": \"personal\"}}\n".utf8)
    try initial.write(to: root.appending(path: "init.lua"))
    try lock.write(to: root.appending(path: "lazy-lock.json"))
    let preparation = EnvironmentNeovimThemePreparation(
      source: root, homeDirectory: fixture.home, stateRoot: fixture.state)
    let plan = try preparation.plan()
    #expect(plan.links.count == 4)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "lua").path))
    try preparation.prepare(approval: plan.approval)
    #expect(try preparation.plan().links.isEmpty)
    #expect(try Data(contentsOf: root.appending(path: "init.lua")) == initial)
    #expect(try Data(contentsOf: root.appending(path: "lazy-lock.json")) == lock)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
    for path in EnvironmentNeovimMigration.themePaths {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appending(path: path).path)
          == fixture.state.appending(path: "environment/current/neovim/\(path)").path)
    }
    let resumed = try preparation.plan()
    try preparation.prepare(approval: resumed.approval)
  }

  @Test func rejectsStaleApprovalConflictingLuaAndLinkedParents() throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let root = fixture.root.appending(path: "native")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let initial = root.appending(path: "init.lua")
    try Data("return {}".utf8).write(to: initial)
    let preparation = EnvironmentNeovimThemePreparation(
      source: root, homeDirectory: fixture.home, stateRoot: fixture.state)
    let plan = try preparation.plan()
    try Data("return { changed = true }".utf8).write(to: initial)
    #expect(throws: (any Error).self) { try preparation.prepare(approval: plan.approval) }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "lua").path))
    let plugins = root.appending(path: "lua/plugins")
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    let conflict = plugins.appending(path: "colorscheme.lua")
    let personal = Data("return { personal = true }".utf8)
    try personal.write(to: conflict)
    #expect(throws: (any Error).self) { try preparation.plan() }
    #expect(try Data(contentsOf: conflict) == personal)
    try FileManager.default.removeItem(at: conflict)
    try FileManager.default.removeItem(at: plugins)
    let external = fixture.root.appending(path: "plugins")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: plugins, withDestinationURL: external)
    #expect(throws: (any Error).self) { try preparation.plan() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
  }
}
