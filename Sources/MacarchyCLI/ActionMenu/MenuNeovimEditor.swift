import ArgumentParser
import Foundation
import ThemeCore

/// Native Lua is edited directly. No profile-save hook, apply or plugin restore
/// is attached to this editor session.
struct MenuNeovimEditor: ParsableCommand {
  /// Hidden and stable: the menu, its editor callbacks and existing callers invoke this name.
  static let commandName = "_menu-neovim-edit"
  static let configuration = CommandConfiguration(
    commandName: Self.commandName, shouldDisplay: false)

  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    try MenuEditorSession.run(
      failure: "Could not complete Neovim editing",
      note: "Earlier approved starter/profile changes are retained; review them before retrying."
    ) {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let context = profiles.context(stateRoot: StateLayout.defaultRoot(in: home))
      let neovim = try MenuEditorSession.neovim(named: "Neovim editor")
      guard
        let target = try MenuNeovimSetup(context: context, homeDirectory: home).prepareForEditing()
      else { return }
      print("Neovim configuration: \(target.declaredRoot.path)")
      print("Configuration directory: \(target.physicalRoot.path)\n\(target.notice)")
      // A constant native message survives the initial screen clear. There is
      // deliberately no BufWritePost callback or executable Lua interpolation.
      try MenuEditorSession.edit(
        neovim, arguments: target.editorArguments, directory: target.physicalRoot,
        exitFailure: { "Neovim exited with status \($0.terminationStatus)" })
    }
  }

  struct Target {
    let declaredRoot: URL
    let physicalRoot: URL
    let notice =
      "Native Neovim files: behavior changes take effect next instance; no Macarchy apply on save."

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
    // Validate the bootstrap even though the directory is the launch target;
    // its leaf link must not escape into generated state or another provider.
    _ = try EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: stateRoot
    ).writableInitURL(at: URL(filePath: declared))
    return Target(
      declaredRoot: URL(filePath: declared, directoryHint: .isDirectory),
      physicalRoot: root)
  }
}
