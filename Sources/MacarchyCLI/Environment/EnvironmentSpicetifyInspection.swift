import Foundation
import ThemeCore

extension EnvironmentProviderInspector {
  /// Spicetify adopts only an ordinary config-xpui.ini and accepts an external symlink only as a
  /// complete exact tuple; it never installs the file.
  func inspectSpicetify(
    composition: EnvironmentComposition,
    homeDirectory: URL,
    stateRoot: URL,
    ownership: EnvironmentSpicetifyOwnership?,
    legacyOwned: Bool,
    externallyAuthoritative: Bool
  ) throws -> KeyOwnedInspection<EnvironmentSpicetifyOwnership> {
    try inspectLinkedSelector(
      .spicetify, composition: composition, homeDirectory: homeDirectory, stateRoot: stateRoot,
      ownership: ownership, legacyOwned: legacyOwned,
      externallyAuthoritative: externallyAuthoritative,
      isManaged: { url, evidence in try selectionIsManaged(at: url, evidence: evidence) },
      inspectUnowned: { url, evidence, externalAncestor in
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
              status: exact ? .external : .unsupported,
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
              status: .unsupported,
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
            status: .adoptionRequired,
            ownership: "external",
            message:
              "Only current_theme and color_scheme require reviewed adoption; all other Spicetify state remains external.",
            evidence: evidence
          ),
          proposedOwnership,
          evidence
        )
      })
  }

  func spicetifyExternalTupleIsExact(
    homeDirectory: URL,
    stateRoot: URL,
    configurationEvidence: EnvironmentEntryEvidence? = nil
  ) throws -> Bool {
    let configuration = homeDirectory.appending(path: ConsumerHomePath.spicetifyConfiguration)
    let evidence = try configurationEvidence ?? capture(configuration, directoryLink: nil)
    guard evidence.kind == .regularFile || evidence.kind == .symbolicLink else { return false }
    guard try selectionIsManaged(at: configuration, evidence: evidence) else { return false }
    return try externalLinksAreExact(
      [.spicetifyColor], homeDirectory: homeDirectory, stateRoot: stateRoot)
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
      maximumSize: BoundedRegularFile.maximumSize
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
