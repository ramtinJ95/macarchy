import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuNativeProfileEditTests {
  @Test(arguments: EnvironmentNativeSeed.Provider.allCases)
  func sourceIntentPreservesPhysicalLayersAndRejectsStaleApproval(
    provider: EnvironmentNativeSeed.Provider
  ) throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let machine = fixture.root.appending(path: "machine.toml")
    let physical = fixture.root.appending(path: "dotfiles-machine.toml")
    let source = fixture.root.appending(path: "personal")
    let portable = "schema_version = 1\n# portable retained\n"
    try portable.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let copied = provider.copiedProfileKeys[0]
    var original =
      "schema_version = 1\n# machine retained\n[\(provider.rawValue)]\n\(copied) = \"old\"\n"
    if provider == .atuin {
      original +=
        "search_mode = \"fuzzy\"\nkeymap_mode = \"vim-normal\"\nenter_accept = true\ndaemon = false\n"
    }
    try original.write(to: physical, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: machine, withDestinationURL: physical)
    let context = UnifiedSetupPlanContext(
      themesRoot: repositoryRoot.appending(path: "Themes"),
      keybindingsResourcesRoot: repositoryRoot.appending(path: "Keybindings"),
      desktopResourcesRoot: repositoryRoot.appending(path: "Desktop"),
      environmentResourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: fixture.profile, profileRequired: true,
      machineProfileURL: machine, machineProfileRequired: true,
      stateRoot: fixture.state, homeDirectory: fixture.home)
    let edit = try MenuNativeProfileEdit.prepare(
      context: context, source: source, provider: provider)
    #expect(try String(contentsOf: physical, encoding: .utf8) == original)
    try edit.publish()
    let changed = try String(contentsOf: physical, encoding: .utf8)
    #expect(changed.contains("# machine retained"))
    #expect(changed.contains("\(provider.profileKey) = \"personal\""))
    for key in provider.copiedProfileKeys { #expect(!changed.contains("\n\(key) =")) }
    #expect(try String(contentsOf: fixture.profile, encoding: .utf8) == portable)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: machine.path) == physical.path)
    let stale = try MenuNativeProfileEdit.prepare(
      context: context, source: fixture.root.appending(path: "other"), provider: provider)
    try (changed + "# later edit\n").write(to: physical, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try stale.publish() }
    #expect(try String(contentsOf: physical, encoding: .utf8).hasSuffix("# later edit\n"))
  }
}
