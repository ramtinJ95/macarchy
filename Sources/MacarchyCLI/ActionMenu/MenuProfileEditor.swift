import ArgumentParser
import Darwin
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

  func target(portable: URL, machine: URL) throws -> URL {
    switch self {
    case .portable: return portable
    case .machine: return machine
    case .keybindings:
      let layered = try PortableProfileLoader().load(
        portableAt: portable, portableRequired: false, machineAt: machine, machineRequired: false)
      return layered.fieldOrigins["keybindings.disabled"] == .machine ? machine : portable
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
    let target = try action.target(portable: context.profileURL, machine: context.machineProfileURL)
    // A physical edit target preserves the user's Stow leaf even when their
    // editor writes by rename. Relative inputs still resolve at this location.
    guard
      let resolved = try MenuProfileSource.prepare(
        target, stateRoot: context.stateRoot,
        confirmCreation: { destination in
          print(
            "Create profile at \(destination.path) with schema_version = 1? No adoption or provider connection will be applied. [y/N]"
          )
          return readLine()?.lowercased() == "y"
        })
    else { return }
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
        "Save-to-apply: [keybindings] disabled only (current winning layer: \(origin)). "
        + "Other changes are saved but require reviewed apply. No native override/metadata files are edited."
    } catch {
      notice =
        "Editing only; save-to-apply unavailable: \(error). Fix/review, then reopen from the menu."
    }
    let script = Self.script(
      target: resolved, section: action == .keybindings ? "keybindings" : nil,
      executableURL: RuntimeEnvironment.live.executableURL, notice: notice,
      saveArguments: saveURL.map { ["_menu-profile-save", $0.path] })
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let editor = Process()
    editor.executableURL = neovim
    editor.arguments = ["-S", scriptURL.path, "--", resolved.path]
    try Self.runEditor(editor)
    guard editor.terminationReason == .exit, editor.terminationStatus == 0 else {
      throw ValidationError(
        "Neovim ended with \(editor.terminationReason), status \(editor.terminationStatus)")
    }
  }

  static func runEditor(_ editor: Process) throws {
    let foreground = tcgetpgrp(STDIN_FILENO)
    try editor.run()
    guard foreground >= 0 else {
      editor.waitUntilExit()
      return
    }
    // Foundation gives the child its own process group. An interactive editor
    // must own the terminal or its first read stops it with SIGTTIN. Ignore
    // SIGTTOU in this waiting parent only so it can restore foreground ownership.
    let previousHandler = signal(SIGTTOU, SIG_IGN)
    defer { _ = signal(SIGTTOU, previousHandler) }
    guard tcsetpgrp(STDIN_FILENO, editor.processIdentifier) == 0 else {
      let reason = String(cString: strerror(errno))
      editor.terminate()
      _ = kill(editor.processIdentifier, SIGCONT)
      editor.waitUntilExit()
      throw ValidationError("Could not give Neovim the terminal: \(reason)")
    }
    // Resume a child that raced the handoff and already stopped on a tty read.
    _ = kill(editor.processIdentifier, SIGCONT)
    editor.waitUntilExit()
    guard tcsetpgrp(STDIN_FILENO, foreground) == 0 else {
      throw ValidationError(
        "Could not restore terminal foreground ownership: \(String(cString: strerror(errno)))")
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
