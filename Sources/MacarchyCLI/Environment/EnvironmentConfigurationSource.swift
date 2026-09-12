import Darwin
import Foundation
import ThemeCore

/// An editor target, not permission to apply configuration or repair a connection.
struct EnvironmentConfigurationSource: Encodable, Sendable {
  enum Status: String, Encodable {
    case editable, missing, blocked
    case disabledInProfile = "disabled_in_profile"
    case readOnly = "read_only"
    case nativeSetupRequired = "native_setup_required"
    case connectionRequired = "connection_required"
  }

  let provider: String
  let status: Status
  let authority: String
  let source: String?
  let resolvedSource: String?
  let kind: String
  let message: String

  func render(json: Bool) throws -> String {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    return "\(provider) configuration [\(status.rawValue), \(authority)]: "
      + (source ?? "no editable target") + "\n" + message
  }
}

struct EnvironmentConfigurationSourceResolver: Sendable {
  let homeDirectory: URL
  let stateRoot: URL

  func resolve(
    _ provider: EnvironmentNativeSeed.Provider, profile: PortableProfile
  ) -> EnvironmentConfigurationSource {
    func report(
      _ status: EnvironmentConfigurationSource.Status, authority: String = "none",
      source: URL? = nil, kind: String = "file", message: String
    ) -> EnvironmentConfigurationSource {
      .init(
        provider: provider.rawValue, status: status, authority: authority,
        source: source?.path, resolvedSource: source?.resolvingSymlinksInPath().path,
        kind: kind, message: message)
    }
    guard provider.isEnabled(in: profile.environment) else {
      return report(
        .disabledInProfile,
        message:
          "Disabled in the effective profile; this does not assert that pending provider removal has been applied."
      )
    }
    do {
      let state = EnvironmentStateStore(stateRoot: stateRoot)
      guard !state.transactionExists else {
        throw EnvironmentLifecycleError.blocked(
          "Recover the pending environment transaction before selecting an editor target.")
      }
      let ownership = try state.readOwnership()
      let generations = EnvironmentGenerationStore(stateRoot: stateRoot)
      let current = try generations.currentDestination()
      guard current == ownership.map({ "generations/\($0.generationID)" }) else {
        throw EnvironmentLifecycleError.drift(
          "Environment ownership and its active generation disagree.")
      }
      let inspector = EnvironmentProviderInspector()
      let entry = inspector.allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .first { $0.id == provider.entryID }!
      let record = ownership?.records.first { $0.id == provider.entryID }
      let native: URL?
      switch provider {
      case .zsh, .kitty:
        native =
          ownership?.standardNativeEntries?.contains(provider.entryID) == true
          ? provider.standardURL(homeDirectory: homeDirectory) : nil
      case .neovim:
        native = EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
          .nativeTarget(in: ownership)
      case .atuin, .starship:
        native = EnvironmentNativeFileMigration(
          provider: provider == .atuin ? .atuin : .starship,
          homeDirectory: homeDirectory, stateRoot: stateRoot
        ).nativeTarget(in: ownership)
      }
      if let record {
        guard record.publicPath == entry.url.path, record.managedKind == entry.kind.rawValue,
          record.managedTarget == (native?.path ?? entry.target),
          try inspector.managedEntryIsExact(
            .init(
              id: entry.id, url: entry.url, kind: entry.kind, target: record.managedTarget))
        else {
          throw EnvironmentLifecycleError.drift(
            "The owned public connection has drifted; review environment status before editing.")
        }
      }
      let declared = provider.source(in: profile.environment)
      if let declared,
        (native != nil && native?.path != declared.path)
          || (record != nil && provider != .zsh && provider != .kitty
            && record?.managedTarget != declared.path)
      {
        return report(
          .connectionRequired, authority: "profile", source: declared,
          kind: provider == .neovim ? "directory" : "file",
          message:
            "The profile and active native connection differ. Review environment migrate-\(provider.rawValue) --source; no editor target is approved by this lookup."
        )
      }
      let copied = provider.copiedSource(in: profile.environment)
      guard let source = declared ?? native ?? copied else {
        let next =
          provider == .zsh || provider == .kitty
          ? "Declare \(provider.rawValue).configuration or review a writable starter."
          : "Review environment migrate-\(provider.rawValue) for existing ownership, or a writable starter for a new setup."
        return report(
          .nativeSetupRequired,
          message: "Generated configuration is not an editing surface. " + next)
      }
      guard
        EnvironmentNativeSource.targetIsAllowed(
          source.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
          userOwnedPublicEntry: declared != nil || native != nil ? provider.entryID : nil)
      else {
        throw EnvironmentLifecycleError.blocked(
          "Editor targets must stay outside generated state and managed public entry points.")
      }
      let authority =
        declared != nil
        ? "native_profile" : native != nil ? "native_ownership" : "copied_profile_input"
      let isDirectory =
        provider == .neovim || (provider == .kitty && authority == "copied_profile_input")
      if provider == .neovim,
        !EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
          .targetIsAllowed(source.path, userOwnedPublicEntry: declared != nil || native != nil)
      {
        throw EnvironmentLifecycleError.blocked(
          "An editor configuration tree cannot contain managed state or public entries.")
      }
      let resolved = source.resolvingSymlinksInPath()
      var metadata = stat()
      guard lstat(resolved.path, &metadata) == 0 else {
        if errno == ENOENT {
          return report(
            .missing, authority: authority, source: source,
            kind: isDirectory ? "directory" : "file",
            message:
              "The declared user source is missing. Restore it or review explicit starter creation; no generated fallback is selected."
          )
        }
        throw EnvironmentLifecycleError.system("inspect editor source", resolved, errno)
      }
      guard metadata.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else {
        throw EnvironmentLifecycleError.blocked(
          "The editor source is not an ordinary \(isDirectory ? "directory" : "file").")
      }
      let writable = access(resolved.path, R_OK | W_OK) == 0
      let semantics =
        authority == "copied_profile_input"
        ? "This is a copied profile input; changes require reviewed environment plan/apply."
        : "This is user-owned native configuration, not generated state. This lookup does not prove pending profile changes are connected; review environment plan before expecting native reload effects. It neither applies changes nor verifies arbitrary behavior."
      return report(
        writable ? .editable : .readOnly, authority: authority, source: source,
        kind: isDirectory ? "directory" : "file",
        message: writable
          ? semantics
          : "The user source is not readable and writable; permissions were not changed.")
    } catch {
      return report(.blocked, message: String(describing: error))
    }
  }
}

extension EnvironmentNativeSeed.Provider {
  var entryID: EnvironmentEntryID {
    switch self {
    case .zsh: .zsh
    case .kitty: .kitty
    case .atuin: .atuinConfiguration
    case .starship: .starship
    case .neovim: .neovim
    }
  }

  func isEnabled(in profile: EnvironmentProfile) -> Bool {
    switch self {
    case .zsh: profile.shell == .zsh
    case .kitty: profile.terminal == .kitty
    case .atuin: profile.history == .atuin
    case .starship: profile.prompt == .starship
    case .neovim: profile.editor == .neovim
    }
  }

  func source(in profile: EnvironmentProfile) -> URL? {
    switch self {
    case .zsh: profile.zsh.configurationURL
    case .kitty: profile.kitty.configurationURL
    case .atuin: profile.atuin.nativeConfigurationURL
    case .starship: profile.starship.nativeConfigurationURL
    case .neovim: profile.neovim.nativeConfigurationDirectoryURL
    }
  }

  func copiedSource(in profile: EnvironmentProfile) -> URL? {
    switch self {
    case .zsh: profile.zsh.hookURL
    case .kitty: profile.kitty.overrideDirectoryURL
    case .atuin: profile.atuin.configurationURL
    case .starship: profile.starship.behaviorURL
    case .neovim: profile.neovim.configurationDirectoryURL
    }
  }
}
