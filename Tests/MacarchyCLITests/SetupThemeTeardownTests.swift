import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupThemeTeardownTests {
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
