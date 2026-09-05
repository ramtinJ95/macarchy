import Foundation
import ThemeCore

extension EnvironmentProviderInspector {
  func inspectHerdr(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentHerdrOwnership?,
    previouslyEnabled: Bool
  ) throws -> (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: EnvironmentHerdrOwnership?,
    externalEvidence: EnvironmentEntryEvidence?
  ) {
    guard composition.profile.presets.herdr || ownership != nil else {
      return (nil, nil, nil)
    }
    let url = homeDirectory.appending(path: ".config/herdr/config.toml")
    let transaction = EnvironmentHerdrFileTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot
    )
    if let ownership {
      if previouslyEnabled {
        try transaction.preflight(ownership)
      } else {
        try transaction.preflightOriginal(ownership)
      }
      let enabling = composition.profile.presets.herdr
      let proposed =
        enabling
        ? ownership.replacingManagedTheme(try HerdrAdapter.desiredTheme(root: stateRoot))
        : ownership
      return (
        EnvironmentEntryInspection(
          id: "herdr_configuration",
          path: url.path,
          status: enabling == previouslyEnabled
            ? (enabling ? "managed" : "external") : "restoration_required",
          ownership: "macarchy",
          message: enabling
            ? "The Herdr theme surface is managed."
            : "The disabled Herdr theme surface is restored to its original boundary.",
          evidence: nil
        ),
        proposed,
        nil
      )
    }
    guard composition.profile.presets.herdr else { return (nil, nil, nil) }

    let adapter = HerdrAdapter(
      root: stateRoot,
      configurationURL: url,
      executableURL: HerdrAdapter.executableURL(homeDirectory: homeDirectory),
      controlIsAvailable: { true }
    )
    let evidence = try capture(url, directoryLink: nil)
    let herdrDirectory = url.deletingLastPathComponent()
    let hasExternalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    let directoryEvidence =
      hasExternalAncestor ? try capture(herdrDirectory, directoryLink: nil) : nil
    if hasExternalAncestor {
      guard directoryEvidence?.kind == .symbolicLink,
        try !hasSymlinkAncestor(herdrDirectory, stoppingAt: homeDirectory)
      else {
        throw EnvironmentLifecycleError.blocked(
          "only the reviewed ~/.config/herdr directory-symlink topology is writable"
        )
      }
    }
    guard evidence.kind != .symbolicLink else {
      throw EnvironmentLifecycleError.blocked(
        "Herdr config.toml itself must not be a symbolic link"
      )
    }
    let resolved = url.resolvingSymlinksInPath()
    let legacy = try adapter.legacyOwnershipEvidence()
    let desired = try HerdrAdapter.desiredTheme(root: stateRoot)
    let original: String
    let current: String
    let migratedLegacy: Bool
    if let legacy {
      original = legacy.originalConfiguration
      current = legacy.currentConfiguration
      migratedLegacy = true
      guard
        try EnvironmentHerdrDocument.matchesManaged(
          current, desired: desired, source: url
        )
      else {
        throw EnvironmentLifecycleError.drift(
          "authenticated legacy Herdr state does not match the active generation"
        )
      }
    } else if evidence.kind == .regularFile {
      current = try configurationText(at: url, evidence: evidence)
      original = current
      migratedLegacy = false
    } else if evidence.kind == .absent, !hasExternalAncestor {
      current = ""
      original = ""
      migratedLegacy = false
    } else {
      throw EnvironmentLifecycleError.blocked(
        "Herdr configuration cannot be safely adopted"
      )
    }
    let proposed = try EnvironmentHerdrDocument.ownership(
      original: original,
      source: url,
      resolvedSource: resolved,
      originalFileExisted: evidence.kind == .regularFile,
      directoryLink: directoryEvidence,
      migratedLegacy: migratedLegacy,
      managedTheme: desired
    )
    return (
      EnvironmentEntryInspection(
        id: "herdr_configuration",
        path: url.path,
        status: migratedLegacy
          ? "migration_required"
          : (evidence.kind == .absent ? "install_required" : "adoption_required"),
        ownership: migratedLegacy ? "legacy_adapter" : "external",
        message: migratedLegacy
          ? "Authenticated complete legacy Herdr ownership will migrate into the environment."
          : (hasExternalAncestor
            ? "The reviewed Herdr directory symlink will be preserved while its resolved config target is adopted."
            : "The Herdr theme surface requires reviewed adoption."),
        evidence: evidence
      ),
      proposed,
      evidence.kind == .absent ? nil : evidence
    )
  }
}
