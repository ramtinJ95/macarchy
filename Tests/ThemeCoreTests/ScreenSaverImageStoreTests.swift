import Foundation
import ImageIO
import Synchronization
import Testing

@testable import ThemeCore

struct ScreenSaverImageStoreTests {
  @Test(arguments: [ThemeBackgroundFormat.png, .jpeg, .webp])
  func exportsChosenImageAsPNGWithoutClaimingNativeSelection(format: ThemeBackgroundFormat) throws {
    try withTemporaryRoot { root in
      let package = try package(format: format)
      _ = try activator(root).activate(package: package)
      let store = ScreenSaverImageStore(root: root)
      #expect(store.inspection().status == .drifted)
      let message = try store.reconcile()
      let data = try Data(contentsOf: store.folderURL.appending(path: "wallpaper.png"))
      try ThemeImageAsset.validate(data: data, format: .png)
      #expect(store.inspection().status == .ready)
      #expect(message.contains("Native selection and live repaint are not verified or changed"))
      if format == .png { #expect(data == package.firstBackgroundData) }
    }
  }

  @Test
  func stableFolderUpdatesAndRepeatedReconciliationDoesNotRewriteTheImage() throws {
    try withTemporaryRoot { root in
      let store = ScreenSaverImageStore(root: root)
      _ = try activator(root).activate(package: package(format: .jpeg))
      _ = try store.reconcile()
      let image = store.folderURL.appending(path: "wallpaper.png")
      let first = try Data(contentsOf: image)
      let folderIdentity = try identity(store.folderURL)
      let imageIdentity = try identity(image)
      _ = try store.reconcile()
      #expect(try identity(image) == imageIdentity)

      _ = try activator(root).activate(package: package(format: .webp))
      #expect(store.inspection().status == .drifted)
      _ = try store.reconcile()
      #expect(try identity(store.folderURL) == folderIdentity)
      #expect(try Data(contentsOf: image) != first)
      #expect(store.inspection().status == .ready)

      try Data("drift".utf8).write(to: image)
      #expect(store.inspection().status == .drifted)
      _ = try store.reconcile()
      #expect(store.inspection().status == .ready)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path).sorted()
          == [".macarchy.json", "wallpaper.png"])
    }
  }

  @Test
  func failedPreparationPreservesLastImageAndStaleWorkCannotOverwriteNewerCanonicalState() throws {
    try withTemporaryRoot { root in
      let original = ScreenSaverImageStore(root: root)
      _ = try activator(root).activate(package: package(format: .jpeg))
      _ = try original.reconcile()
      let image = original.folderURL.appending(path: "wallpaper.png")
      let before = try Data(contentsOf: image)
      _ = try activator(root).activate(package: package(format: .webp))
      let failed = ScreenSaverImageStore(
        root: root, beforeCompletion: { throw ProbeFailure.injected })
      #expect(throws: ProbeFailure.injected) { try failed.reconcile() }
      #expect(try Data(contentsOf: image) == before)

      let newest = try package(format: .png)
      let stale = ScreenSaverImageStore(
        root: root,
        beforeCompletion: {
          _ = try activator(root).activate(package: newest)
        })
      #expect(throws: (any Error).self) { try stale.reconcile() }
      #expect(try Data(contentsOf: image) == before)
      #expect(original.inspection().status == .drifted)
      _ = try original.reconcile()
      #expect(try Data(contentsOf: image) == newest.firstBackgroundData)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: original.folderURL.path).count == 2)
    }
  }

  @Test
  func matchingImageStillRechecksCanonicalGenerationAndFolderBinding() throws {
    for replaceFolder in [false, true] {
      try withTemporaryRoot { root in
        let store = ScreenSaverImageStore(root: root)
        _ = try activator(root).activate(package: package(format: .png))
        _ = try store.reconcile()
        let next = try package(format: .webp)
        let racing = ScreenSaverImageStore(
          root: root,
          beforeCompletion: {
            if replaceFolder {
              let displaced = root.appending(path: "displaced")
              try FileManager.default.moveItem(at: store.folderURL, to: displaced)
              try FileManager.default.copyItem(at: displaced, to: store.folderURL)
            } else {
              _ = try activator(root).activate(package: next)
            }
          })
        #expect(throws: (any Error).self) { try racing.reconcile() }
      }
    }
  }

  @Test
  func inspectionWaitsForReceiptPublicationInsteadOfRejectingItsTemporaryFile() throws {
    try withTemporaryRoot { root in
      let store = ScreenSaverImageStore(root: root)
      _ = try activator(root).activate(package: package(format: .png))
      _ = try store.reconcile()
      let staged = store.folderURL.appending(
        path: "..macarchy.json-\(UUID().uuidString.lowercased())")
      let completed = DispatchSemaphore(value: 0)
      let inspection = Mutex<AdapterInspection?>(nil)
      try ActivationLock(root: root).withLock {
        try Data("receipt being written".utf8).write(to: staged)
        DispatchQueue.global().async {
          inspection.withLock { $0 = store.inspection() }
          completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 0.03) == .timedOut)
        try FileManager.default.removeItem(at: staged)
      }
      #expect(completed.wait(timeout: .now() + 5) == .success)
      #expect(inspection.withLock { $0?.status } == .ready)
    }
  }

  @Test
  func unownedContentsAndDirectoryLinksArePreservedRatherThanAdopted() throws {
    try withTemporaryRoot { root in
      _ = try activator(root).activate(package: package(format: .png))
      let store = ScreenSaverImageStore(root: root)
      let external = root.appending(path: "personal")
      try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
      let personal = external.appending(path: "photo.png")
      try Data("personal".utf8).write(to: personal)
      try FileManager.default.createSymbolicLink(at: store.folderURL, withDestinationURL: external)
      #expect(throws: (any Error).self) { try store.reconcile() }
      try FileManager.default.removeItem(at: store.folderURL)
      try FileManager.default.createDirectory(
        at: store.folderURL, withIntermediateDirectories: false)
      try FileManager.default.copyItem(
        at: personal, to: store.folderURL.appending(path: "photo.png"))
      #expect(throws: (any Error).self) { try store.reconcile() }
      #expect(try Data(contentsOf: personal) == Data("personal".utf8))
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path) == ["photo.png"])
    }
  }

  @Test
  func linkedDestinationAndUnexpectedPhotosFailWithoutTouchingExternalFiles() throws {
    try withTemporaryRoot { root in
      _ = try activator(root).activate(package: package(format: .png))
      let store = ScreenSaverImageStore(root: root)
      _ = try store.reconcile()
      let image = store.folderURL.appending(path: "wallpaper.png")
      let external = root.appending(path: "external.png")
      try Data("external".utf8).write(to: external)
      try FileManager.default.removeItem(at: image)
      try FileManager.default.createSymbolicLink(at: image, withDestinationURL: external)
      #expect(throws: (any Error).self) { try store.reconcile() }
      #expect(store.inspection().status == .failed)
      #expect(try Data(contentsOf: external) == Data("external".utf8))

      try FileManager.default.removeItem(at: image)
      _ = try store.reconcile()
      try Data("unrelated".utf8).write(to: store.folderURL.appending(path: "extra.jpg"))
      #expect(throws: (any Error).self) { try store.reconcile() }
      #expect(
        FileManager.default.fileExists(atPath: store.folderURL.appending(path: "extra.jpg").path))
    }
  }

  @Test
  func noBackgroundRetainsPreviousExportAndCorruptCanonicalStateFailsExplicitly() throws {
    try withTemporaryRoot { root in
      let store = ScreenSaverImageStore(root: root)
      _ = try activator(root).activate(package: package(format: .png))
      _ = try store.reconcile()
      let image = store.folderURL.appending(path: "wallpaper.png")
      let before = try Data(contentsOf: image)
      _ = try activator(root).activate(package: package(format: nil))
      #expect(try store.reconcile().contains("retained"))
      #expect(try Data(contentsOf: image) == before)
      try FileManager.default.removeItem(at: root.appending(path: "current"))
      try Data("invalid pointer".utf8).write(to: root.appending(path: "current"))
      #expect(store.inspection().status == .failed)
      #expect(throws: (any Error).self) { try store.reconcile() }
      #expect(try Data(contentsOf: image) == before)
    }
  }

  private enum ProbeFailure: Error { case injected }

  private func identity(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
  }

  private func activator(_ root: URL) -> ThemeActivator {
    ThemeActivator(root: root, faultInjector: { _ in })
  }

  private func package(format: ThemeBackgroundFormat?) throws -> ThemePackage {
    let base = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/kanagawa-wave"))
    let data: Data
    switch format {
    case .png:
      data = try Data(
        contentsOf: repositoryRoot.appending(path: "Tests/Fixtures/Images/test-wallpaper.png"))
    case .jpeg:
      data = try Data(
        contentsOf: repositoryRoot.appending(path: "Themes/kanagawa-wave/wallpapers/1-kanagawa.jpg")
      )
    case .webp:
      data = try Data(
        contentsOf: repositoryRoot.appending(
          path: "Themes/catppuccin-mocha/wallpapers/1-totoro.webp"))
    case nil:
      data = Data()
    }
    let backgrounds =
      format.map { format in
        [
          ThemeBackground(
            id: format.rawValue, path: "wallpapers/fixture.\(format.rawValue)", source: "fixture",
            author: "fixture", license: "MIT", format: format)
        ]
      } ?? []
    return ThemePackage(
      packageURL: base.packageURL, schemaVersion: base.schemaVersion, id: base.id,
      displayName: base.displayName, appearance: base.appearance, semantic: base.semantic,
      terminal: base.terminal, backgrounds: backgrounds,
      backgroundData: backgrounds.first.map { [$0.id: data] } ?? [:], mappings: base.mappings
    )
  }
}
