import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupThemeTeardownTests {
  @Test func accentEvidenceCanBeConsumedWithoutOwningTheCanonicalTheme() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    try SetupCoreOwnershipStore(stateRoot: fixture.state).remove()
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: #"{"ok":true,"value":-1}"#),
    ])
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: fake.runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: nil, desiredAppearance: .dark, dryRun: false)
    #expect(result.succeeded)
    #expect(result.message.contains("external theme is preserved"))
    #expect(try store.load() == nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [false, true])
  func accentRestorationFailureBlocksRetirementAndKeepsEvidence(dryRun: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(.init(original: .graphite, applied: .blue))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root, helper: MacOSLookHelper(executableURL: root.appending(path: "missing")))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: dryRun)
    #expect(!result.succeeded)
    #expect(result.message.contains("macOS look helper is missing"))
    #expect(try store.load() != nil)
    #expect(
      try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [MacOSAccent.blue, .graphite, .green, .red])
  func accentRestoresBeforeRetirementAndOnlyThenRemovesEvidence(current: MacOSAccent) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let store = MacOSAccentStore(root: fixture.state)
    try store.persist(
      .init(original: .graphite, applied: .blue, pending: current == .red ? .red : nil))
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let fake = ProcessRunnerFake(replies: [
      .init(arguments: ["check"], output: #"{"ok":true,"value":{"build":"25G83","accent":true}}"#),
      .init(arguments: ["get", "accent"], output: "{\"ok\":true,\"value\":\(current.rawValue)}"),
      .init(arguments: ["set", "accent", "-1"], output: #"{"ok":true,"value":-1}"#),
    ])
    let runner = ProcessRunner { request in
      #expect(
        try ThemeGenerationReader(root: fixture.state).activeManifest().generationID
          == manifest.generationID)
      #expect(try store.load() != nil)
      return try fake.runner.run(request)
    }
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) },
      accent: { root in
        MacOSAccentAdapter(
          root: root,
          helper: MacOSLookHelper(
            executableURL: URL(filePath: "/usr/bin/true"), processRunner: runner))
      })
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: false)
    #expect(result.succeeded, "\(result.message)")
    #expect(try store.load() == nil)
    #expect(
      fake.requests.filter { $0.arguments.first == "set" }.count
        == (current == .blue || current == .red ? 1 : 0))
    if current == .green {
      #expect(result.message.contains("Kept the green accent, which was changed after setup."))
    }
  }

  @Test(arguments: [false, true])
  func scriptsReceiveTeardownBeforeRetirementAndFailuresDoNotBlock(journaled: Bool) async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let directory = try makeTrustedScriptDirectory()
    defer { removeTemporaryRoot(directory) }
    let script = directory.appending(path: "record")
    let recorded = directory.appending(path: "events")
    try
      "#!/bin/sh\ntest -f \"$MACARCHY_THEME_FILE\" || exit 9\necho $MACARCHY_EVENT >> \"$(dirname \"$0\")/events\"\n"
      .write(to: script, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let shared = directory.appending(path: "shared")
    try "#!/bin/sh\nexit 0\n".write(to: shared, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: shared.path)
    let scripts = [script.path, shared.path]
    if journaled {
      try UnifiedSetupTransactionStore(stateRoot: fixture.state).write(
        UnifiedSetupTransaction(
          operation: .teardown, stages: [.theme], desiredAppearance: .dark,
          contextDigest: "sha256:" + String(repeating: "a", count: 64), userScripts: scripts))
    } else {
      try EnvironmentStateStore(stateRoot: fixture.state).writeOwnership(
        EnvironmentOwnership(
          generationID: "e-00000000-0000-0000-0000-000000000000", records: [],
          createdDirectories: [], originalThemeBridges: [], userScripts: scripts,
          enabledThemeAdapterIDs: [UserScriptsAdapter.id]))
    }
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) })
    let preview = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership,
      desiredAppearance: .dark, dryRun: true)
    #expect(preview.message.contains("Would run 2 user scripts"))
    #expect(!FileManager.default.fileExists(atPath: recorded.path))
    let result = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership,
      desiredAppearance: .dark, dryRun: false)
    #expect(result.succeeded)
    #expect(result.message.contains("record succeeded"))
    #expect(result.message.contains("shared refused"))
    #expect(try String(contentsOf: recorded, encoding: .utf8) == "teardown\n")
  }

  @Test func restoresTheOriginalAppearanceAndWallpaperBeforeRemovingTheTheme() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let appearance = FakeAppearance(.dark)
    let wallpaper = FakeWallpaper(
      showing: fixture.state.appending(
        path: "generations/\(manifest.generationID)/generated/wallpaper.png"))
    try WallpaperOriginalStore(root: fixture.state).persist([
      WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/original.png",
        presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z")
    ])
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in
        WallpaperOriginalRestorer(
          root: root, control: wallpaper.control, originalExists: { _ in true })
      }
    )

    let plan = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: true)
    #expect(plan.outcome == "planned")
    #expect(
      plan.message
        == "Would restore macOS appearance and remove the setup-owned canonical theme. "
        + "Would restore the original wallpaper on 'Built-in'.")
    #expect(appearance.current() == .dark)
    #expect(wallpaper.current().path.hasSuffix("generated/wallpaper.png"))

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.outcome == "restored")
    #expect(
      stage.message
        == "Restored macOS appearance and removed the setup-owned canonical theme. "
        + "Restored the original wallpaper on 'Built-in'.")
    #expect(appearance.current() == .light)
    #expect(wallpaper.current() == URL(filePath: "/o/original.png"))
    #expect(try WallpaperOriginalStore(root: fixture.state).load() == [])
    #expect(try SetupCoreOwnershipStore(stateRoot: fixture.state).read() == nil)
    #expect(throws: (any Error).self) {
      try ThemeGenerationReader(root: fixture.state).activeManifest()
    }
  }

  @Test func keepsAndReportsValuesTheUserChangedAfterSetup() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    // Setup found Dark and kept it; the user switched to Light afterwards.
    let store = SetupCoreOwnershipStore(stateRoot: fixture.state)
    try store.remove()
    let ownership = SetupCoreOwnership(
      themeGenerationID: manifest.generationID, originalAppearance: .dark)
    try store.write(ownership)
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    try WallpaperOriginalStore(root: fixture.state).persist([
      WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/original.png",
        presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z")
    ])
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in
        WallpaperOriginalRestorer(
          root: root, control: wallpaper.control, originalExists: { _ in true })
      }
    )

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.outcome == "restored")
    #expect(
      stage.message
        == "Removed the setup-owned canonical theme. "
        + "Kept the macOS light appearance, which was changed after setup. "
        + "Kept the wallpaper on 'Built-in', which was changed after Macarchy set it.")
    #expect(appearance.current() == .light)
    #expect(appearance.applied() == [])
    #expect(wallpaper.current() == URL(filePath: "/user/chosen.png"))
    #expect(try store.read() == nil)
  }

  @Test func leavesAnAppearanceThatIsAlreadyTheOriginalSilently() async throws {
    let fixture = try ApplyFixture()
    let manifest = try fixture.activateSetupOwnedTheme()
    defer { fixture.cleanup(expectedThemeGenerationID: manifest.generationID) }
    let ownership = try #require(try SetupCoreOwnershipStore(stateRoot: fixture.state).read())
    let appearance = FakeAppearance(.light)
    let wallpaper = FakeWallpaper(showing: URL(filePath: "/user/chosen.png"))
    let teardown = SetupThemeTeardown(
      appearance: { _ in appearance.control },
      wallpaper: { root in WallpaperOriginalRestorer(root: root, control: wallpaper.control) }
    )

    let stage = try await teardown.run(
      stateRoot: fixture.state, ownership: ownership, desiredAppearance: .dark, dryRun: false)

    #expect(stage.succeeded)
    #expect(stage.message == "Removed the setup-owned canonical theme.")
    #expect(appearance.applied() == [])
  }
}

private final class FakeAppearance: Sendable {
  private let state: Mutex<ThemeAppearance>
  private let requests = Mutex<[ThemeAppearance]>([])

  init(_ appearance: ThemeAppearance) {
    state = Mutex(appearance)
  }

  var control: SetupAppearanceControl {
    SetupAppearanceControl(
      read: { self.current() },
      apply: { appearance in
        self.requests.withLock { $0.append(appearance) }
        self.state.withLock { $0 = appearance }
        return AdapterResult(
          adapterID: MacOSAppearanceAdapter.id, requirement: .required, status: .applied)
      }
    )
  }

  func current() -> ThemeAppearance { state.withLock { $0 } }
  func applied() -> [ThemeAppearance] { requests.withLock { $0 } }
}

private final class FakeWallpaper: Sendable {
  private let wallpaper: Mutex<URL>

  init(showing url: URL) {
    wallpaper = Mutex(url)
  }

  var control: WallpaperControl {
    WallpaperControl(
      inspect: {
        [WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: self.current())]
      },
      set: { url, _ in self.wallpaper.withLock { $0 = url } },
      displayUUID: { "uuid-\($0)" }
    )
  }

  func current() -> URL { wallpaper.withLock { $0 } }
}
