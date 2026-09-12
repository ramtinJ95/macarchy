import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentStandardTerminalTests {
  @Test(arguments: [false, true])
  func personalTerminalFilesAreReadDirectlyAndSurviveLifecycle(linked: Bool) async throws {
    let fixture = try EnvironmentLifecycleFixture(externalEntries: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let personal = fixture.root.appending(path: "personal")
    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    let kittyDirectory = linked ? personal : fixture.kittyEntry
    if linked {
      try FileManager.default.createSymbolicLink(
        at: fixture.kittyEntry, withDestinationURL: personal)
    } else {
      try FileManager.default.createDirectory(at: kittyDirectory, withIntermediateDirectories: true)
    }
    let zsh = linked ? personal.appending(path: "zshrc") : fixture.zshEntry
    let kitty = kittyDirectory.appending(path: "kitty.conf")
    let shell = """
      starship() { print -r -- '(( STARSHIP_COUNT += 1 ))'; }
      atuin() { print -r -- '(( ATUIN_COUNT += 1 ))'; }
      eval "$(starship init zsh)"
      eval "$(atuin init zsh)"
      export PATH="$HOME/.bun/bin:$PATH"
      alias personal_alias='print personal'
      """ + "\n"
    try shell.write(to: zsh, atomically: true, encoding: .utf8)
    if linked {
      try FileManager.default.createSymbolicLink(at: fixture.zshEntry, withDestinationURL: zsh)
    }
    let themeInclude = "include " + fixture.state.appending(path: KittyAdapter.bridgePath).path
    let kittyText = "font_size 17\ninclude bindings.conf\n\(themeInclude)\n"
    try kittyText.write(to: kitty, atomically: true, encoding: .utf8)
    try "map ctrl+shift+x new_window\n".write(
      to: kittyDirectory.appending(path: "bindings.conf"), atomically: true, encoding: .utf8)
    let profile =
      try String(contentsOf: fixture.profile, encoding: .utf8)
      + "\n[zsh]\nconfiguration = \"\(fixture.zshEntry.path)\"\n"
      + "\n[kitty]\nconfiguration = \"\(fixture.kittyEntry.appending(path: "kitty.conf").path)\"\n"
    try profile.write(to: fixture.profile, atomically: true, encoding: .utf8)
    let plan = try fixture.plan()
    #expect(plan.succeeded, "\(plan.output)")
    let applied = try await fixture.apply(adopt: nil)
    #expect(applied.succeeded, "\(applied.output)")
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership())
    #expect(ownership.standardNativeEntries == [.kitty, .zsh])
    #expect(!ownership.records.contains { $0.id == .kitty || $0.id == .zsh })
    let edited = shell + "export PERSONAL_EDIT=kept\n"
    try edited.write(to: zsh, atomically: true, encoding: .utf8)
    let bunx = fixture.home.appending(path: ".bun/bin/bunx")
    try FileManager.default.createDirectory(
      at: bunx.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: bunx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bunx.path)
    let session = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/zsh"),
        arguments: [
          "-d", "-f", "-c",
          "source \"$HOME/.zshrc\"; print -r -- \"$STARSHIP_COUNT:$ATUIN_COUNT:$PERSONAL_EDIT\"; command -v bunx",
        ],
        timeout: 5, environmentOverrides: ["HOME": fixture.home.path, "PATH": "/usr/bin:/bin"]))
    #expect(session.terminationStatus == 0)
    #expect(session.output.contains("1:1:kept"), "\(session.output)")
    #expect(session.output.contains(bunx.path))
    try fixture.activateTheme()
    let adapter = KittyAdapter(
      root: fixture.state, configurationURL: fixture.kittyEntry.appending(path: "kitty.conf"),
      includeDirective: themeInclude,
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") })
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try await fixture.apply(adopt: nil).succeeded)
    #expect(try fixture.status().succeeded)
    for provider in [EnvironmentNativeSeed.Provider.zsh, .kitty] {
      let source = EnvironmentConfigurationSourceResolver(
        homeDirectory: fixture.home, stateRoot: fixture.state
      )
      .resolve(provider, profile: .defaults)
      #expect(source.status == .editable, "\(source.message)")
      #expect(source.source == provider.standardURL(homeDirectory: fixture.home).path)
    }
    try (kittyText + "foreground #112233\n").write(to: kitty, atomically: true, encoding: .utf8)
    #expect(!(try fixture.plan().succeeded))
    #expect(throws: (any Error).self) {
      try ThemeRuntimeSelection.consumerPaths(
        stateRoot: fixture.state,
        consumerPaths: testConsumerPaths().managedEnvironmentPaths(
          stateRoot: fixture.state, homeDirectory: fixture.home, ownership: ownership))
    }
    try kittyText.write(to: kitty, atomically: true, encoding: .utf8)
    #expect(try await fixture.teardown().succeeded)
    #expect(try String(contentsOf: zsh, encoding: .utf8) == edited)
    #expect(try String(contentsOf: kitty, encoding: .utf8) == kittyText)
    if linked {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: fixture.zshEntry.path) == zsh.path
      )
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: fixture.kittyEntry.path)
          == personal.path)
    }
  }
}
