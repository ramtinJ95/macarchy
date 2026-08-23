import Foundation

struct ThemeActivationResult: Sendable {
  let manifest: GenerationManifest
  let reconciliation: ReconciliationRecord
}

struct ThemeCommittedWithReconciliationError: Error, CustomStringConvertible, Sendable {
  let manifest: GenerationManifest
  let cause: String

  var description: String {
    "Theme '\(manifest.themeID)' committed as generation '\(manifest.generationID)', but reconciliation failed: \(cause)"
  }
}

struct ThemeActivationCoordinator: Sendable {
  private let activator: ThemeActivator
  private let kitty: KittyAdapter
  private let reconciler: ThemeReconciler

  init(root: URL, kittyConfigurationURL: URL) {
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

  func activate(package: ThemePackage) async throws -> ThemeActivationResult {
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
