import Foundation

struct AdapterObservation: Equatable, Sendable {
  let status: AdapterStatus
  let message: String?

  init(status: AdapterStatus, message: String? = nil) {
    self.status = status
    self.message = message
  }
}

struct RenderedAdapterArtifact: Sendable {
  let relativePath: String
  let data: Data
}

struct AdapterReconciliationContext: Sendable {
  let root: URL
  let manifest: GenerationManifest

  var generationURL: URL {
    root.appending(
      path: "generations/\(manifest.generationID)",
      directoryHint: .isDirectory
    )
  }
}

// This is a compile-in lifecycle boundary, not a runtime plugin interface.
protocol ThemeAdapter: Sendable {
  var id: String { get }
  var requirement: AdapterRequirement { get }

  func inspect(context: AdapterReconciliationContext) throws -> AdapterObservation
  func preflight(root: URL, package: ThemePackage) throws
  func render(package: ThemePackage, generationID: String) throws -> [RenderedAdapterArtifact]
  func reconcile(context: AdapterReconciliationContext) async -> AdapterObservation
}
