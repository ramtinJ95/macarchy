import ArgumentParser
import Foundation
import ThemeCore

/// A menu-session snapshot, not another source of configuration truth. Only the
/// selected profile's disabled bindings or declared native override may change.
struct MenuKeybindingSaveSession: Codable {
  struct Source: Codable {
    let path: URL
    let resolvedPath: URL
    let text: String?

    init(_ path: URL) throws {
      self.path = path
      resolvedPath = path.resolvingSymlinksInPath()
      if FileManager.default.fileExists(atPath: path.path) {
        let bytes = try BoundedRegularFile.read(at: resolvedPath, maximumSize: 65_536).data
        guard let text = String(data: bytes, encoding: .utf8) else {
          throw ValidationError("Profile is not UTF-8: \(path.path)")
        }
        self.text = text
      } else {
        text = nil
      }
    }
  }

  let portable: Source
  let machine: Source
  let target: URL
  let nativeSource: URL?
  let resourcesRoot: URL
  let homeDirectory: URL
  let dependencyDigests: [String: String]
  var generationID: String

  var stateRoot: URL {
    homeDirectory.appending(path: ".config/macarchy", directoryHint: .isDirectory)
  }

  static func begin(
    portableURL: URL, machineURL: URL, target: URL,
    resourcesRoot: URL, homeDirectory: URL,
    portableRequired: Bool = false, machineRequired: Bool = false,
    planner: KeybindingsPlanCommandRunner = .live
  ) throws -> (session: Self, disabledOrigin: String) {
    let portable = try Source(portableURL)
    let machine = try Source(machineURL)
    guard portable.resolvedPath != machine.resolvedPath else {
      throw ValidationError("Portable and machine profiles must be distinct files")
    }
    let layered = try PortableProfileLoader().load(
      portableAt: portableURL, portableRequired: portableRequired,
      machineAt: machineURL, machineRequired: machineRequired)
    let profile = layered.profile
    let physical = target.resolvingSymlinksInPath()
    let nativeSource = profile.keybindings.overrideURL.flatMap {
      $0.resolvingSymlinksInPath() == physical ? $0 : nil
    }
    guard nativeSource != nil || [portable.resolvedPath, machine.resolvedPath].contains(physical)
    else {
      throw ValidationError("Save target must be a profile source or its declared native override")
    }
    if nativeSource != nil {
      guard ![portable.resolvedPath, machine.resolvedPath].contains(physical),
        profile.keybindings.metadataURL?.resolvingSymlinksInPath() != physical
      else { throw ValidationError("Native override must be distinct from profiles and metadata") }
    }
    guard profile.desktop.provider == .yabaiSkhd else {
      throw ValidationError("Keybinding saves require the existing yabai-skhd provider")
    }
    let preparation = try planner.prepare(
      resourcesRoot: resourcesRoot, profileURL: portableURL, profileRequired: false,
      stateRoot: homeDirectory.appending(path: ".config/macarchy", directoryHint: .isDirectory),
      homeDirectory: homeDirectory, profile: profile)
    guard preparation.outcome == "no_change", let generation = preparation.generation.generationID
    else {
      throw ValidationError(
        "Keybindings must already be converged before enabling save-to-apply. Review setup changes first. "
          + preparation.blockingMessages.joined(separator: "; "))
    }
    let dependencies = [profile.keybindings.overrideURL, profile.keybindings.metadataURL].compactMap
    { $0 }.filter { $0 != nativeSource }
    let session = Self(
      portable: portable, machine: machine, target: target.resolvingSymlinksInPath(),
      nativeSource: nativeSource,
      resourcesRoot: resourcesRoot, homeDirectory: homeDirectory,
      dependencyDigests: try Dictionary(
        dependencies.map { ($0.path, try digest($0)) },
        uniquingKeysWith: { first, _ in first }), generationID: generation)
    return (session, layered.fieldOrigins["keybindings.disabled"]?.rawValue ?? "built-in defaults")
  }

  func validatedProfile() throws -> PortableProfile {
    if let nativeSource {
      guard nativeSource.resolvingSymlinksInPath() == target else {
        throw ValidationError("Native override link changed; reopen from the menu before applying")
      }
    }
    for source in [portable, machine] {
      guard source.path.resolvingSymlinksInPath() == source.resolvedPath else {
        throw ValidationError("Profile link changed; reopen from the menu before applying")
      }
      let current = try Source(source.path)
      if source.resolvedPath != target {
        guard current.text == source.text else {
          throw ValidationError("The other profile changed; review changes before applying")
        }
      } else {
        let loader = PortableProfileLoader()
        let before =
          try source.text.map {
            try loader.decode($0, source: source.path, resolvedSource: source.resolvedPath)
          } ?? .defaults
        let after = try loader.load(at: source.path, required: true)
        guard Self.sameExceptDisabled(before, after) else {
          throw ValidationError(
            "Saved, not applied: only keybindings.disabled edits are authorized in this session. "
              + "Source connections, providers, packages and other settings require reviewed apply."
          )
        }
      }
    }
    for (path, expected) in dependencyDigests {
      guard try Self.digest(URL(filePath: path)) == expected else {
        throw ValidationError(
          "Keybinding input changed outside this editor: \(path); review before applying")
      }
    }
    return try PortableProfileLoader().load(
      portableAt: portable.path, portableRequired: false,
      machineAt: machine.path, machineRequired: false
    ).profile
  }

  mutating func apply(runner: KeybindingsApplyCommandRunner = .live) throws -> String {
    try ActivationLock(root: stateRoot).withLock {
      let profile = try validatedProfile()
      let preparation = try runner.planner.prepare(
        resourcesRoot: resourcesRoot, profileURL: portable.path, profileRequired: false,
        stateRoot: stateRoot, homeDirectory: homeDirectory, profile: profile)
      guard preparation.outcome != "blocked",
        preparation.provider.status == .managed,
        preparation.effectiveBehavior.transaction.status == .clear,
        preparation.generation.generationID == generationID,
        let approvedDigest = preparation.composition?.inputDigest
      else {
        throw ValidationError(
          "Keybinding state changed or requires review; no save applied. "
            + preparation.blockingMessages.joined(separator: "; "))
      }
      // Planning reads native inputs. Revalidate the session after that read,
      // then bind the lifecycle's actual staged composition to this exact plan.
      guard try validatedProfile() == profile else {
        throw ValidationError("Profile changed while validating the save; save again")
      }
      let result = try runner.applyIntegrationLocked(
        resourcesRoot: resourcesRoot, profileURL: portable.path, profileRequired: false,
        stateRoot: stateRoot, homeDirectory: homeDirectory, adopt: nil,
        deferFinalization: false, profile: profile, approvedInputDigest: approvedDigest)
      guard
        let selected = KeybindingGenerationInspector().inspect(stateRoot: stateRoot).generationID
      else {
        throw ValidationError("Applied keybinding generation could not be inspected")
      }
      generationID = selected
      return result.message
    }
  }

  private static func digest(_ path: URL) throws -> String {
    sha256Digest(
      try BoundedRegularFile.read(at: path.resolvingSymlinksInPath(), maximumSize: 1_048_576).data)
  }

  private static func sameExceptDisabled(_ lhs: PortableProfile, _ rhs: PortableProfile) -> Bool {
    lhs.keybindings.overrideURL == rhs.keybindings.overrideURL
      && lhs.keybindings.metadataURL == rhs.keybindings.metadataURL
      && lhs.desktop == rhs.desktop && lhs.topBar == rhs.topBar
      && lhs.sketchyBar == rhs.sketchyBar && lhs.environment == rhs.environment
      && lhs.packages == rhs.packages && lhs.macOSPreferences == rhs.macOSPreferences
  }
}
