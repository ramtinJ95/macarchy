import Foundation
import ThemeCore

enum DesktopAggregateOperation: String, Codable, Sendable {
  case apply
  case teardown
}

enum DesktopAggregatePhase: String, Codable, Sendable {
  case mutating
  case committing
}

struct DesktopAggregateTransaction: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let operation: DesktopAggregateOperation
  let phase: DesktopAggregatePhase

  init(operation: DesktopAggregateOperation, phase: DesktopAggregatePhase) {
    schemaVersion = 1
    self.operation = operation
    self.phase = phase
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operation, phase
  }
}

struct DesktopAggregateTransactionStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "aggregate-transaction.json") }

  var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

  func read() throws -> DesktopAggregateTransaction? {
    guard exists else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 4_096).data
    let transaction = try JSONDecoder().decode(DesktopAggregateTransaction.self, from: data)
    guard transaction.schemaVersion == 1 else {
      throw DesktopAggregateError.invalidState("desktop aggregate transaction is invalid")
    }
    return transaction
  }

  func write(_ transaction: DesktopAggregateTransaction) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(transaction).write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}

enum DesktopAggregateError: Error, CustomStringConvertible, Sendable {
  case invalidState(String)
  case rolledBack(String)
  case recoveryRequired(String)

  var description: String {
    switch self {
    case .invalidState(let reason):
      "desktop aggregate is blocked: \(reason)"
    case .rolledBack(let reason):
      "desktop aggregate failed and rolled back: \(reason)"
    case .recoveryRequired(let reason):
      "desktop aggregate recovery is required: \(reason)"
    }
  }
}

struct DesktopPrerequisiteStatus: Encodable, Equatable, Sendable {
  enum Status: String, Encodable, Sendable {
    case present
    case missing
  }

  let id: String
  let status: Status
  let requirement: String
  let remediation: String
}

struct DesktopPrerequisiteInspector: Sendable {
  let inspect: @Sendable (PortableProfile, URL) -> [DesktopPrerequisiteStatus]

  static let assumed = Self { _, _ in [] }

  static let live = Self { profile, homeDirectory in
    let selected = Set(
      ["macos-26", "arm64", "homebrew"]
        + (profile.desktop.provider == .yabaiSkhd ? ["skhd", "yabai"] : [])
        + (profile.topBar == .sketchybar ? ["sketchybar"] : [])
    )
    return DependencyProfile.personal(homeDirectory: homeDirectory).capabilities
      .filter { selected.contains($0.id) }
      .map {
        DesktopPrerequisiteStatus(
          id: $0.id,
          status: $0.isAvailable() ? .present : .missing,
          requirement: $0.requirement,
          remediation: remediation($0.remediation)
        )
      }
      .sorted { $0.id < $1.id }
  }

  private static func remediation(_ remediation: DependencyRemediation) -> String {
    switch remediation {
    case .cask(let package):
      "Install Homebrew cask \(package)."
    case .formula(let package):
      "Install Homebrew formula \(package)."
    case .external(let instruction):
      instruction
    }
  }
}

struct DesktopKeybindingPlan: Encodable, Equatable, Sendable {
  let outcome: String
  let effectiveStatus: String
  let message: String
  let generationID: String?
  let providerStatus: String
  let ownership: String
  let adoptionEvidenceDigest: String?
  let transactionStatus: String

  var succeeded: Bool { outcome != "blocked" }
  var transactionPending: Bool { transactionStatus != "clear" }
}

struct DesktopKeybindingOrchestrator: Sendable {
  let runner: KeybindingsApplyCommandRunner
  let planner: KeybindingsPlanCommandRunner

  static let live = Self(runner: .live, planner: .live)

  func plan(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL
  ) throws -> DesktopKeybindingPlan {
    Self.summary(
      try planner.prepare(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        homeDirectory: homeDirectory
      )
    )
  }

  func preview(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?
  ) throws -> DesktopKeybindingPlan {
    let execution = try runner.preview(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      adopt: adopt,
      json: true
    )
    var result = try plan(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory
    )
    if !execution.succeeded {
      result = DesktopKeybindingPlan(
        outcome: "blocked",
        effectiveStatus: result.effectiveStatus,
        message: execution.output,
        generationID: result.generationID,
        providerStatus: result.providerStatus,
        ownership: result.ownership,
        adoptionEvidenceDigest: result.adoptionEvidenceDigest,
        transactionStatus: result.transactionStatus
      )
    }
    return result
  }

  func applyLocked(
    resourcesRoot: URL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    adopt: String?
  ) throws -> SetupIntegrationResult {
    try runner.applyIntegrationLocked(
      resourcesRoot: resourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      adopt: adopt,
      deferFinalization: true
    )
  }

  func teardownLocked(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool
  ) throws -> SetupIntegrationResult {
    try runner.teardownLocked(
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      dryRun: dryRun,
      deferFinalization: !dryRun
    )
  }

  func recoverLocked(stateRoot: URL, homeDirectory: URL) throws {
    try runner.recoverPendingLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
  }

  func rollbackLocked(stateRoot: URL, homeDirectory: URL) throws {
    try runner.rollbackDeferredLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
  }

  func commitLocked(stateRoot: URL, homeDirectory: URL) throws {
    try runner.commitDeferredLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
  }

  private static func summary(
    _ preparation: KeybindingsPlanPreparation
  ) -> DesktopKeybindingPlan {
    DesktopKeybindingPlan(
      outcome: preparation.outcome,
      effectiveStatus: preparation.effectiveBehavior.status.rawValue,
      message: preparation.effectiveBehavior.statusMessage,
      generationID: preparation.generation.generationID,
      providerStatus: preparation.provider.status.rawValue,
      ownership: preparation.provider.ownership,
      adoptionEvidenceDigest: preparation.provider.adoptionEvidenceDigest,
      transactionStatus: preparation.effectiveBehavior.transaction.status.rawValue
    )
  }
}

struct DesktopAggregateCoordinator: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let keybindings: DesktopKeybindingOrchestrator?
  let faultInjector: @Sendable (YabaiTransactionCheckpoint) throws -> Void
  let sketchyBarFaultInjector: @Sendable (SketchyBarTransactionCheckpoint) throws -> Void

  func recoverLocked(stateRoot: URL, homeDirectory: URL) throws {
    let store = DesktopAggregateTransactionStore(stateRoot: stateRoot)
    if let transaction = try store.read() {
      switch (transaction.phase, transaction.operation) {
      case (.mutating, .apply):
        try rollbackApplyLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
      case (.mutating, .teardown):
        try rollbackTeardownLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
      case (.committing, .apply):
        try commitApplyLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
      case (.committing, .teardown):
        try commitTeardownLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
      }
      try store.remove()
      return
    }

    _ = try sketchyBarTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .recoverPendingLocked()
    try keybindings?.recoverLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
    let yabaiStore = YabaiTransactionStore(stateRoot: stateRoot)
    if let pending = try yabaiStore.read() {
      let transaction = yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      switch pending.operation {
      case .apply:
        try transaction.recoverApply(pending, lifecycle: lifecycle)
      case .teardown:
        try transaction.completeTeardown(pending, lifecycle: lifecycle)
      }
    }
  }

  func rollbackApplyLocked(stateRoot: URL, homeDirectory: URL) throws {
    try sketchyBarTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .rollbackDeferredLocked()
    try keybindings?.rollbackLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
    try yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .rollbackDeferred(lifecycle: lifecycle)
  }

  func commitApplyLocked(stateRoot: URL, homeDirectory: URL) throws {
    try yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .commitDeferred(lifecycle: lifecycle)
    try keybindings?.commitLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
    try sketchyBarTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .commitDeferredLocked()
  }

  func rollbackTeardownLocked(stateRoot: URL, homeDirectory: URL) throws {
    try yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .rollbackDeferred(lifecycle: lifecycle)
    try keybindings?.rollbackLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
    try sketchyBarTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .rollbackDeferredLocked()
  }

  func commitTeardownLocked(stateRoot: URL, homeDirectory: URL) throws {
    try sketchyBarTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .commitDeferredLocked()
    try keybindings?.commitLocked(stateRoot: stateRoot, homeDirectory: homeDirectory)
    try yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory)
      .commitDeferred(lifecycle: lifecycle)
  }

  func teardownYabaiLocked(
    stateRoot: URL,
    homeDirectory: URL,
    dryRun: Bool,
    deferFinalization: Bool = false
  ) throws -> ApplyResult {
    try yabaiTransaction(stateRoot: stateRoot, homeDirectory: homeDirectory).teardownLocked(
      lifecycle: lifecycle,
      faultInjector: faultInjector,
      dryRun: dryRun,
      deferFinalization: deferFinalization
    )
  }

  func sketchyBarTransaction(
    stateRoot: URL,
    homeDirectory: URL
  ) -> SketchyBarProviderTransaction {
    SketchyBarProviderTransaction(
      homeDirectory: homeDirectory,
      stateRoot: stateRoot,
      lifecycle: sketchyBarLifecycle,
      coreRuntime: sketchyBarCoreRuntime ?? .live(stateRoot: stateRoot),
      faultInjector: sketchyBarFaultInjector
    )
  }

  private func yabaiTransaction(
    stateRoot: URL,
    homeDirectory: URL
  ) -> YabaiProviderTransaction {
    YabaiProviderTransaction(homeDirectory: homeDirectory, stateRoot: stateRoot)
  }
}

struct DesktopThemeAdapterStatus: Encodable, Equatable, Sendable {
  let adapterID: String
  let requirement: String
  let status: String
  let message: String?
}

struct DesktopThemeReconciliation: Encodable, Equatable, Sendable {
  let generationID: String
  let results: [DesktopThemeAdapterStatus]
  let succeeded: Bool
}

struct DesktopThemeController: Sendable {
  let reconcile:
    @Sendable (_ adapterIDs: [String], _ stateRoot: URL, _ consumerPaths: ThemeConsumerPaths)
      async throws -> DesktopThemeReconciliation
  let inspect:
    @Sendable (_ adapterIDs: [String], _ stateRoot: URL, _ consumerPaths: ThemeConsumerPaths)
      throws -> [DesktopThemeAdapterStatus]

  static let live = Self(
    reconcile: { adapterIDs, stateRoot, consumerPaths in
      let result = try await ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths
      ).reconcile(adapterIDs: adapterIDs)
      let selected = Set(adapterIDs)
      let results = result.record.results.filter { selected.contains($0.adapterID) }
      return DesktopThemeReconciliation(
        generationID: result.manifest.generationID,
        results: results.map {
          DesktopThemeAdapterStatus(
            adapterID: $0.adapterID,
            requirement: $0.requirement.rawValue,
            status: $0.status.rawValue,
            message: $0.message
          )
        },
        succeeded: !hasRequiredReconciliationFailure(results)
      )
    },
    inspect: { adapterIDs, stateRoot, consumerPaths in
      try ThemeActivationCoordinator(
        root: stateRoot,
        consumerPaths: consumerPaths
      ).inspectAdapters(adapterIDs, includeRuntimeChecks: true).map {
        DesktopThemeAdapterStatus(
          adapterID: $0.adapterID,
          requirement: $0.requirement.rawValue,
          status: $0.status.rawValue,
          message: $0.message
        )
      }
    }
  )
}
