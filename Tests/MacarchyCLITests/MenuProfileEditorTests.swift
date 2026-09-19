import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct MenuProfileEditorTests {
  @Test func creationRequiresConsentAndPhysicalTargetsPreserveLinks() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(
      try MenuProfileSource.prepare(
        fixture.profile, stateRoot: fixture.stateRoot, confirmCreation: { _ in false }) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.profile.path))
    let created = try #require(
      try MenuProfileSource.prepare(
        fixture.profile, stateRoot: fixture.stateRoot,
        confirmCreation: { destination in
          #expect(destination == fixture.profile.resolvingSymlinksInPath())
          return true
        }))
    let link = fixture.root.appending(path: "profile-link.toml")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: created.path)
    let editable = try MenuProfileSource.prepare(
      link, stateRoot: fixture.stateRoot,
      confirmCreation: { _ in
        Issue.record("Existing source requested creation")
        return false
      })
    #expect(editable == created)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == created.path)
    #expect(try String(contentsOf: created, encoding: .utf8) == "schema_version = 1\n")
    let generated = fixture.stateRoot.appending(path: "environment/generations/e-test/profile.toml")
    let generatedLink = fixture.root.appending(path: "unsafe.toml")
    try FileManager.default.createDirectory(
      at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: generated)
    try FileManager.default.createSymbolicLink(
      atPath: generatedLink.path, withDestinationPath: generated.path)
    #expect(throws: (any Error).self) {
      try MenuProfileSource.prepare(
        generatedLink, stateRoot: fixture.stateRoot, confirmCreation: { _ in true })
    }
    #expect(throws: (any Error).self) {
      try MenuProfileSource.prepare(
        fixture.stateRoot.appending(path: "state/preferences/state.json"),
        stateRoot: fixture.stateRoot,
        confirmCreation: { _ in
          Issue.record("Managed state must be rejected before creation is offered")
          return true
        })
    }
  }

  @Test func customPathsAndMachineWinningFieldSelectTheCorrectSource() throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let machine = fixture.root.appending(path: "custom machine.toml")
    try "schema_version = 1\n[keybindings]\ndisabled = []\n".write(
      to: machine, atomically: true, encoding: .utf8)
    #expect(
      try ProfileEditAction.keybindings.target(portable: fixture.profile, machine: machine)
        == machine)
    #expect(
      try ProfileEditAction.portable.target(portable: fixture.profile, machine: machine)
        == fixture.profile)
    try "schema_version = 1\n".write(to: machine, atomically: true, encoding: .utf8)
    #expect(
      try ProfileEditAction.keybindings.target(portable: fixture.profile, machine: machine)
        == fixture.profile)
    let command = try ActionMenu.parse([
      "--profile", fixture.profile.path, "--machine-profile", machine.path,
    ])
    #expect(
      command.profiles.menuArguments == [
        "--profile", fixture.profile.path, "--machine-profile", machine.path,
      ])
    let relative = try ActionMenu.parse(["--profile", "personal.toml"])
    #expect(
      relative.profiles.menuArguments == [
        "--profile", URL(filePath: "personal.toml").standardizedFileURL.path,
      ])
  }

  @Test(
    .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/nvim")),
    arguments: [
      (0, "[keybindings]", false), (7, "  [ keybindings ]", false),
      (7, "[keybindings]", true),
    ])
  func realNeovimHookIsBufferScopedQuotesPathsAndReportsResults(
    status: Int, header: String, nativeValidation: Bool
  ) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy editor ' \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "profile ' name.toml")
    let script = root.appending(path: "editor.lua")
    let helper = root.appending(path: "helper")
    let session = root.appending(path: "session.json")
    try "schema_version = 1\n\n\(header)\ndisabled = []\n".write(
      to: target, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nprintf 'save result\\n'\nexit \(status)\n"
      .write(
        to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let validationArguments = [
      "_menu-config-validate", "atuin", target.path,
      "--profile", root.appending(path: "portable ' profile.toml").path,
    ]
    let generated = MenuProfileEditor.script(
      target: target, section: "keybindings", executableURL: helper,
      notice: "Scoped save only",
      saveArguments: nativeValidation ? validationArguments : ["_menu-profile-save", session.path])
    // No user config or live lifecycle. Exercise the actual Neovim event and
    // synchronous argv callback, including :wq-style failure acknowledgement.
    let probe = """
      local held = false
      vim.fn.input = function(_) held = true; return '' end
      assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'wrong section')
      vim.cmd('write')
      assert(held == \(status != 0 ? "true" : "false"), 'wrong failure acknowledgement')
      assert(vim.api.nvim_exec2('messages', {output=true}).output:find('save result', 1, true))
      vim.cmd('enew')
      assert(#vim.api.nvim_get_autocmds({event='BufWritePost', buffer=0}) == 0, 'hook escaped buffer')
      vim.cmd('qa!')
      """
    let checkedScript =
      "local ok, err = pcall(function()\n" + generated + "\n" + probe
      + "\nend)\nif not ok then print(err); vim.cmd('cquit') end\n"
    try checkedScript.write(to: script, atomically: true, encoding: .utf8)
    let execution = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/opt/homebrew/bin/nvim"),
        arguments: ["--headless", "-u", "NONE", "-n", "-S", script.path, "--", target.path],
        timeout: 10))
    #expect(execution.terminationStatus == 0, "\(execution.output)")
    #expect(
      try String(contentsOf: URL(filePath: helper.path + ".args"), encoding: .utf8)
        == (nativeValidation ? validationArguments : ["_menu-profile-save", session.path])
        .joined(separator: "\n") + "\n")
  }
}
