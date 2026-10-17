import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Lifecycle families every preset on the shared preset file transaction must satisfy. Each
/// preset's own suite keeps its document, adoption and external-tuple rules.
struct EnvironmentPresetFileLifecycleTests {
  @Test(arguments: PresetFileCase.allCases)
  func cleanEnableIsIdempotentAndDisableRemovesTheFileAndLinks(
    _ preset: PresetFileCase
  ) async throws {
    let fixture = try preset.fixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(try fixture.plan().succeeded)
    let first = try await fixture.applyPreset()
    #expect(first.succeeded)
    #expect(try jsonObject(first.output)["outcome"] as? String == "applied")
    let theme = try #require(
      (try jsonObject(first.output)["theme"] as? [[String: Any]])?.first
    )
    #expect(theme["status"] as? String == preset.reconciledStatus)
    #expect((theme["message"] as? String)?.contains(preset.reconciledMessage) == true)
    #expect(try String(contentsOf: fixture.presetFile, encoding: .utf8) == preset.managedFile)
    for (link, destination) in fixture.themeLinks {
      #expect(try fixture.destination(of: link) == destination.path)
    }
    let ownership = try #require(
      try EnvironmentStateStore(stateRoot: fixture.state).readOwnership()
    )
    #expect(preset.isEnabled(in: ownership))
    #expect(ownership.enabledThemeAdapterIDs == [preset.adapterID])
    #expect(try fixture.runtimeAdapterIDs() == [preset.adapterID])

    let repeated = try await fixture.applyPreset()
    #expect(repeated.succeeded)
    #expect(try jsonObject(repeated.output)["outcome"] as? String == "no_change")

    try fixture.setPresetEnabled(false)
    #expect(try fixture.runtimeAdapterIDs().contains(preset.adapterID))
    let disabled = try await fixture.applyPreset()
    #expect(disabled.succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.presetFile.path))
    for (link, _) in fixture.themeLinks {
      #expect(!FileManager.default.fileExists(atPath: link.path))
    }
    if let directory = preset.directoryRemovedOnDisable(home: fixture.home) {
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    #expect(try !fixture.runtimeAdapterIDs().contains(preset.adapterID))

    let teardown = try await fixture.teardown()
    #expect(teardown.succeeded)
    #expect(try jsonObject(teardown.output)["outcome"] as? String == "absent")
  }

  @Test(arguments: PresetFileCase.allCases)
  func interruptedAuthorityPublicationRollsBackReplaysAndClaimedTeardownRecovers(
    _ preset: PresetFileCase
  ) async throws {
    let fixture = try preset.fixture(configuration: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    let checkpointObserved = Mutex(false)
    let interrupted = Mutex<EnvironmentTransaction?>(nil)

    let result = try await fixture.applyPreset(adopt: nil) { checkpoint in
      guard checkpoint == .authorityPublished else { return }
      #expect(store.transactionExists)
      let published = try #require(try store.readOwnership())
      #expect(preset.isEnabled(in: published))
      interrupted.withLock { $0 = try? store.readTransaction() }
      #expect(try fixture.runtimeAdapterIDs().contains(preset.adapterID))
      checkpointObserved.withLock { $0 = true }
      throw PresetFileFixtureError.injectedFailure
    }

    #expect(!result.succeeded)
    #expect(checkpointObserved.withLock { $0 })
    #expect(try store.readOwnership() == nil)
    #expect(!store.transactionExists)
    #expect(try !fixture.runtimeAdapterIDs().contains(preset.adapterID))
    #expect(!FileManager.default.fileExists(atPath: fixture.presetFile.path))

    try store.writeTransaction(try #require(interrupted.withLock { $0 }))
    #expect(try fixture.recoverTransaction())
    #expect(!store.transactionExists)
    #expect(try fixture.runtimeAdapterIDs().contains(preset.adapterID))
    let recovered = try #require(try store.readOwnership())
    #expect(preset.isEnabled(in: recovered))
    #expect(try String(contentsOf: fixture.presetFile, encoding: .utf8) == preset.managedFile)
    for (link, destination) in fixture.themeLinks {
      #expect(try fixture.destination(of: link) == destination.path)
    }

    // The replayed state tears down through the ordinary command.
    #expect(try await fixture.teardown().succeeded)
    #expect(!FileManager.default.fileExists(atPath: fixture.presetFile.path))
    for (link, _) in fixture.themeLinks {
      #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    // Teardown recovery settles a configuration the interrupted teardown already claimed.
    #expect(try await fixture.applyPreset().succeeded)
    let reapplied = try #require(try store.readOwnership())
    let replacementName = ".macarchy-environment-\(preset.rawValue)-claimed.replacement"
    try store.writeTransaction(
      try preset.teardownTransaction(
        previous: reapplied, state: fixture.state, replacementName: replacementName))
    try FileManager.default.moveItem(
      at: fixture.presetFile,
      to: fixture.presetFile.deletingLastPathComponent().appending(path: replacementName)
    )
    #expect(try fixture.recoverTransaction())
    #expect(!FileManager.default.fileExists(atPath: fixture.presetFile.path))
    for (link, _) in fixture.themeLinks {
      #expect(!FileManager.default.fileExists(atPath: link.path))
    }
    #expect(try !fixture.runtimeAdapterIDs().contains(preset.adapterID))
  }

  @Test(arguments: PresetFileCase.allCases)
  func driftBlocksMutationAndInterruptedTeardownRestoresTheOriginalSelector(
    _ preset: PresetFileCase
  ) async throws {
    let drift = preset.drift
    let fixture = try preset.fixture(configuration: drift.original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let digest = try #require(
      try jsonObject(fixture.plan().output)["adoption_evidence_digest"] as? String
    )
    #expect(try await fixture.applyPreset(adopt: digest).succeeded)

    try drift.drifted.write(to: fixture.presetFile, atomically: true, encoding: .utf8)
    #expect(try !fixture.status().succeeded)
    if preset == .tuicr {
      let preview: (output: String, succeeded: Bool) = (try? fixture.plan()) ?? ("", false)
      #expect(!preview.succeeded)
    }
    let driftedTeardown = try await fixture.teardown()
    #expect(!driftedTeardown.succeeded)
    for (link, destination) in fixture.themeLinks {
      #expect(try fixture.destination(of: link) == destination.path)
    }
    let store = EnvironmentStateStore(stateRoot: fixture.state)
    #expect(!store.transactionExists)

    try drift.managedWithLaterChange.write(
      to: fixture.presetFile, atomically: true, encoding: .utf8)
    let adopted = try #require(try store.readOwnership())
    try store.writeTransaction(
      try preset.teardownTransaction(
        previous: adopted, state: fixture.state,
        replacementName: ".macarchy-environment-\(preset.rawValue)-recovery.replacement"))

    #expect(try fixture.recoverTransaction())
    #expect(
      try String(contentsOf: fixture.presetFile, encoding: .utf8) == drift.restoredWithLaterChange)
    for (link, _) in fixture.themeLinks {
      #expect(!FileManager.default.fileExists(atPath: link.path))
    }
    #expect(try store.readOwnership() == nil)
    #expect(!store.transactionExists)
  }
}

enum PresetFileFixtureError: Error {
  case injectedFailure
}

enum PresetFileCase: String, CaseIterable, Sendable {
  case tuicr
  case pi
  case codex

  struct Drift {
    /// The adopted file, then a foreign selector, then the managed selector beside a later
    /// provider change, and what teardown restores from that.
    let original: String
    let drifted: String
    let managedWithLaterChange: String
    let restoredWithLaterChange: String
  }

  /// An activated fixture with `configuration` as the preset file, or no file when nil.
  func fixture(configuration: String?) throws -> any PresetFileFixture {
    switch self {
    case .tuicr: try makeTuicrPresetFileFixture(configuration: configuration)
    case .pi: try makePiPresetFileFixture(settings: configuration)
    case .codex: try makeCodexPresetFileFixture(configuration: configuration)
    }
  }

  var adapterID: String {
    switch self {
    case .tuicr: TuicrAdapter.id
    case .pi: PiAdapter.id
    case .codex: CodexAdapter.id
    }
  }

  /// The preset file a clean enable creates.
  var managedFile: String {
    switch self {
    case .tuicr: "theme = \"macarchy-current\"\n"
    case .pi: "{\"theme\": \"macarchy-current\"}\n"
    case .codex: "[tui]\ntheme = \"macarchy-current\"\n"
    }
  }

  var reconciledStatus: String {
    self == .pi ? "applied" : "restart_required"
  }

  var reconciledMessage: String {
    switch self {
    case .tuicr: "Restart tuicr"
    case .pi: "Running Pi sessions reloaded"
    case .codex: "fresh Codex"
    }
  }

  var drift: Drift {
    switch self {
    case .tuicr:
      Drift(
        original: "wrap = true\n",
        drifted: "theme = \"wrong\"\nwrap = true\n",
        managedWithLaterChange: "theme = \"macarchy-current\"\nwrap = true\n",
        restoredWithLaterChange: "wrap = true\n")
    case .pi:
      Drift(
        original: "{\"theme\":\"personal\",\"keep\":true}\n",
        drifted: "{\"theme\":\"wrong\",\"later\":1}\n",
        managedWithLaterChange: "{\"later\":1,\"theme\":\"macarchy-current\"}\n",
        restoredWithLaterChange: "{\"later\":1,\"theme\":\"personal\"}\n")
    case .codex:
      Drift(
        original: "[tui]\ntheme = \"personal\"\n",
        drifted: "[tui]\ntheme = \"wrong\"\n",
        managedWithLaterChange: "[tui]\ntheme = \"macarchy-current\"\nanimations = true\n",
        restoredWithLaterChange: "[tui]\ntheme = \"personal\"\nanimations = true\n")
    }
  }

  func isEnabled(in ownership: EnvironmentOwnership) -> Bool {
    switch self {
    case .tuicr: ownership.tuicrEnabled
    case .pi: ownership.piEnabled
    case .codex: ownership.codexEnabled
    }
  }

  /// A preset directory that disabling removes along with the file.
  func directoryRemovedOnDisable(home: URL) -> URL? {
    self == .pi ? home.appending(path: ".pi") : nil
  }

  func teardownTransaction(
    previous: EnvironmentOwnership, state: URL, replacementName: String
  ) throws -> EnvironmentTransaction {
    let destination = try EnvironmentGenerationStore(stateRoot: state).currentDestination()
    switch self {
    case .tuicr:
      return EnvironmentTransaction(
        operation: .teardown, previousOwnership: previous, proposedOwnership: nil,
        previousCurrentDestination: destination, tuicrReplacementName: replacementName)
    case .pi:
      return EnvironmentTransaction(
        operation: .teardown, previousOwnership: previous, proposedOwnership: nil,
        previousCurrentDestination: destination, piReplacementName: replacementName)
    case .codex:
      return EnvironmentTransaction(
        operation: .teardown, previousOwnership: previous, proposedOwnership: nil,
        previousCurrentDestination: destination, codexReplacementName: replacementName)
    }
  }
}

extension PresetFileCase: CustomTestStringConvertible {
  var testDescription: String { rawValue }
}
