import ArgumentParser
import Foundation
import ThemeCore

extension Macarchy.Setup.ProfileOptions {
  var menuArguments: [String] {
    (portable.profile.map { ["--profile", URL(filePath: $0).standardizedFileURL.path] } ?? [])
      + (machineProfile.map { ["--machine-profile", URL(filePath: $0).standardizedFileURL.path] }
        ?? [])
  }
}

enum ProfileEditAction: String, CaseIterable, ExpressibleByArgument, Sendable {
  case portable
  case machine
  case keybindings

  var title: String {
    switch self {
    case .portable: "Portable profile"
    case .machine: "Machine overrides"
    case .keybindings: "Configure keybindings"
    }
  }

}

struct MenuProfileEditor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-profile-edit", shouldDisplay: false)

  @Argument var action: ProfileEditAction
  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    do {
      try edit()
    } catch {
      print("Could not complete profile editing: \(error)\nPress Enter to close.")
      _ = readLine()
      throw ExitCode.failure
    }
  }

  private func edit() throws {
    let neovim = URL(filePath: "/opt/homebrew/bin/nvim")
    guard FileManager.default.isExecutableFile(atPath: neovim.path) else {
      throw ValidationError("Profile editor is not executable: \(neovim.path)")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let context = profiles.context(stateRoot: home.appending(path: ".config/macarchy"))
    let target: URL
    let resolved: URL
    if action == .keybindings {
      guard let source = try MenuKeybindingSetup(context: context).prepareForEditing() else {
        return
      }
      target = source
      resolved = source
    } else {
      target = action == .machine ? context.machineProfileURL : context.profileURL
      // A physical edit target preserves the user's Stow leaf even when their
      // editor writes by rename. Relative inputs still resolve at this location.
      guard
        let source = try MenuProfileSource.prepare(
          target, stateRoot: context.stateRoot,
          confirmCreation: { destination in
            print(
              "Create profile at \(destination.path) with schema_version = 1? No adoption or provider connection will be applied. [y/N]"
            )
            return readLine()?.lowercased() == "y"
          })
      else { return }
      resolved = source
    }
    print("\(action.title): \(target.path)\nEditing source: \(resolved.path)")
    let temporary = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-menu-edit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sessionURL = temporary.appending(path: "session.json")
    let scriptURL = temporary.appending(path: "editor.lua")
    let notice: String
    var saveURL: URL?
    do {
      let (session, origin) = try MenuKeybindingSaveSession.begin(
        portableURL: context.profileURL, machineURL: context.machineProfileURL, target: resolved,
        resourcesRoot: context.keybindingsResourcesRoot, homeDirectory: home,
        portableRequired: context.profileRequired, machineRequired: context.machineProfileRequired)
      try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
      saveURL = sessionURL
      notice =
        session.nativeSource != nil
        ? "Save-to-apply: this personal skhd override only. Packaged defaults load first. "
          + "Supported binding syntax only; invalid edits stay saved and retain the last working generation. "
          + "Profile connections, metadata and other providers are not applied."
        : "Save-to-apply: [keybindings] disabled only (current winning layer: \(origin)). "
          + "Other changes are saved but require reviewed apply. No native override/metadata files are edited."
    } catch {
      notice =
        "Editing only; save-to-apply unavailable: \(error). Fix/review, then reopen from the menu."
    }
    let script = Self.script(
      target: resolved, section: nil,
      executableURL: RuntimeEnvironment.live.executableURL, notice: notice,
      saveArguments: saveURL.map { ["_menu-profile-save", $0.path] })
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let editor = Process()
    editor.executableURL = neovim
    editor.arguments = ["-S", scriptURL.path, "--", resolved.path]
    try MenuTerminal.runForeground(editor)
    guard editor.terminationReason == .exit, editor.terminationStatus == 0 else {
      throw ValidationError(
        "Neovim ended with \(editor.terminationReason), status \(editor.terminationStatus)")
    }
  }

  static func script(
    target: URL, section: String?, executableURL: URL, notice: String,
    saveArguments: [String]?
  ) -> String {
    let callback: String
    if let arguments = saveArguments {
      let command = ([executableURL.path] + arguments).map(luaString).joined(separator: ", ")
      callback = """
          local output = vim.fn.system({\(command)})
          local failed = vim.v.shell_error ~= 0
          vim.api.nvim_echo({{output, failed and 'ErrorMsg' or 'Normal'}}, true, {})
          if failed then vim.fn.input('Save/apply reported an error. Press Enter to continue editing: ') end
        """
    } else {
      callback = "vim.api.nvim_echo({{\(luaString(notice)), 'WarningMsg'}}, true, {})"
    }
    return """
      local target = \(luaString(target.path))
      local buffer = vim.fn.bufnr(target)
      if buffer < 0 then error('Macarchy profile buffer was not opened') end
      vim.api.nvim_set_current_buf(buffer)
      local original_name = vim.api.nvim_buf_get_name(buffer)
      \(section.map { "vim.fn.search('^\\\\s*\\\\[\\\\s*" + $0 + "\\\\s*\\\\]', 'w')" } ?? "")
      vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = buffer,
        callback = function()
          if vim.api.nvim_buf_get_name(buffer) ~= original_name then
            vim.api.nvim_echo({{'Saved under another name; no Macarchy apply.', 'WarningMsg'}}, true, {})
            return
          end
      \(callback)
        end,
      })
      vim.api.nvim_echo({{\(luaString(notice)), 'WarningMsg'}}, true, {})
      """
  }

  private static func luaString(_ text: String) -> String {
    "\"" + text.utf8.map { String(format: "\\%03d", $0) }.joined() + "\""
  }
}

struct MenuProfileSave: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-profile-save", shouldDisplay: false)
  @Argument var sessionPath: String

  mutating func run() throws {
    let url = URL(filePath: sessionPath)
    var session = try JSONDecoder().decode(
      MenuKeybindingSaveSession.self,
      from: BoundedRegularFile.read(at: url, maximumSize: 1_048_576).data)
    let message = try session.apply()
    try JSONEncoder().encode(session).write(to: url, options: .atomic)
    print(message)
  }
}
