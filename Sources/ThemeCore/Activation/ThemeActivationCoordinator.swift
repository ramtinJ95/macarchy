import Foundation

package struct ThemeActivationResult: Sendable {
  package let manifest: GenerationManifest
  package let reconciliation: ReconciliationRecord
}

package struct ThemeCommittedWithReconciliationError: Error, CustomStringConvertible, Sendable {
  package let manifest: GenerationManifest
  package let cause: String

  package var description: String {
    "Theme '\(manifest.themeID)' committed as generation '\(manifest.generationID)', but reconciliation failed: \(cause)"
  }
}

package struct ThemeActivationCoordinator: Sendable {
  private let activator: ThemeActivator
  private let kitty: KittyAdapter
  private let reconciler: ThemeReconciler

  package init(root: URL, kittyConfigurationURL: URL) {
    let root = root.standardizedFileURL
    activator = ThemeActivator(root: root)
    kitty = KittyAdapter(
      configurationURL: kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: .live
    )
    reconciler = ThemeReconciler(statusStore: ReconciliationStatusStore(root: root))
  }

  init(
    root: URL,
    kittyConfigurationURL: URL,
    processRunner: ProcessRunner,
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void = { _ in },
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in },
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    let root = root.standardizedFileURL
    activator = ThemeActivator(
      root: root,
      faultInjector: faultInjector,
      onThemeChanged: onThemeChanged,
      postDarwinNotification: postDarwinNotification
    )
    kitty = KittyAdapter(
      configurationURL: kittyConfigurationURL,
      includeDirective: Self.kittyIncludeDirective(root: root),
      processRunner: processRunner
    )
    reconciler = ThemeReconciler(statusStore: ReconciliationStatusStore(root: root))
  }

  package func preflight(package: ThemePackage) throws {
    try kitty.preflight()
    _ = try ThemeRenderer().render(
      package: package,
      generationID: "dry-run-\(package.id)"
    )
  }

  package func activate(package: ThemePackage) async throws -> ThemeActivationResult {
    try Task.checkCancellation()
    try kitty.preflight()
    try Task.checkCancellation()
    let manifest = try activator.activate(package: package)

    do {
      let reconciliation = try await reconciler.reconcile(
        manifest: manifest,
        adapters: [kitty.reconciliation()]
      )
      return ThemeActivationResult(manifest: manifest, reconciliation: reconciliation)
    } catch {
      throw ThemeCommittedWithReconciliationError(
        manifest: manifest,
        cause: String(describing: error)
      )
    }
  }

  private static func kittyIncludeDirective(root: URL) -> String {
    "include \(root.appending(path: "current/\(KittyAdapter.outputPath)").path)"
  }
}
