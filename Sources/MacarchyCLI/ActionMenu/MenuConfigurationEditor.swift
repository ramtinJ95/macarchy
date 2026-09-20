import ArgumentParser
import Foundation
import ThemeCore

enum MenuConfigurationAction: String, CaseIterable, ExpressibleByArgument, Sendable {
  case starship, atuin, kitty, zsh, desktop, bar

  var title: String {
    switch self {
    case .starship: "Starship"
    case .atuin: "Atuin"
    case .kitty: "Kitty"
    case .zsh: "zsh"
    case .desktop: "Desktop (yabai)"
    case .bar: "Bar (SketchyBar)"
    }
  }

  var nativeProvider: EnvironmentNativeSeed.Provider? {
    switch self {
    case .starship: .starship
    case .atuin: .atuin
    case .kitty: .kitty
    case .zsh: .zsh
    case .desktop, .bar: nil
    }
  }

  var desktopProvider: DesktopPersonalProvider? {
    switch self {
    case .desktop: .yabai
    case .bar: .sketchybar
    default: nil
    }
  }

  var saveNotice: String {
    switch self {
    case .starship: "Native Starship edits affect new prompts; no Macarchy apply on save."
    case .atuin:
      "Native Atuin edits affect new invocations; running sessions may need reopening. No history/sync changes."
    case .kitty:
      "Use Kitty's native reload after saving. Macarchy does not signal or restart Kitty on save."
    case .zsh:
      "Native zsh edits affect new shells. Macarchy does not source arbitrary shell code on save."
    case .desktop:
      MenuDesktopConfiguration.notice(.yabai)
    case .bar:
      MenuDesktopConfiguration.notice(.sketchybar)
    }
  }
}

struct MenuConfigurationEditor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_menu-config-edit", shouldDisplay: false)
  @Argument var action: MenuConfigurationAction
  @OptionGroup var profiles: Macarchy.Setup.ProfileOptions

  mutating func run() throws {
    do {
      let neovim = URL(filePath: "/opt/homebrew/bin/nvim")
      guard FileManager.default.isExecutableFile(atPath: neovim.path) else {
        throw ValidationError("Neovim editor is not executable: \(neovim.path)")
      }
      let home = FileManager.default.homeDirectoryForCurrentUser
      let context = profiles.context(stateRoot: home.appending(path: ".config/macarchy"))
      let selected: URL?
      let desktopSession: MenuDesktopEditSession?
      if let provider = action.desktopProvider {
        desktopSession = try MenuDesktopConfiguration(provider: provider, context: context)
          .prepareForEditing()
        selected = desktopSession?.target
      } else if let provider = action.nativeProvider {
        desktopSession = nil
        selected = try MenuNativeConfigurationSetup(provider: provider, context: context)
          .prepareForEditing()
      } else {
        throw ValidationError("No configuration provider for \(action.rawValue)")
      }
      guard let target = selected else { return }
      let notice = try Self.notice(action, context: context)
      print("\(action.title): \(target.path)\n\(notice)")
      let temporary = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-config-edit-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: temporary) }
      let script = temporary.appending(path: "editor.lua")
      try MenuProfileEditor.script(
        target: target,
        section: try Self.usesManagedProfile(action, context: context) ? action.rawValue : nil,
        executableURL: RuntimeEnvironment.live.executableURL,
        notice: notice,
        saveArguments: ["_menu-config-validate", action.rawValue, target.path]
          + profiles.menuArguments
      ).write(to: script, atomically: true, encoding: .utf8)
      let editor = Process()
      editor.executableURL = neovim
      editor.currentDirectoryURL = target.deletingLastPathComponent()
      editor.arguments = ["-S", script.path, "--", target.path]
      try MenuProfileEditor.runEditor(editor)
      guard editor.terminationReason == .exit, editor.terminationStatus == 0 else {
        throw ValidationError("Neovim exited with status \(editor.terminationStatus)")
      }
      if let result = try desktopSession?.finish() { print(result.message) }
    } catch {
      print("Could not edit \(action.title): \(error)\nPress Enter to close.")
      _ = readLine()
      throw ExitCode.failure
    }
  }

  static func notice(
    _ action: MenuConfigurationAction, context: UnifiedSetupPlanContext
  ) throws -> String {
    if try usesManagedProfile(action, context: context) {
      return
        "Managed \(action.title) settings: reviewed environment plan/apply is required. Saving only changes your profile."
    }
    if let provider = action.nativeProvider {
      let profile = try MenuNativeProfileEdit.load(context).profile
      let source = EnvironmentConfigurationSourceResolver(
        homeDirectory: context.homeDirectory, stateRoot: context.stateRoot
      ).resolve(provider, profile: profile)
      if source.authority == "copied_profile_input" {
        return
          "Copied native input: reviewed environment plan/apply is required. Saving does not change managed state."
      }
    }
    return action.saveNotice
  }

  static func usesManagedProfile(
    _ action: MenuConfigurationAction, context: UnifiedSetupPlanContext
  ) throws -> Bool {
    guard action == .zsh || action == .kitty, let provider = action.nativeProvider else {
      return false
    }
    let profile = try MenuNativeProfileEdit.load(context).profile
    guard provider.source(in: profile.environment) == nil,
      provider.copiedSource(in: profile.environment) == nil
    else { return false }
    let ownership = try EnvironmentStateStore(stateRoot: context.stateRoot).readOwnership()
    return ownership?.records.contains(where: { $0.id == provider.entryID }) == true
      && ownership?.standardNativeEntries?.contains(provider.entryID) != true
  }

  static func target(
    _ action: MenuConfigurationAction, context: UnifiedSetupPlanContext,
    io: GuidedSetupIO = .live
  ) throws -> URL? {
    guard let provider = action.nativeProvider else {
      throw ValidationError("Desktop configuration requires a reviewed editor session")
    }
    let layered = try MenuNativeProfileEdit.load(context)
    if try !usesManagedProfile(action, context: context) {
      let source = try EnvironmentConfigurationSourceResolver(
        homeDirectory: context.homeDirectory,
        stateRoot: context.stateRoot
      ).menuEditingSource(provider, profile: layered.profile)
      guard source.status == .editable, let physical = source.resolvedSource
      else {
        throw ValidationError(source.message)
      }
      return URL(filePath: physical)
    }
    let section = action.rawValue
    let origins = Set(layered.fieldOrigins.filter { $0.key.hasPrefix(section + ".") }.map(\.value))
    let layer: PortableProfileLayerKind
    if origins.count > 1 {
      io.write(
        "\(section) settings come from both profile layers. Portable: \(context.profileURL.path)\nMachine: \(context.machineProfileURL.path)\n"
      )
      layer =
        try io.confirm("Edit the machine overrides? Choose no for portable defaults.")
        ? .machine : .portable
    } else {
      layer = origins.first ?? .portable
    }
    let path = layer == .machine ? context.machineProfileURL : context.profileURL
    return try MenuProfileSource.prepare(
      path, stateRoot: context.stateRoot,
      confirmCreation: { destination in
        io.write(
          "Create schema_version = 1 profile at \(destination.path)? No adoption or provider apply. [y/N] "
        )
        return io.read()?.lowercased() == "y"
      })
  }
}
