import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct OmarchyThemePackageInstallerTests {
  @Test
  func newInstallationCanBeWithdrawn() throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let candidate = try fixture.candidate(marker: "new")

    let rejected = try OmarchyThemePackageInstaller().install(
      package: candidate,
      userThemesRoot: fixture.userThemes
    )
    #expect(try fixture.installedMarker() == "new")
    try rejected.rollback()
    #expect(!FileManager.default.fileExists(atPath: fixture.installedPackage.path))
    #expect(try fixture.transactionResidue().isEmpty)
  }

  @Test
  func replacementIsAtomicAndRollbackRestoresThePreviousPackage() throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    try fixture.installExisting(marker: "old")
    let candidate = try fixture.candidate(marker: "new")

    let installation = try OmarchyThemePackageInstaller().install(
      package: candidate,
      userThemesRoot: fixture.userThemes
    )
    #expect(installation.replacedExistingPackage)
    #expect(try fixture.installedMarker() == "new")

    try installation.rollback()
    #expect(try fixture.installedMarker() == "old")
    #expect(try fixture.transactionResidue().isEmpty)
  }

  @Test
  func finishingReplacementKeepsTheNewPackageAndRemovesTheOldOne() throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    try fixture.installExisting(marker: "old")
    let candidate = try fixture.candidate(marker: "new")

    let installation = try OmarchyThemePackageInstaller().install(
      package: candidate,
      userThemesRoot: fixture.userThemes
    )
    try installation.finish()

    #expect(try fixture.installedMarker() == "new")
    #expect(try fixture.transactionResidue().isEmpty)
  }

  @Test
  func unsafeDestinationIsRejectedWithoutOverwritingIt() throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.userThemes,
      withIntermediateDirectories: true
    )
    try "occupied".write(
      to: fixture.installedPackage,
      atomically: false,
      encoding: .utf8
    )
    let candidate = try fixture.candidate(marker: "new")

    #expect(
      throws: OmarchyThemePackageInstallationError.unsafeExistingPackage(
        fixture.installedPackage.path
      )
    ) {
      _ = try OmarchyThemePackageInstaller().install(
        package: candidate,
        userThemesRoot: fixture.userThemes
      )
    }
    #expect(try String(contentsOf: fixture.installedPackage, encoding: .utf8) == "occupied")
    #expect(try fixture.transactionResidue().isEmpty)
  }

  @Test
  func interruptedTransactionEvidenceBlocksAnotherInstallation() throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    try fixture.installExisting(marker: "old")
    let residue = fixture.userThemes.appending(
      path: ".macarchy-install-catppuccin-mocha-interrupted",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: residue, withIntermediateDirectories: false)
    let candidate = try fixture.candidate(marker: "new")

    do {
      _ = try OmarchyThemePackageInstaller().wouldReplace(
        themeID: candidate.id,
        userThemesRoot: fixture.userThemes
      )
      Issue.record("Expected dry-run inspection to report interrupted evidence")
    } catch let error as OmarchyThemePackageInstallationError {
      guard case .interruptedTransaction = error else {
        Issue.record("Unexpected dry-run inspection error: \(error)")
        return
      }
    }
    do {
      _ = try OmarchyThemePackageInstaller().install(
        package: candidate,
        userThemesRoot: fixture.userThemes
      )
      Issue.record("Expected interrupted transaction evidence to block installation")
    } catch let error as OmarchyThemePackageInstallationError {
      guard case .interruptedTransaction(let path) = error else {
        Issue.record("Unexpected installation error: \(error)")
        return
      }
      #expect(path.hasSuffix("/\(residue.lastPathComponent)"))
    }
    #expect(try fixture.installedMarker() == "old")
    #expect(try fixture.transactionResidue() == [residue.lastPathComponent])
  }

  @Test
  func packageLockSerializesConcurrentCallersInOneProcess() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.remove() }
    let lock = ThemePackageLock(root: fixture.root)
    let state = PackageLockTestState()
    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    var enteredIterator = entered.makeAsyncIterator()
    defer { state.values.withLock { $0.releaseFirst = true } }

    let first = Task.detached {
      try await lock.withLock {
        state.values.withLock { state in
          state.entered += 1
          state.active += 1
          state.maximumActive = max(state.maximumActive, state.active)
        }
        enteredContinuation.yield()
        while !state.values.withLock({ $0.releaseFirst }) {
          try await Task.sleep(for: .milliseconds(1))
        }
        state.values.withLock { $0.active -= 1 }
      }
    }
    _ = await enteredIterator.next()

    let spicetifyEntered = Mutex(false)
    let spicetify = Task.detached { @Sendable in
      try await SpicetifyLock(root: fixture.root).withLock {
        await Task.yield()
        spicetifyEntered.withLock { $0 = true }
      }
    }
    for _ in 0..<100 where !spicetifyEntered.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(1))
    }
    let spicetifyEnteredWhilePackageLocked = spicetifyEntered.withLock { $0 }

    let second = Task.detached {
      try await lock.withLock {
        state.values.withLock { state in
          state.entered += 1
          state.active += 1
          state.maximumActive = max(state.maximumActive, state.active)
          state.active -= 1
        }
      }
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(state.values.withLock { $0.entered } == 1)

    state.values.withLock { $0.releaseFirst = true }
    try await first.value
    try await spicetify.value
    try await second.value
    #expect(spicetifyEnteredWhilePackageLocked)
    #expect(state.values.withLock { $0.entered } == 2)
    #expect(state.values.withLock { $0.maximumActive } == 1)
  }
}

private final class PackageLockTestState: Sendable {
  let values = Mutex((entered: 0, active: 0, maximumActive: 0, releaseFirst: false))
}

private struct InstallationFixture {
  let root: URL
  let userThemes: URL
  let candidateRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-package-installer-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    userThemes = root.appending(path: "themes", directoryHint: .isDirectory)
    candidateRoot = root.appending(path: "candidate", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  var installedPackage: URL {
    userThemes.appending(path: "catppuccin-mocha", directoryHint: .isDirectory)
  }

  func candidate(marker: String) throws -> ThemePackage {
    if FileManager.default.fileExists(atPath: candidateRoot.path) {
      try FileManager.default.removeItem(at: candidateRoot)
    }
    try copyAuthoredPackage(to: candidateRoot, marker: marker)
    return try ThemePackageLoader().load(packageURL: candidateRoot)
  }

  func installExisting(marker: String) throws {
    try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
    try copyAuthoredPackage(to: installedPackage, marker: marker)
  }

  func installedMarker() throws -> String {
    try String(
      contentsOf: installedPackage.appending(path: "install-marker"),
      encoding: .utf8
    )
  }

  func transactionResidue() throws -> [String] {
    guard FileManager.default.fileExists(atPath: userThemes.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: userThemes.path)
      .filter { $0.hasPrefix(".macarchy-install-") }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private func copyAuthoredPackage(to destination: URL, marker: String) throws {
    try FileManager.default.copyItem(at: Self.authoredPackage, to: destination)
    try marker.write(
      to: destination.appending(path: "install-marker"),
      atomically: false,
      encoding: .utf8
    )
  }

  private static var authoredPackage: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
  }
}
