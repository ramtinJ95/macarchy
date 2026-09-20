import ArgumentParser
import Foundation
import TOMLDecoder
import ThemeCore

/// Read-only feedback, not an apply capability. Native consumers can observe a
/// save immediately; validation cannot promise rollback of their behavior.
struct MenuConfigurationValidate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-config-validate", shouldDisplay: false)
  @Argument var action: MenuConfigurationAction
  @Argument var target: String
  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let context = profiles.context(stateRoot: home.appending(path: ".config/macarchy"))
    print(try Self.validate(action, target: URL(filePath: target), context: context))
  }

  static func validate(
    _ action: MenuConfigurationAction, target: URL, context: UnifiedSetupPlanContext
  ) throws -> String {
    let layered = try MenuNativeProfileEdit.load(context)
    if let provider = action.desktopProvider,
      let source = provider.source(in: layered.profile)
    {
      guard source.resolvingSymlinksInPath() == target,
        try MenuProfileSource.prepare(
          source, stateRoot: context.stateRoot, confirmCreation: { _ in false }) == target
      else {
        throw ValidationError("Personal source changed; reopen Configure.")
      }
      let text = try BoundedRegularFile.readUTF8(at: target, maximumSize: 1_048_576)
      try DesktopShellSyntax.validate(text, source: target)
      return "Shell syntax is valid; no code executed. " + action.saveNotice
    }
    if try action.nativeProvider == nil
      || MenuConfigurationEditor.usesManagedProfile(action, context: context)
    {
      let sources = [context.profileURL, context.machineProfileURL]
      guard sources.contains(where: { $0.resolvingSymlinksInPath().path == target.path }),
        try MenuProfileSource.prepare(
          target, stateRoot: context.stateRoot,
          confirmCreation: { _ in false }) != nil
      else { throw ValidationError("Profile target changed; reopen Configure from the menu.") }
      if action.desktopProvider != nil {
        return
          "Layered profile is valid. No managed state was changed. Legacy profile edits require reviewed desktop apply."
      }
      return "Layered profile is valid. No managed state was changed. "
        + (try MenuConfigurationEditor.notice(action, context: context))
    }
    let provider = action.nativeProvider!
    let source = try EnvironmentConfigurationSourceResolver(
      homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
    ).menuEditingSource(provider, profile: layered.profile)
    guard source.status == .editable, source.resolvedSource == target.path
    else {
      throw ValidationError(
        "Native source changed or is unavailable; reopen Configure. " + source.message)
    }
    if source.authority == "copied_profile_input" {
      return "Source remains editable; native syntax/behavior was not evaluated. "
        + (try MenuConfigurationEditor.notice(action, context: context))
    }
    let data = try BoundedRegularFile.read(at: target).data
    guard let contents = String(data: data, encoding: .utf8) else {
      throw ValidationError("Saved configuration is not UTF-8. The edit was not reverted.")
    }
    if provider == .atuin || provider == .starship {
      _ = try TOMLTable(source: contents)
      try EnvironmentNativeFileMigration(
        provider: provider == .atuin ? .atuin : .starship,
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).validateNativeFile(at: target, userOwnedPublicEntry: true)
      return
        "TOML syntax and Macarchy theme seam are valid; application behavior is not validated. "
        + action.saveNotice
    }
    // External Kitty sources are included by a wrapper that owns the final
    // theme include. Only standard-native files own that directive themselves.
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    if provider == .kitty, ownership?.standardNativeEntries?.contains(.kitty) == true {
      try EnvironmentStandardNativeConfiguration.validate(
        provider, homeDirectory: context.homeDirectory, stateRoot: context.stateRoot,
        sourceURL: target)
    }
    return "Saved readable UTF-8; native syntax/behavior was not evaluated. " + action.saveNotice
  }
}
