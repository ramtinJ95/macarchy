import Foundation

package enum ManualThemePayloadError: Error, CustomStringConvertible, Equatable, Sendable {
  case invalidText(String)
  case noActiveTheme
  case unavailableInActiveGeneration(target: String, themeID: String)
  case unsupportedTarget(String, available: [String])

  package var description: String {
    switch self {
    case .invalidText(let target):
      "The active '\(target)' theme payload is not valid UTF-8 text"
    case .noActiveTheme:
      "No active theme; activate one with 'macarchy theme set <theme-id>'"
    case .unavailableInActiveGeneration(let target, let themeID):
      "Active theme '\(themeID)' does not contain a '\(target)' import payload; reactivate it with the current Macarchy version"
    case .unsupportedTarget(let target, let available):
      "Unsupported manual theme target '\(target)'. Available targets: \(available.joined(separator: ", "))"
    }
  }
}

package struct ManualThemePayloadStore: Sendable {
  private let root: URL
  private let catalog: ConsumerCatalog

  package init(root: URL, catalog: ConsumerCatalog = .shared) {
    self.root = root.standardizedFileURL
    self.catalog = catalog
  }

  package var availableTargetIDs: [String] {
    catalog.manualPayloadTargets.map(\.id).sorted()
  }

  package func payload(targetID: String) throws -> String {
    guard let target = catalog.manualPayloadTarget(id: targetID) else {
      throw ManualThemePayloadError.unsupportedTarget(
        targetID,
        available: availableTargetIDs
      )
    }

    let manifest: GenerationManifest
    do {
      manifest = try ReconciliationStatusStore(root: root).activeManifest()
    } catch ReconciliationStatusError.noActiveGeneration {
      throw ManualThemePayloadError.noActiveTheme
    }
    guard manifest.artifacts[target.artifactPath] != nil else {
      throw ManualThemePayloadError.unavailableInActiveGeneration(
        target: targetID,
        themeID: manifest.themeID
      )
    }

    let artifactURL = root.appending(
      path: "generations/\(manifest.generationID)/\(target.artifactPath)"
    )
    let data = try BoundedRegularFile.read(at: artifactURL).data
    guard let payload = String(data: data, encoding: .utf8) else {
      throw ManualThemePayloadError.invalidText(targetID)
    }
    return payload
  }
}
