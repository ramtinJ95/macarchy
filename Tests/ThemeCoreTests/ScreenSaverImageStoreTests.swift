import Foundation
import ImageIO
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
  func inspectionWaitsForReceiptPublicationInsteadOfRejectingItsTemporaryFile() async throws {
    try await withTemporaryRoot { root in
      let store = ScreenSaverImageStore(root: root)
      _ = try activator(root).activate(package: package(format: .png))
      _ = try store.reconcile()
      let staged = store.folderURL.appending(
        path: "..macarchy.json-\(UUID().uuidString.lowercased())")
      let completed = DispatchSemaphore(value: 0)
      let (inspections, continuation) = AsyncStream<AdapterInspection>.makeStream()
      try ActivationLock(root: root).withLock {
        try Data("receipt being written".utf8).write(to: staged)
        DispatchQueue.global().async {
          continuation.yield(store.inspection())
          continuation.finish()
          completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 0.03) == .timedOut)
        try FileManager.default.removeItem(at: staged)
      }
      // Other test roots share ActivationLock's process mutex. Join our actual
      // inspection instead of imposing a wall-clock deadline under suite load.
      for await inspection in inspections {
        #expect(inspection.status == .ready)
      }
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

  @Test
  func perThemeScreensaversSurviveWallpaperChangesAndReturnToInheritance() throws {
    try withTemporaryRoot { root in
      let wallpaper = try package(format: .jpeg)
      let independent = try package(format: .png)
      let other = try ThemePackageLoader().load(
        packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha"))
      let preferences = ScreenSaverPreferenceStore(root: root)
      let images = ScreenSaverImageStore(root: root)
      let manifest = try activator(root).activate(package: wallpaper)
      try preferences.select(package: independent, backgroundID: "png")
      let selected = try #require(preferences.load()[wallpaper.id])
      #expect(try preferences.image(for: selected) == independent.firstBackgroundData)
      _ = try images.reconcile()
      let exported = images.folderURL.appending(path: "wallpaper.png")
      #expect(try Data(contentsOf: exported) == independent.firstBackgroundData)
      #expect(
        try ReconciliationStatusStore(root: root).activeManifest().generationID
          == manifest.generationID)
      let receipt = root.appending(path: "state/screensaver-preferences.json")
      let before = try identity(receipt)
      try preferences.select(package: independent, backgroundID: "png")
      #expect(try identity(receipt) == before)

      _ = try activator(root).activate(package: package(format: .webp))
      _ = try images.reconcile()
      #expect(try Data(contentsOf: exported) == independent.firstBackgroundData)
      _ = try activator(root).activate(package: other)
      _ = try images.reconcile()
      #expect(try Data(contentsOf: exported) != independent.firstBackgroundData)
      try preferences.select(package: other, backgroundID: #require(other.backgrounds.first?.id))
      _ = try activator(root).activate(package: wallpaper)
      _ = try images.reconcile()
      #expect(try Data(contentsOf: exported) == independent.firstBackgroundData)
      try preferences.followWallpaper(themeID: wallpaper.id)
      _ = try images.reconcile()
      #expect(try Data(contentsOf: exported) != independent.firstBackgroundData)
      #expect(try preferences.load().keys.sorted() == [other.id])
    }
  }

  @Test(arguments: [false, true])
  func changedSelectionRejectsStalePublicationEvenWhenTheImageAlreadyMatches(matching: Bool) throws
  {
    try withTemporaryRoot { root in
      let first = try package(format: .png)
      let replacement = try package(format: .webp)
      _ = try activator(root).activate(package: first)
      let preferences = ScreenSaverPreferenceStore(root: root)
      let store = ScreenSaverImageStore(root: root)
      _ = try store.reconcile()
      let exported = store.folderURL.appending(path: "wallpaper.png")
      let before = try Data(contentsOf: exported)
      if !matching { try preferences.select(package: replacement, backgroundID: "webp") }
      let racing = ScreenSaverImageStore(
        root: root,
        beforeCompletion: {
          if matching {
            try preferences.select(package: replacement, backgroundID: "webp")
          } else {
            try preferences.followWallpaper(themeID: first.id)
          }
        })
      #expect(throws: ScreenSaverImageError.activeThemeChanged) { try racing.reconcile() }
      #expect(try Data(contentsOf: exported) == before)
    }
  }

  @Test
  func invalidSelectionsAndDamagedSnapshotsFailWithoutFallingBackToWallpaper() throws {
    try withTemporaryRoot { root in
      let selected = try package(format: .png)
      _ = try activator(root).activate(package: package(format: .jpeg))
      let preferences = ScreenSaverPreferenceStore(root: root)
      #expect(throws: (any Error).self) {
        try preferences.select(package: selected, backgroundID: "missing")
      }
      #expect(try preferences.load().isEmpty)
      try preferences.select(package: selected, backgroundID: "png")
      let saved = try #require(preferences.load()[selected.id])
      let image = root.appending(path: "state/screensaver-images/\(saved.imageName)")
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
      try Data("damaged".utf8).write(to: image)
      #expect(throws: (any Error).self) { try ScreenSaverImageStore(root: root).reconcile() }
      #expect(ScreenSaverImageStore(root: root).inspection().status == .failed)
      #expect(throws: (any Error).self) {
        try preferences.select(package: selected, backgroundID: "png")
      }
      try FileManager.default.removeItem(at: image)
      let external = root.appending(path: "external")
      try Data("external".utf8).write(to: external)
      try FileManager.default.createSymbolicLink(at: image, withDestinationURL: external)
      #expect(throws: (any Error).self) { try ScreenSaverImageStore(root: root).reconcile() }
      #expect(try Data(contentsOf: external) == Data("external".utf8))
      try preferences.followWallpaper(themeID: selected.id)
      _ = try ScreenSaverImageStore(root: root).reconcile()
      let document = root.appending(path: "state/screensaver-preferences.json")
      try Data(#"{"schema_version":1,"selections":{},"unknown":true}"#.utf8).write(to: document)
      #expect(throws: (any Error).self) { try preferences.load() }
    }
  }

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
