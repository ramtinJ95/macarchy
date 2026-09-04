import Foundation
import ThemeCore

extension EnvironmentProviderInspector {
  func inspectSpicetify(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentSpicetifyOwnership?,
    legacyOwned: Bool,
    externallyAuthoritative: Bool
  ) throws -> (
    entry: EnvironmentEntryInspection?,
    proposedOwnership: EnvironmentSpicetifyOwnership?,
    externalEvidence: EnvironmentEntryEvidence?
  ) {
    guard
      composition.profile.presets.spicetify || ownership != nil || legacyOwned
        || externallyAuthoritative
    else { return (nil, nil, nil) }

    let url = homeDirectory.appending(path: ".config/spicetify/config-xpui.ini")
    if legacyOwned {
      let evidence = try capture(url, directoryLink: nil)
      guard evidence.kind == .regularFile,
        try selectionIsManaged(at: url, evidence: evidence)
      else { throw EnvironmentLifecycleError.drift("legacy setup-owned Spicetify selectors") }
      return (
        EnvironmentEntryInspection(
          id: "spicetify_configuration",
          path: url.path,
          status: "external",
          ownership: "legacy_setup",
          message: "The working legacy setup-owned Spicetify selector tuple is preserved.",
          evidence: evidence
        ), nil, nil
      )
    }

    if let ownership {
      guard ownership.path == url.path,
        try !hasSymlinkAncestor(url, stoppingAt: homeDirectory)
      else { throw EnvironmentLifecycleError.blocked("Spicetify ownership path is invalid") }
      let evidence = try capture(url, directoryLink: nil)
      let exact =
        try evidence.kind == .regularFile
        && selectionIsManaged(at: url, evidence: evidence)
      return (
        EnvironmentEntryInspection(
          id: "spicetify_configuration",
          path: url.path,
          status: exact
            ? (composition.profile.presets.spicetify ? "managed" : "restoration_required")
            : "drifted",
          ownership: "macarchy",
          message: exact
            ? (composition.profile.presets.spicetify
              ? "The Spicetify current_theme and color_scheme selectors are managed."
              : "The disabled Spicetify selectors will be restored exactly.")
            : "The owned Spicetify selectors drifted.",
          evidence: nil
        ),
        composition.profile.presets.spicetify ? ownership : nil,
        nil
      )
    }

    if externallyAuthoritative {
      let evidence = try capture(url, directoryLink: nil)
      let exact = try spicetifyExternalTupleIsExact(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        configurationEvidence: evidence
      )
      return (
        EnvironmentEntryInspection(
          id: "spicetify_configuration",
          path: url.path,
          status: exact ? "external" : "drifted",
          ownership: "external_exact",
          message: exact
            ? "The exact Spicetify selector and color-link tuple remains externally owned."
            : "The externally owned Spicetify tuple drifted.",
          evidence: evidence
        ), nil, nil
      )
    }

    guard composition.profile.presets.spicetify else { return (nil, nil, nil) }
    let evidence = try capture(url, directoryLink: nil)
    let externalAncestor = try hasSymlinkAncestor(url, stoppingAt: homeDirectory)
    if evidence.kind == .symbolicLink || externalAncestor {
      let exact = try spicetifyExternalTupleIsExact(
        homeDirectory: homeDirectory,
        stateRoot: stateRoot,
        configurationEvidence: evidence
      )
      return (
        EnvironmentEntryInspection(
          id: "spicetify_configuration",
          path: url.path,
          status: exact ? "external" : "unsupported",
          ownership: exact ? "external_exact" : "external",
          message: exact
            ? "The complete exact Stow selector and color-link tuple remains externally owned."
            : "A symlink-owned Spicetify configuration requires the complete exact selector and color-link tuple.",
          evidence: evidence
        ), nil, exact ? evidence : nil
      )
    }
    guard evidence.kind == .regularFile else {
      return (
        EnvironmentEntryInspection(
          id: "spicetify_configuration",
          path: url.path,
          status: "unsupported",
          ownership: "external",
          message:
            "Spicetify config-xpui.ini must already be an ordinary file or a complete exact Stow tuple.",
          evidence: evidence
        ), nil, nil
      )
    }
    let data = try configurationData(at: url, evidence: evidence)
    let originalSelection = try SetupOwnershipManager().spicetifySelection(data, target: url)
    let proposedOwnership = EnvironmentSpicetifyOwnership(
      path: url.path,
      originalSelection: originalSelection
    )
    guard proposedOwnership.hasValidShape else {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify selector values exceed the bounded restoration evidence contract"
      )
    }
    return (
      EnvironmentEntryInspection(
        id: "spicetify_configuration",
        path: url.path,
        status: "adoption_required",
        ownership: "external",
        message:
          "Only current_theme and color_scheme require reviewed adoption; all other Spicetify state remains external.",
        evidence: evidence
      ),
      proposedOwnership,
      evidence
    )
  }

  func spicetifyExternalTupleIsExact(
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence? = nil
  ) throws -> Bool {
    let configuration = homeDirectory.appending(path: ".config/spicetify/config-xpui.ini")
    let evidence = try configurationEvidence ?? capture(configuration, directoryLink: nil)
    guard evidence.kind == .regularFile || evidence.kind == .symbolicLink else { return false }
    guard try selectionIsManaged(at: configuration, evidence: evidence) else { return false }
    let color = allManagedEntries(homeDirectory: homeDirectory, stateRoot: stateRoot)
      .first { $0.id == .spicetifyColor }!
    let colorEvidence = try capture(color.url, directoryLink: nil)
    return colorEvidence.kind == .symbolicLink && colorEvidence.linkDestination == color.target
  }

  private func selectionIsManaged(
    at url: URL,
    evidence: EnvironmentEntryEvidence
  ) throws -> Bool {
    let data = try configurationData(at: url, evidence: evidence)
    return try SetupOwnershipManager().spicetifySelectorsAreExternal(data, target: url)
  }

  private func configurationData(
    at url: URL,
    evidence: EnvironmentEntryEvidence
  ) throws -> Data {
    let target = url.resolvingSymlinksInPath().standardizedFileURL
    let data = try BoundedRegularFile.read(
      at: target,
      maximumSize: SetupOwnershipManager.maximumConfigurationSize
    ).data
    if evidence.kind == .regularFile,
      evidence.contentDigest != nil,
      evidence.contentDigest != sha256Digest(data)
    {
      throw EnvironmentLifecycleError.blocked(
        "Spicetify configuration changed during inspection: \(url.path)"
      )
    }
    return data
  }
}
