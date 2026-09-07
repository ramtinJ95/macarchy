import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeBrowserDeletionTests {
  @Test
  func confirmedDeletionRefreshesSelectionAndPreservesUnrelatedData() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let content = try fixture.content()
    let target = try #require(content.item(id: fixture.themeID)?.deletion.target)
    var state = ThemeBrowserState(content: content)
    state.selectTheme(id: fixture.themeID)
    let preferences = BackgroundPreferenceStore(root: fixture.root)
    try preferences.persist([fixture.themeID: "default"])
    let personal = fixture.root.appending(path: "personal-wallpaper.png")
    try Data("personal".utf8).write(to: personal)
    // Even an extra symlink inside the package must not turn its external
    // destination into a deletion target.
    try FileManager.default.createSymbolicLink(
      at: fixture.packageURL.appending(path: "personal-link"), withDestinationURL: personal
    )

    let outcome = await fixture.runner().execute(
      target: target, repository: fixture.repository, stateRoot: fixture.root
    )
    guard case .deleted(let refreshed) = outcome else {
      Issue.record("Expected a deleted package and refreshed inventory: \(outcome)")
      return
    }
    state.refresh(content: refreshed, query: "")
    #expect(refreshed.item(id: fixture.themeID) == nil)
    #expect(state.content.item(id: state.selectedThemeID) != nil)
    #expect(state.selectedThemeID != fixture.themeID)
    #expect(!FileManager.default.fileExists(atPath: fixture.packageURL.path))
    #expect(
      FileManager.default.fileExists(atPath: fixture.trashURL.appending(path: "theme.toml").path))
    #expect(try String(contentsOf: personal, encoding: .utf8) == "personal")
    #expect(try preferences.load()[fixture.themeID] == "default")
    #expect(
      try fixture.repository.packages().map(\.id)
        == content.items.map(\.id).filter {
          $0 != fixture.themeID
        })
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "current").path))
  }

  @Test
  func selectionCannotReenableDeletionAfterRefreshFailure() throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let content = try fixture.content()
    var state = ThemeBrowserState(content: content)
    state.selectTheme(id: fixture.themeID)
    #expect(state.deletionAvailability.target != nil)
    state.markInventoryStale()
    state.selectTheme(id: "catppuccin-mocha")
    state.selectTheme(id: fixture.themeID)
    #expect(state.deletionAvailability.target == nil)
    #expect(state.deletionAvailability.explanation.contains("refresh failed"))
    state.refresh(content: content, query: fixture.themeID)
    #expect(state.deletionAvailability.target != nil)
  }

  @Test
  func builtInsAndOverlappingReleaseRootsNeverProduceDeletionTargets() throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let content = try fixture.content()
    for item in content.items where item.id != fixture.themeID {
      #expect(item.deletion.target == nil)
      #expect(item.deletion.explanation.contains("Built-in"))
    }
    let overlapping = ThemeRepository(builtInRoot: fixture.userRoot, userRoot: fixture.userRoot)
    let package = try ThemePackageLoader().load(packageURL: fixture.packageURL)
    #expect(try overlapping.deletionTarget(for: package) == nil)
  }

  @Test
  func activeThemeIsProtectedInInventoryAndAtMutationTime() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let target = try fixture.target()
    let loader = ThemeBrowserCommandLoader(
      loadPackages: ThemeBrowserCommandLoader.live.loadPackages,
      loadPreferences: { _ in [:] },
      loadActiveManifest: { _ in fixture.manifest() },
      addPersonalBackgrounds: { _, package in package },
      renderPreview: ThemeBrowserCommandLoader.live.renderPreview
    )
    let activeContent = try loader.load(repository: fixture.repository, stateRoot: fixture.root)
    let item = try #require(activeContent.item(id: fixture.themeID))
    #expect(item.deletion.target == nil)
    #expect(item.deletion.explanation.contains("Apply another"))
    let outcome = await fixture.runner(activeThemeID: { _ in fixture.themeID }).execute(
      target: target, repository: fixture.repository, stateRoot: fixture.root
    )
    guard case .failed(let reason) = outcome else {
      Issue.record("Deleted active theme")
      return
    }
    #expect(reason.contains("Apply another"))
    #expect(FileManager.default.fileExists(atPath: fixture.packageURL.path))
  }

  @Test
  func deletionWaitsForConcurrentActivationAndRechecksItsCommittedIdentity() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let target = try fixture.target()
    let active = Mutex<String?>(nil)
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let (release, resume) = AsyncStream<Void>.makeStream()
    defer { resume.finish() }
    let activation = Task.detached { @Sendable in
      try await ThemePackageLock(root: fixture.root).withLock {
        enter.yield()
        for await _ in release { break }
        active.withLock { $0 = fixture.themeID }
      }
    }
    for await _ in entered { break }
    let checked = Mutex(false)
    let deletion = Task.detached { @Sendable in
      await fixture.runner(activeThemeID: { _ in
        checked.withLock { $0 = true }
        return active.withLock { $0 }
      }).execute(
        target: target, repository: fixture.repository, stateRoot: fixture.root
      )
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(!checked.withLock { $0 })
    resume.yield()
    try await activation.value
    guard case .failed(let reason) = await deletion.value else {
      Issue.record("Deletion did not respect concurrent activation")
      return
    }
    #expect(reason.contains("Apply another"))
    #expect(FileManager.default.fileExists(atPath: fixture.packageURL.path))
  }

  @Test
  func aReplacedDirectoryWithTheSameIDRequiresFreshConfirmation() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let target = try fixture.target()
    let old = fixture.root.appending(path: "old-package")
    try FileManager.default.moveItem(at: fixture.packageURL, to: old)
    try FileManager.default.copyItem(at: old, to: fixture.packageURL)
    let outcome = await fixture.runner().execute(
      target: target, repository: fixture.repository, stateRoot: fixture.root
    )
    guard case .failed(let reason) = outcome else {
      Issue.record("Deleted replacement")
      return
    }
    #expect(reason.contains("changed or is protected"))
    #expect(FileManager.default.fileExists(atPath: fixture.packageURL.path))
    #expect(try fixture.target() != target)
  }

  @Test(arguments: [false, true])
  func symlinkedPackageOrLibraryCannotBecomeAnOwnedDeletionTarget(linkLibrary: Bool) async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let target = try fixture.target()
    let package = try fixture.repository.package(id: fixture.themeID)
    let source = linkLibrary ? fixture.userRoot : fixture.packageURL
    let outside = fixture.root.appending(path: "outside")
    try FileManager.default.moveItem(at: source, to: outside)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
    let outcome = await fixture.runner().execute(
      target: target, repository: fixture.repository, stateRoot: fixture.root
    )
    guard case .failed = outcome else {
      Issue.record("Deleted a linked directory")
      return
    }
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(throws: (any Error).self) {
      try fixture.repository.deletionTarget(for: package)
    }
  }

  @Test
  func corruptCanonicalStateFailsClosedBeforeTrash() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let target = try fixture.target()
    let current = fixture.root.appending(path: "current")
    try Data("not a canonical pointer".utf8).write(to: current)
    let outcome = await fixture.runner().execute(
      target: target, repository: fixture.repository, stateRoot: fixture.root
    )
    guard case .failed(let reason) = outcome else {
      Issue.record("Ignored corrupt state")
      return
    }
    #expect(reason.contains("current"))
    #expect(try String(contentsOf: current, encoding: .utf8) == "not a canonical pointer")
    #expect(FileManager.default.fileExists(atPath: fixture.packageURL.path))
  }

  @Test
  func trashFailureDoesNotMasqueradeAsSuccess() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let runner = ThemeBrowserDeletionRunner(
      activeThemeID: { _ in nil },
      moveToTrash: { _ in throw DeletionTestError.injected },
      loadContent: { _, _ in
        Issue.record("Refreshed after failed deletion")
        return try fixture.content()
      }
    )
    let outcome = await runner.execute(
      target: try fixture.target(), repository: fixture.repository,
      stateRoot: fixture.root
    )
    guard case .failed(let reason) = outcome else {
      Issue.record("Expected trash failure")
      return
    }
    #expect(reason.contains("injected"))
    #expect(FileManager.default.fileExists(atPath: fixture.packageURL.path))
  }

  @Test
  func refreshFailureReportsCommittedDeletionAndCanRemoveTheStaleSelection() async throws {
    let fixture = try DeletionFixture()
    defer { fixture.remove() }
    let before = try fixture.content()
    let runner = ThemeBrowserDeletionRunner(
      activeThemeID: { _ in nil },
      moveToTrash: fixture.runner().moveToTrash,
      loadContent: { _, _ in throw DeletionTestError.injected }
    )
    let outcome = await runner.execute(
      target: try fixture.target(), repository: fixture.repository,
      stateRoot: fixture.root
    )
    guard case .deletedButRefreshFailed(let reason) = outcome else {
      Issue.record("Lost the committed-deletion result")
      return
    }
    #expect(reason.contains("injected"))
    var state = ThemeBrowserState(content: before)
    state.selectTheme(id: fixture.themeID)
    state.refresh(content: before.removingTheme(id: fixture.themeID), query: "")
    #expect(state.selectedThemeID != fixture.themeID)
    #expect(state.visibleItems.allSatisfy { $0.id != fixture.themeID })
    #expect(!FileManager.default.fileExists(atPath: fixture.packageURL.path))
  }
}

private enum DeletionTestError: Error {
  case injected
}

private struct DeletionFixture: Sendable {
  let root: URL
  let themeID = "delete-test"
  let builtInRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Themes")

  var userRoot: URL { root.appending(path: "themes") }
  var packageURL: URL { userRoot.appending(path: themeID) }
  var trashURL: URL { root.appending(path: "test-trash") }
  var repository: ThemeRepository { ThemeRepository(builtInRoot: builtInRoot, userRoot: userRoot) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-delete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: builtInRoot.appending(path: "catppuccin-mocha"), to: packageURL)
    let manifestURL = packageURL.appending(path: "theme.toml")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
      .replacingOccurrences(of: "catppuccin-mocha", with: themeID)
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
  }

  func content() throws -> ThemeBrowserContent {
    try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: root)
  }

  func target() throws -> ThemePackageDeletionTarget {
    let package = try repository.package(id: themeID)
    return try #require(try repository.deletionTarget(for: package))
  }

  func runner(
    activeThemeID: @escaping @Sendable (URL) throws -> String? = ThemeBrowserDeletionRunner.live
      .activeThemeID
  ) -> ThemeBrowserDeletionRunner {
    ThemeBrowserDeletionRunner(
      activeThemeID: activeThemeID,
      moveToTrash: { try FileManager.default.moveItem(at: $0, to: trashURL) },
      loadContent: ThemeBrowserDeletionRunner.live.loadContent
    )
  }

  func manifest() -> GenerationManifest {
    GenerationManifest(
      generationID: "g-delete-test", themeID: themeID, themeSchemaVersion: 1,
      inputDigest: String(repeating: "a", count: 71),
      themeDigest: String(repeating: "b", count: 71),
      background: nil, rendererVersions: [:], artifacts: [:]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
