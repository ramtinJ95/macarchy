import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeUndoCommandTests {
  @Test func undoWalksBackThroughBackgroundAndThemeChanges() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("catppuccin-mocha", "mocha-1"))
      let activation = fixture.activation()
      let wave = try repository.package(id: "kanagawa-wave")

      _ = try await activate(activation, wave, background: nil, stateRoot: stateRoot)
      _ = try await activate(activation, wave, background: "wave-2", stateRoot: stateRoot)
      #expect(
        try selections(stateRoot) == [
          "catppuccin-mocha#mocha-1", "kanagawa-wave#default", "kanagawa-wave#wave-2",
        ])

      let runner = fixture.undoRunner(activation)
      let background = try await runner.execute(
        repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
        dryRun: false)
      #expect(background.succeeded)
      #expect(
        background.output.hasPrefix(
          "Undo: returning to theme 'kanagawa-wave' with background 'default'.\n"
            + "Activated 'kanagawa-wave'"))
      #expect(fixture.selection == "kanagawa-wave#default")
      #expect(try selections(stateRoot) == ["catppuccin-mocha#mocha-1", "kanagawa-wave#default"])

      let theme = try await runner.execute(
        repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
        dryRun: false)
      #expect(theme.succeeded)
      #expect(fixture.selection == "catppuccin-mocha#mocha-1")
      #expect(try selections(stateRoot) == ["catppuccin-mocha#mocha-1"])

      await #expect(throws: ThemeUndoError.nothingToUndo) {
        _ = try await runner.execute(
          repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
          dryRun: false)
      }
      #expect(
        fixture.activations == [
          "kanagawa-wave#-", "kanagawa-wave#wave-2", "kanagawa-wave#default",
          "catppuccin-mocha#mocha-1",
        ])
    }
  }

  @Test func dryRunPreflightsTheTargetWithoutChangingStateOrHistory() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("catppuccin-mocha", "mocha-1"))
      let activation = fixture.activation()
      _ = try await activate(
        activation, try repository.package(id: "kanagawa-wave"), background: nil,
        stateRoot: stateRoot)
      let history = try ThemeHistoryStore(root: stateRoot).load()

      let execution = try await fixture.undoRunner(activation).execute(
        repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
        dryRun: true)

      #expect(execution.succeeded)
      #expect(
        execution.output.hasPrefix(
          "Undo would return to theme 'catppuccin-mocha' with background 'mocha-1'."))
      #expect(fixture.preflights == ["catppuccin-mocha#mocha-1"])
      #expect(fixture.selection == "kanagawa-wave#default")
      #expect(try ThemeHistoryStore(root: stateRoot).load() == history)
    }
  }

  @Test func undoWithoutAnActiveThemeOrHistoryFailsWithoutActivating() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("catppuccin-mocha", "mocha-1"))
      let activation = fixture.activation()

      await #expect(throws: ThemeUndoError.nothingToUndo) {
        _ = try await fixture.undoRunner(activation).execute(
          repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
          dryRun: false)
      }

      let inactive = ThemeUndoCommandRunner(
        activeManifest: { _ in throw ReconciliationStatusError.noActiveGeneration },
        loadHistory: { try ThemeHistoryStore(root: $0).load() },
        activation: activation
      )
      await #expect(throws: ThemeUndoError.noActiveTheme) {
        _ = try await inactive.execute(
          repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
          dryRun: false)
      }
      #expect(fixture.activations.isEmpty)
    }
  }

  @Test func undoToARemovedThemeFailsAndKeepsTheHistory() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("kanagawa-wave", "wave-1"))
      let activation = fixture.activation()
      let history = [
        ThemeHistoryEntry(
          manifest: selectionManifest("removed-theme", nil), recordedAt: "2026-11-08T00:00:00Z"),
        ThemeHistoryEntry(
          manifest: selectionManifest("kanagawa-wave", "wave-1"),
          recordedAt: "2026-11-08T00:00:00Z"),
      ]
      try ThemeHistoryStore(root: stateRoot).persist(history)

      await #expect(throws: (any Error).self) {
        _ = try await fixture.undoRunner(activation).execute(
          repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
          dryRun: false)
      }
      #expect(fixture.activations.isEmpty)
      #expect(try ThemeHistoryStore(root: stateRoot).load() == history)
    }
  }

  @Test func undoToAnEntryWithoutABackgroundRecordsTheBackgroundThatCommitted() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("kanagawa-wave", "wave-1"))
      try ThemeHistoryStore(root: stateRoot).persist([
        ThemeHistoryEntry(
          manifest: selectionManifest("catppuccin-mocha", nil), recordedAt: "2026-11-08T00:00:00Z"),
        ThemeHistoryEntry(
          manifest: selectionManifest("kanagawa-wave", "wave-1"),
          recordedAt: "2026-11-08T00:00:00Z"),
      ])
      let runner = fixture.undoRunner(fixture.activation())

      let execution = try await runner.execute(
        repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
        dryRun: false)

      #expect(execution.succeeded)
      #expect(execution.output.hasPrefix("Undo: returning to theme 'catppuccin-mocha'.\n"))
      #expect(fixture.selection == "catppuccin-mocha#default")
      #expect(try selections(stateRoot) == ["catppuccin-mocha#default"])
      await #expect(throws: ThemeUndoError.nothingToUndo) {
        _ = try await runner.execute(
          repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
          dryRun: false)
      }
    }
  }

  @Test func undoReturnsAHistoryNoticeWithoutFailing() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("kanagawa-wave", "wave-1"))
      let history = [
        ThemeHistoryEntry(
          manifest: selectionManifest("catppuccin-mocha", "mocha-1"),
          recordedAt: "2026-11-08T00:00:00Z"),
        ThemeHistoryEntry(
          manifest: selectionManifest("kanagawa-wave", "wave-1"),
          recordedAt: "2026-11-08T00:00:00Z"),
      ]
      try ThemeHistoryStore(root: stateRoot).persist(history)
      let activation = fixture.activation(persist: { _, _ in throw TestError.historyWrite })

      let execution = try await fixture.undoRunner(activation).execute(
        repository: repository, stateRoot: stateRoot, consumerPaths: testConsumerPaths(),
        dryRun: false)

      #expect(execution.succeeded)
      #expect(fixture.selection == "catppuccin-mocha#mocha-1")
      #expect(
        execution.notice
          == "Theme history was not updated, so undo may skip this change: history write denied.")
      #expect(execution.output.contains("Notice: Theme history was not updated"))
      #expect(try ThemeHistoryStore(root: stateRoot).load() == history)
    }
  }

  @Test func aHistoryWriteFailureIsANoticeOnTheCommittedActivation() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let fixture = UndoFixture(initial: selectionManifest("catppuccin-mocha", "mocha-1"))
      let activation = fixture.activation(persist: { _, _ in throw TestError.historyWrite })

      let outcome = try await activate(
        activation, try repository.package(id: "kanagawa-wave"), background: nil,
        stateRoot: stateRoot)

      guard case .committed(let result, let requiredFailure) = outcome else {
        Issue.record("Expected a committed activation, got \(outcome)")
        return
      }
      #expect(!requiredFailure)
      #expect(result.manifest.themeID == "kanagawa-wave")
      #expect(
        result.notice
          == "Theme history was not updated, so undo may skip this change: history write denied.")
    }
  }

  @Test func anUnreadableHistoryStartsAgainWithANotice() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      let url = stateRoot.appending(path: "state/theme-history.json")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("not json".utf8).write(to: url)
      let fixture = UndoFixture(initial: selectionManifest("catppuccin-mocha", "mocha-1"))

      let outcome = try await activate(
        fixture.activation(), try repository.package(id: "kanagawa-wave"), background: nil,
        stateRoot: stateRoot)

      guard case .committed(let result, _) = outcome else {
        Issue.record("Expected a committed activation, got \(outcome)")
        return
      }
      #expect(
        result.notice?.hasPrefix("Theme history could not be read and was started again") == true)
      #expect(try selections(stateRoot) == ["catppuccin-mocha#mocha-1", "kanagawa-wave#default"])
    }
  }

  @Test func aPrecommitFailureRecordsNothing() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-undo") { stateRoot in
      var activation = ThemeActivationService(
        preflight: { _, _, _, _ in },
        activate: { _, _, _, _, _ in throw TestError.activation },
        slackIsEnabled: { _ in false }
      )
      activation.history = UndoFixture(initial: selectionManifest("catppuccin-mocha", nil))
        .recorder(persist: { try ThemeHistoryStore(root: $1).persist($0) })

      let outcome = try await activate(
        activation, try repository.package(id: "kanagawa-wave"), background: nil,
        stateRoot: stateRoot)

      guard case .precommitFailure = outcome else {
        Issue.record("Expected a precommit failure, got \(outcome)")
        return
      }
      #expect(try ThemeHistoryStore(root: stateRoot).load() == [])
    }
  }

  private var repository: ThemeRepository {
    ThemeRepository(
      builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    )
  }
}

/// A canonical selection that fake activations replace, and the calls they received.
private final class UndoFixture: Sendable {
  private let canonical: Mutex<GenerationManifest>
  private struct Calls {
    var preflights: [String] = []
    var activations: [String] = []
  }

  private let calls = Mutex(Calls())

  init(initial: GenerationManifest) {
    canonical = Mutex(initial)
  }

  var selection: String { canonical.withLock { selectionLabel($0) } }
  var preflights: [String] { calls.withLock { $0.preflights } }
  var activations: [String] { calls.withLock { $0.activations } }

  func recorder(
    persist: @escaping @Sendable ([ThemeHistoryEntry], URL) throws -> Void
  ) -> ThemeHistoryRecorder {
    ThemeHistoryRecorder(
      activeManifest: { _ in self.canonical.withLock { $0 } },
      load: { try ThemeHistoryStore(root: $0).load() },
      persist: persist,
      now: { "2026-11-08T00:00:00Z" }
    )
  }

  /// Activation that selects the requested background, or `default` when none is requested.
  func activation(
    persist: @escaping @Sendable ([ThemeHistoryEntry], URL) throws -> Void = {
      try ThemeHistoryStore(root: $1).persist($0)
    }
  ) -> ThemeActivationService {
    var service = ThemeActivationService(
      preflight: { package, backgroundID, _, _ in
        self.calls.withLock { $0.preflights.append("\(package.id)#\(backgroundID ?? "-")") }
      },
      activate: { package, backgroundID, _, _, _ in
        self.calls.withLock { $0.activations.append("\(package.id)#\(backgroundID ?? "-")") }
        let manifest = selectionManifest(package.id, backgroundID ?? "default")
        self.canonical.withLock { $0 = manifest }
        return ThemeActivationResult(
          manifest: manifest,
          reconciliation: try ReconciliationRecord(manifest: manifest, results: [])
        )
      },
      slackIsEnabled: { _ in false }
    )
    service.history = recorder(persist: persist)
    return service
  }

  func undoRunner(_ activation: ThemeActivationService) -> ThemeUndoCommandRunner {
    ThemeUndoCommandRunner(
      activeManifest: { _ in self.canonical.withLock { $0 } },
      loadHistory: { try ThemeHistoryStore(root: $0).load() },
      activation: activation
    )
  }
}

private func activate(
  _ activation: ThemeActivationService,
  _ package: ThemePackage,
  background: String?,
  stateRoot: URL
) async throws -> ThemeActivationOutcome {
  try await activation.activateLocked(
    package: package,
    backgroundID: background,
    stateRoot: stateRoot,
    consumerPaths: testConsumerPaths(),
    expectedActiveGenerationID: nil
  )
}

private func selections(_ stateRoot: URL) throws -> [String] {
  try ThemeHistoryStore(root: stateRoot).load().map {
    "\($0.themeID)#\($0.backgroundID ?? "-")"
  }
}

private func selectionLabel(_ manifest: GenerationManifest) -> String {
  "\(manifest.themeID)#\(manifest.background?.id ?? "-")"
}

private func selectionManifest(_ themeID: String, _ backgroundID: String?) -> GenerationManifest {
  GenerationManifest(
    generationID: "g-\(UUID().uuidString.lowercased())",
    themeID: themeID,
    themeSchemaVersion: 1,
    inputDigest: "sha256:test",
    themeDigest: "sha256:theme",
    background: backgroundID.map { GenerationBackground(id: $0, format: .jpeg) },
    rendererVersions: ["normalized_theme": 1],
    artifacts: ["theme.json": "sha256:theme"]
  )
}

private enum TestError: Error, CustomStringConvertible {
  case activation
  case historyWrite

  var description: String {
    switch self {
    case .activation: "activation failed"
    case .historyWrite: "history write denied"
    }
  }
}
