import ArgumentParser
import Foundation
import ThemeCore

/// Native Lua is edited directly. No profile-save hook, apply or plugin restore
/// is attached to this editor session.
struct MenuNeovimEditor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-neovim-edit", shouldDisplay: false)

  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    do {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let context = profiles.context(stateRoot: home.appending(path: ".config/macarchy"))
      let neovim = URL(filePath: "/opt/homebrew/bin/nvim")
      guard FileManager.default.isExecutableFile(atPath: neovim.path) else {
        throw ValidationError("Neovim editor is not executable: \(neovim.path)")
      }
      guard
        let target = try MenuNeovimSetup(context: context, homeDirectory: home).prepareForEditing()
      else { return }
      print("Neovim configuration: \(target.declaredRoot.path)")
      print("Configuration directory: \(target.physicalRoot.path)\n\(target.notice)")
      let editor = Process()
      editor.executableURL = neovim
      editor.currentDirectoryURL = target.physicalRoot
      // A constant native message survives the initial screen clear. There is
      // deliberately no BufWritePost callback or executable Lua interpolation.
      editor.arguments = target.editorArguments
      try MenuProfileEditor.runEditor(editor)
      guard editor.terminationReason == .exit, editor.terminationStatus == 0 else {
        throw ValidationError("Neovim exited with status \(editor.terminationStatus)")
      }
    } catch {
      print(
        "Could not complete Neovim editing: \(error)\nEarlier approved starter/profile changes are retained; review them before retrying.\nPress Enter to close."
      )
      _ = readLine()
      throw ExitCode.failure
    }
  }

  struct Target {
    let declaredRoot: URL
    let physicalRoot: URL
    let file: URL
    let notice: String

    // Let the user's normal Neovim directory handler choose its file browser.
    // Do not force a plugin, explorer command, or an init.lua buffer.
    var editorArguments: [String] {
      ["-c", "echo '" + notice + "'", "--", physicalRoot.path]
    }
  }

  static func editTarget(
    profile: PortableProfile, homeDirectory: URL, stateRoot: URL
  ) throws -> Target {
    let source = EnvironmentConfigurationSourceResolver(
      homeDirectory: homeDirectory, stateRoot: stateRoot
    ).resolve(.neovim, profile: profile)
    guard source.status == .editable, let declared = source.source,
      let physical = source.resolvedSource
    else { throw ValidationError(source.message) }
    let root = URL(filePath: physical, directoryHint: .isDirectory)
    // Resolve the leaf as well as the root, preserving dotfile links when an
    // editor writes by rename. A personal init link is not permission to edit
    // generated configuration or another managed provider entry.
    let file = try EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: stateRoot
    ).writableInitURL(at: URL(filePath: declared))
    let notice =
      source.authority == "copied_profile_input"
      ? "Copied Neovim input: saves require reviewed apply; no automatic apply or plugin restore."
      : "Native Neovim files: behavior changes take effect next instance; no Macarchy apply on save."
    return Target(
      declaredRoot: URL(filePath: declared, directoryHint: .isDirectory),
      physicalRoot: root, file: file, notice: notice)
  }
}
