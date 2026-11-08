import Darwin
import Foundation
import ThemeCore

/// Creates personal starter files, not ownership receipts or active connections.
struct EnvironmentNativeSeed: Sendable {
  enum Provider: String, Codable, CaseIterable, Sendable {
    case zsh, kitty, atuin, starship, neovim

    /// The single-file native migration this provider uses, if its native source is one file.
    var nativeFileProvider: EnvironmentNativeFileMigration.Provider? {
      switch self {
      case .atuin: .atuin
      case .starship: .starship
      case .zsh, .kitty, .neovim: nil
      }
    }

    /// The profile table that declares this provider's sources.
    var profileTable: String { profileFields.table }

    /// The profile key that selects the native source.
    var profileKey: String { profileFields.source }

    /// These fields configure copied behavior, not the new user-owned source.
    /// Review must disclose their removal; existing migrations preserve the
    /// active composed behavior in the writable file before removing intent.
    var copiedProfileKeys: [String] { profileFields.copied }

    private var profileFields: (table: String, source: String, copied: [String]) {
      switch self {
      case .zsh:
        return (
          ZshProfileOptions.table, ZshProfileOptions.key(\.configurationURL),
          [ZshProfileOptions.key(\.hookURL)]
        )
      case .kitty:
        return (
          KittyProfileOptions.table, KittyProfileOptions.key(\.configurationURL),
          [KittyProfileOptions.key(\.overrideDirectoryURL)]
        )
      case .atuin:
        return (
          AtuinProfileOptions.table, AtuinProfileOptions.key(\.nativeConfigurationURL),
          [
            AtuinProfileOptions.key(\.configurationURL), AtuinProfileOptions.key(\.searchMode),
            AtuinProfileOptions.key(\.keymapMode), AtuinProfileOptions.key(\.enterAccept),
            AtuinProfileOptions.key(\.daemon),
          ]
        )
      case .starship:
        return (
          StarshipProfileOptions.table, StarshipProfileOptions.key(\.nativeConfigurationURL),
          [StarshipProfileOptions.key(\.behaviorURL)]
        )
      case .neovim:
        return (
          NeovimProfileOptions.table, NeovimProfileOptions.key(\.nativeConfigurationDirectoryURL),
          [NeovimProfileOptions.key(\.configurationDirectoryURL)]
        )
      }
    }
  }

  struct Plan: Encodable, Sendable {
    let provider: String
    let destination: String
    let contents: String
    let approval: String
    let message: String
    var files: [String: Data] = [:]
    var parentDirectory: String? = nil
  }

  let provider: Provider
  let destination: URL
  let homeDirectory: URL
  let stateRoot: URL
  var resourcesRoot: URL = RuntimeEnvironment.live.builtInEnvironmentURL
  var bootstrapPalette: Data? = nil
  /// Guided setup reviews this one directory as well as each absent starter.
  var createParentDirectory = false

  func plan() throws -> Plan {
    let destination = destination.standardizedFileURL
    guard
      EnvironmentNativeSource.targetIsAllowed(
        destination.path, homeDirectory: homeDirectory, stateRoot: stateRoot,
        userOwnedPublicEntry: provider.entryID)
    else {
      throw EnvironmentLifecycleError.blocked(
        "starter destination must be outside Macarchy state and managed entry points")
    }
    if provider == .neovim,
      !EnvironmentNeovimMigration(homeDirectory: homeDirectory, stateRoot: stateRoot)
        .targetIsAllowed(destination.path, userOwnedPublicEntry: true)
    {
      throw EnvironmentLifecycleError.blocked(
        "Neovim starter must not contain managed entry points or state")
    }
    try validateDestination()
    let contents: String
    var files: [String: Data] = [:]
    switch provider {
    case .zsh:
      let source =
        destination == provider.standardURL(homeDirectory: homeDirectory)
        ? EnvironmentConfigurationComposer.nativeZshDefaultsSource(stateRoot: stateRoot)
        : "source \"$MACARCHY_ZSH_DEFAULTS\" || return 1"
      contents = """
        # User-owned configuration. Put overrides after the optional curated defaults.
        \(source)

        """
    case .kitty:
      let defaults = StateLayout(root: stateRoot).environmentArtifact("kitty/defaults.conf").path
      guard !defaults.contains("$"),
        !defaults.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw EnvironmentLifecycleError.blocked(
          "Kitty defaults path cannot contain expansion or control characters")
      }
      let theme =
        destination == provider.standardURL(homeDirectory: homeDirectory)
        ? "# Keep the managed theme include last.\n"
          + KittyAdapter.includeDirective(stateRoot: stateRoot) + "\n" : ""
      contents = """
        # User-owned configuration. Put overrides after the optional curated defaults.
        include \(defaults)

        """ + theme
    case .neovim:
      let composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot, profile: .defaults, stateRoot: stateRoot)
      let artifacts = composition.artifacts.filter { $0.path.hasPrefix("neovim/") }
      files = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0.data) })
      contents = artifacts.sorted(by: { $0.path < $1.path }).map { artifact in
        let relative = String(artifact.path.dropFirst("neovim/".count))
        if NeovimAdapter.managedThemePaths.contains(relative) {
          return
            "\(relative) -> \(StateLayout(root: stateRoot).environmentArtifact(artifact.path).path)"
        }
        return "\(relative):\n" + String(decoding: artifact.data, as: UTF8.self)
      }.joined(separator: "\n\n")
    case .atuin, .starship:
      let composition = try EnvironmentConfigurationComposer().compose(
        resourcesRoot: resourcesRoot, profile: .defaults, stateRoot: stateRoot)
      let path = provider == .atuin ? "atuin/config.toml" : "starship/behavior.toml"
      guard let artifact = composition.artifacts.first(where: { $0.path == path }) else {
        throw EnvironmentLifecycleError.blocked("shipped starter is missing: \(path)")
      }
      if provider == .atuin {
        contents = String(decoding: artifact.data, as: UTF8.self)
      } else {
        let palette: Data
        if let bootstrapPalette {
          palette = bootstrapPalette
        } else {
          let manifest = try ThemeGenerationReader(root: stateRoot).activeManifest()
          palette = try BoundedRegularFile.read(
            at: manifest.artifactURL(root: stateRoot, path: "generated/starship.toml")
          ).data
        }
        contents = String(
          decoding: try StarshipNativeConfiguration(url: destination).seed(
            behavior: artifact.data, palette: palette), as: UTF8.self)
      }
    }
    let approval = sha256Digest(
      try sortedKeysJSON([
        provider.rawValue, destination.path, stateRoot.standardizedFileURL.path, contents,
        createParentDirectory ? destination.deletingLastPathComponent().path : "",
      ]) + sortedKeysJSON(files))
    return Plan(
      provider: provider.rawValue, destination: destination.path, contents: contents,
      approval: approval,
      message:
        "Creates only this writable starter. Set \(provider.rawValue).\(provider.profileKey) in your profile, then review environment plan/apply. No active entry or profile is changed.",
      files: files,
      parentDirectory: createParentDirectory ? destination.deletingLastPathComponent().path : nil
    )
  }

  func seed(approval: String) throws -> Plan {
    let plan = try plan()
    guard approval == plan.approval else {
      throw EnvironmentLifecycleError.blocked("starter approval changed; review the plan again")
    }
    if createParentDirectory { try ensureParentDirectory() }
    let destination = URL(filePath: plan.destination)
    if provider == .neovim {
      try EnvironmentNeovimMigration.seedArtifacts(
        plan.files.sorted(by: { $0.key < $1.key }).map {
          EnvironmentConfigurationArtifact(path: $0.key, data: $0.value)
        }, destination: destination, stateRoot: stateRoot)
      try EnvironmentNeovimMigration(
        homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: destination
      ).validateNativeTree(userOwnedPublicEntry: true)
      return plan
    }
    try Self.publishFile(
      Data(plan.contents.utf8), at: destination, temporaryPrefix: ".macarchy-native",
      publishOperation: "publish native starter", syncOperation: "sync published native starter")
    return plan
  }

  static func publishFile(
    _ data: Data, at destination: URL, temporaryPrefix: String,
    publishOperation: String, syncOperation: String
  ) throws {
    let parent = try PinnedFilesystem.openDirectory(at: destination.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let temporary = "\(temporaryPrefix)-\(UUID().uuidString.lowercased()).seed"
    // Also removes a partially written seed.
    defer { temporary.withCString { _ = Darwin.unlinkat(parent, $0, 0) } }
    do {
      try PinnedFilesystem.publishNewRegularFile(
        data, as: destination.lastPathComponent, through: temporary, parentDescriptor: parent,
        url: destination, mode: 0o600)
    } catch let failure as PinnedFilesystem.PublicationError {
      throw EnvironmentLifecycleError.system(
        failure.step == .publish ? publishOperation : syncOperation, destination, failure.code)
    }
  }

  private func validateDestination() throws {
    let parentURL = destination.deletingLastPathComponent()
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: parentURL)
    } catch let error as PinnedFilesystemError where error.code == ENOENT && createParentDirectory {
      // Only one reviewed leaf directory may be created; no recursive mkdir or symlink traversal.
      let ancestor = try PinnedFilesystem.openDirectory(at: parentURL.deletingLastPathComponent())
      defer { Darwin.close(ancestor) }
      var metadata = stat()
      let rc = parentURL.lastPathComponent.withCString {
        fstatat(ancestor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      guard rc != 0, errno == ENOENT else {
        throw EnvironmentLifecycleError.blocked("starter parent changed; review it again")
      }
      return
    }
    defer { Darwin.close(parent) }
    var metadata = stat()
    let exists = destination.lastPathComponent.withCString {
      fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    guard exists != 0 else {
      throw EnvironmentLifecycleError.blocked(
        "destination already exists; it will not be overwritten: \(destination.path)")
    }
    guard errno == ENOENT else {
      throw EnvironmentLifecycleError.system("inspect starter destination", destination, errno)
    }
  }

  private func ensureParentDirectory() throws {
    let url = destination.deletingLastPathComponent()
    let ancestor = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(ancestor) }
    let rc = url.lastPathComponent.withCString { mkdirat(ancestor, $0, 0o700) }
    guard rc == 0 || errno == EEXIST else {
      throw EnvironmentLifecycleError.system("create reviewed starter directory", url, errno)
    }
    let parent = try PinnedFilesystem.openDirectory(at: url)
    Darwin.close(parent)
    guard fsync(ancestor) == 0 else {
      throw EnvironmentLifecycleError.system("sync reviewed starter directory", url, errno)
    }
  }
}
