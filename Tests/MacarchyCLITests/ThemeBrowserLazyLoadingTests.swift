import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserLazyLoadingTests {
  // Explicit, read-only supported-machine timing. Run this test alone so the
  // process-local image-validation cache cannot hide the eager loading cost.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_BROWSER_STATE_ROOT"] != nil))
  func supportedMachineCatalogTiming() throws {
    let path = try #require(ProcessInfo.processInfo.environment["MACARCHY_TEST_BROWSER_STATE_ROOT"])
    let root = URL(filePath: path)
    let builtIn = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Themes")
    let repository = ThemeRepository(builtInRoot: builtIn, userRoot: root.appending(path: "themes"))
    let clock = ContinuousClock()
    let started = clock.now
    let content = try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: root)
    let catalogTime = started.duration(to: clock.now)
    let eagerStarted = clock.now
    let packages = try repository.packages()
    let eagerTime = eagerStarted.duration(to: clock.now)
    #expect(content.items.map(\.id) == packages.map(\.id))
    print(
      "Browser library (\(content.items.count) themes): metadata startup \(catalogTime); full package loading \(eagerTime)"
    )
  }

  @Test
  func catalogAndGeneratedPreviewsDoNotReadPackageOrPersonalImages() throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    try """
    schema_version = 2
    [[wallpaper_additions]]
    theme_id = "lazy-test"
    id = "personal"
    path = "\(fixture.root.appending(path: "missing.webp").path)"
    """.write(to: fixture.root.appending(path: "config.toml"), atomically: true, encoding: .utf8)

    // No image files exist. Discovery still yields searchable, navigable metadata.
    let content = try fixture.content()
    let item = try #require(content.item(id: "lazy-test"))
    #expect(item.backgrounds.map(\.id) == ["good", "broken", "personal"])
    #expect(item.isPersonalBackground(id: "personal"))
    #expect(!item.generatedPreview.data.isEmpty)
    #expect(content.filteredItems(query: "lazy dark").count == 1)
    #expect(throws: (any Error).self) { try item.backgroundData(id: "personal") }
    #expect(throws: (any Error).self) { try item.backgroundData(id: "broken") }

    // Only the requested image is read, even with other broken entries present.
    try fixture.validImage.write(to: fixture.goodImage)
    #expect(try item.backgroundData(id: "good") == fixture.validImage)
    #expect(throws: (any Error).self) {
      try ThemePackageLoader().load(packageURL: fixture.packageURL)
    }
  }

  @Test
  func personalConfigurationIsReadOnceForTheWholeCatalog() throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    let other = fixture.library.appending(path: "other")
    try FileManager.default.copyItem(at: fixture.packageURL, to: other)
    let file = other.appending(path: "theme.toml")
    try String(contentsOf: file, encoding: .utf8)
      .replacingOccurrences(of: "lazy-test", with: "other")
      .write(to: file, atomically: true, encoding: .utf8)
    let calls = Mutex(0)
    let live = ThemeBrowserCommandLoader.live
    let loader = ThemeBrowserCommandLoader(
      loadMetadata: live.loadMetadata,
      loadPreferences: live.loadPreferences,
      loadActiveManifest: live.loadActiveManifest,
      loadPersonalBackgrounds: { _, ids in
        calls.withLock { $0 += 1 }
        #expect(ids == ["lazy-test", "other"])
        return [:]
      },
      renderPreview: live.renderPreview)
    #expect(
      try loader.load(repository: fixture.repository, stateRoot: fixture.root).items.count == 2)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test(arguments: ["duplicate-id", "escape", "unsupported"])
  func metadataStillRejectsInvalidDeclarations(problem: String) throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    let file = fixture.packageURL.appending(path: "theme.toml")
    let before = try String(contentsOf: file, encoding: .utf8)
    let after: String
    switch problem {
    case "duplicate-id":
      after = before.replacingOccurrences(of: "id = \"broken\"", with: "id = \"good\"")
    case "escape": after = before.replacingOccurrences(of: "broken.webp", with: "../outside.webp")
    default: after = before.replacingOccurrences(of: "broken.webp", with: "broken.svg")
    }
    try after.write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try fixture.content() }
  }

  @Test
  func deferredReadRechecksSymlinkContainment() throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    let item = try #require(try fixture.content().items.first)
    let outside = fixture.root.appending(path: "outside.webp")
    try fixture.validImage.write(to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.goodImage, withDestinationURL: outside)
    do {
      _ = try item.backgroundData(id: "good")
      Issue.record("Read an image outside the package after catalog discovery")
    } catch let error as ThemeDiagnostic {
      #expect(error.message.contains("must resolve inside"))
    }
  }

  @Test
  func deferredReadRejectsChangedBytesRatherThanTrustingCatalogMetadata() throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    try fixture.validImage.write(to: fixture.goodImage)
    let item = try #require(try fixture.content().items.first)
    try Data("not an image".utf8).write(to: fixture.goodImage)
    #expect(throws: (any Error).self) { try item.backgroundData(id: "good") }
  }

  @Test
  func applyStillFullyValidatesAndLeavesCanonicalStateUnchangedOnFailure() async throws {
    let fixture = try LazyBrowserFixture()
    defer { fixture.remove() }
    #expect(try fixture.content().items.count == 1)
    let current = fixture.root.appending(path: "current")
    try FileManager.default.createSymbolicLink(
      atPath: current.path, withDestinationPath: "generations/untouched")
    let calls = Mutex(0)
    let runner = ThemeSetCommandRunner(
      preflight: { _, _, _, _ in calls.withLock { $0 += 1 } },
      activate: { _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        throw LazyBrowserTestError.unexpectedActivation
      })
    let result = try await runner.execute(
      repository: fixture.repository, themeID: "lazy-test", stateRoot: fixture.root,
      consumerPaths: testConsumerPaths(), dryRun: false, json: true, requestedBackgroundID: "good")
    #expect(!result.succeeded)
    #expect(result.output.contains("Cannot load background"))
    #expect(calls.withLock { $0 } == 0)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        == "generations/untouched")
  }
}

private enum LazyBrowserTestError: Error { case unexpectedActivation }

private struct LazyBrowserFixture {
  let root: URL
  var library: URL { root.appending(path: "themes") }
  var packageURL: URL { library.appending(path: "lazy-test") }
  var goodImage: URL { packageURL.appending(path: "good.webp") }
  var repository: ThemeRepository {
    ThemeRepository(builtInRoot: root.appending(path: "built-in"), userRoot: library)
  }
  private var source: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Themes/catppuccin-mocha")
  }
  var validImage: Data {
    get throws { try Data(contentsOf: source.appending(path: "wallpapers/1-totoro.webp")) }
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-lazy-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: packageURL.appending(path: "LICENSES"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "built-in"), withIntermediateDirectories: true)
    let prefix = try String(contentsOf: source.appending(path: "theme.toml"), encoding: .utf8)
      .components(separatedBy: "[[backgrounds]]")[0]
      .replacingOccurrences(of: "catppuccin-mocha", with: "lazy-test")
    let backgrounds = ["good", "broken"].map { id in
      """
      [[backgrounds]]
      id = "\(id)"
      path = "\(id).webp"
      source = "Test"
      author = "Test"
      license = "MIT"

      """
    }.joined(separator: "\n")
    try (prefix + backgrounds).write(
      to: packageURL.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(
      at: source.appending(path: "mappings.toml"), to: packageURL.appending(path: "mappings.toml"))
    try "Test fixture".write(
      to: packageURL.appending(path: "LICENSES/wallpaper.md"), atomically: true, encoding: .utf8)
  }

  func content() throws -> ThemeBrowserContent {
    try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: root)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
