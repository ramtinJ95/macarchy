import AppKit
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

struct WallpaperOriginalsTests {
  @Test func reconciliationRecordsEachOriginalBeforeTheFirstChangeOnly() async throws {
    try await withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: root.appending(path: "a.png")),
        WallpaperDisplay(id: 2, name: "External", wallpaperURL: root.appending(path: "b.png")),
      ])
      let adapter = WallpaperAdapter(
        root: root, control: displays.control, waitForSettle: {}, now: { "2026-11-08T00:00:00Z" })

      let first = try await adapter.reconciliation(desiredWallpaperURL: {
        generated(root, "g-1")
      }).run()
      #expect(first.status == .applied)
      let recorded = try WallpaperOriginalStore(root: root).load()
      #expect(recorded.map(\.displayUUID) == ["uuid-1", "uuid-2"])
      #expect(recorded.map(\.imagePath) == [path(root, "a.png"), path(root, "b.png")])
      #expect(recorded.first?.presentation == FakeDisplays.presentation(1))

      // A later theme and a user's own change both keep the first original.
      displays.show(root.appending(path: "chosen.png"), on: 1)
      let second = try await adapter.reconciliation(desiredWallpaperURL: {
        generated(root, "g-2")
      }).run()
      #expect(second.status == .applied)
      #expect(try WallpaperOriginalStore(root: root).load() == recorded)
    }
  }

  @Test func reconciliationDoesNotRecordAWallpaperMacarchySetBefore() async throws {
    try await withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: generated(root, "g-0"))
      ])
      let adapter = WallpaperAdapter(root: root, control: displays.control, waitForSettle: {})

      let outcome = try await adapter.reconciliation(desiredWallpaperURL: {
        generated(root, "g-1")
      }).run()

      #expect(outcome.status == .applied)
      #expect(try WallpaperOriginalStore(root: root).load() == [])
    }
  }

  @Test func reconciliationLeavesWallpaperUnchangedWhenTheOriginalCannotBeRecorded() async throws {
    try await withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let state = root.appending(path: "state", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
      let original = root.appending(path: "a.png")
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: original)
      ])
      let adapter = WallpaperAdapter(root: root, control: displays.control, waitForSettle: {})

      let outcome = try await adapter.reconciliation(desiredWallpaperURL: {
        generated(root, "g-1")
      }).run()

      #expect(outcome.status == .failed)
      #expect(outcome.message?.contains("Cannot record the original wallpaper") == true)
      #expect(displays.current(1) == original)
    }
  }

  @Test func reconciliationKeepsAnUnreadableRecordAndReportsIt() async throws {
    try await withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let recordURL = root.appending(path: "state/wallpaper-originals.json")
      try FileManager.default.createDirectory(
        at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("not json".utf8).write(to: recordURL)
      let desired = generated(root, "g-1")
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: root.appending(path: "a.png"))
      ])
      let adapter = WallpaperAdapter(root: root, control: displays.control, waitForSettle: {})

      let outcome = try await adapter.reconciliation(desiredWallpaperURL: { desired }).run()

      #expect(outcome.status == .applied)
      #expect(outcome.message?.contains("teardown cannot restore them") == true)
      #expect(displays.current(1) == desired)
      #expect(try Data(contentsOf: recordURL) == Data("not json".utf8))
    }
  }

  @Test func restorationPlanAppliesTheThreeWayRulePerDisplay() {
    let originals = (1...5).map { original(uuid: "uuid-\($0)", path: "/o/\($0).png") }
    let displays = [
      connected(1, wallpaper: "/m/1.png"),
      connected(2, wallpaper: "/o/2.png"),
      connected(3, wallpaper: "/user/3.png"),
      connected(4, wallpaper: "/m/4.png"),
      connected(6, wallpaper: "/m/6.png"),
    ]

    let steps = WallpaperOriginals.restorationPlan(
      originals: originals,
      displays: displays,
      isMacarchyWallpaper: { $0.path.hasPrefix("/m/") },
      originalExists: { $0 != "/o/4.png" }
    )

    #expect(
      steps == [
        .restore(originals[0], displayID: 1),
        .alreadyOriginal(originals[1]),
        .keepUserChange(originals[2]),
        .originalMissing(originals[3]),
        .disconnected(originals[4]),
        .unrecorded(displayName: "Display 6"),
      ])
  }

  @Test func capturingKeepsOnlyTheNewestDisplays() {
    let count = WallpaperOriginals.maximumDisplays + 8
    let displays = (0..<count).map { index in
      WallpaperDisplay(
        id: UInt32(index), name: "Display \(index)", wallpaperURL: URL(filePath: "/o/\(index).png"))
    }

    let originals = WallpaperOriginals.capturing(
      [],
      displays: displays,
      isMacarchyWallpaper: { _ in false },
      describe: { ("uuid-\($0.id)", WallpaperPresentation()) },
      now: "2026-11-08T00:00:00Z"
    )

    #expect(originals.count == WallpaperOriginals.maximumDisplays)
    #expect(originals.first?.displayUUID == "uuid-8")
    #expect(originals.last?.displayUUID == "uuid-\(count - 1)")
  }

  @Test func storeRoundTripsOriginalsPrivately() throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let store = WallpaperOriginalStore(root: root)
      #expect(try store.load() == [])
      let originals = [
        original(uuid: "uuid-1", path: "/o/1.png"),
        WallpaperOriginal(
          displayUUID: "uuid-2", displayName: "External", imagePath: "/o/2.png",
          presentation: WallpaperPresentation(), recordedAt: "2026-11-08T00:00:00Z"),
      ]

      try store.persist(originals)

      #expect(try store.load() == originals)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: root.appending(path: "state/wallpaper-originals.json").path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      try store.remove()
      #expect(try store.load() == [])
      try store.remove()
    }
  }

  @Test(arguments: [
    #"{"schema_version":1,"displays":[],"extra":true}"#,
    #"{"schema_version":2,"displays":[]}"#,
    "not json",
  ])
  func storeRejectsInvalidDocuments(contents: String) throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let url = root.appending(path: "state/wallpaper-originals.json")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)

      #expect(throws: WallpaperOriginalStoreError.self) {
        try WallpaperOriginalStore(root: root).load()
      }
    }
  }

  @Test func storeRefusesInvalidOriginals() throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let store = WallpaperOriginalStore(root: root)
      let relative = original(uuid: "uuid-1", path: "relative.png")
      let badColor = WallpaperOriginal(
        displayUUID: "uuid-1", displayName: "Built-in", imagePath: "/o/1.png",
        presentation: WallpaperPresentation(fillColor: [2, 0, 0, 1]), recordedAt: "")
      let duplicate = original(uuid: "uuid-1", path: "/o/1.png")

      #expect(throws: WallpaperOriginalStoreError.self) { try store.persist([relative]) }
      #expect(throws: WallpaperOriginalStoreError.self) { try store.persist([badColor]) }
      #expect(throws: WallpaperOriginalStoreError.self) {
        try store.persist([duplicate, duplicate])
      }
      let stored = try store.load()
      #expect(stored == [])
    }
  }

  @Test func presentationRoundTripsThroughDesktopImageOptions() {
    let presentation = WallpaperPresentation(
      imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
      allowClipping: false,
      fillColor: [0.25, 0.5, 0.75, 1]
    )

    #expect(WallpaperPresentation(presentation.options) == presentation)
    #expect(WallpaperPresentation(WallpaperPresentation().options) == WallpaperPresentation())
  }

  @Test func restorerPlansThenRestoresMacarchysWallpaperAndKeepsTheUsersChange() throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: generated(root, "g-1")),
        WallpaperDisplay(id: 2, name: "External", wallpaperURL: URL(filePath: "/user/2.png")),
      ])
      let originals = [
        original(uuid: "uuid-1", path: "/o/1.png", name: "Built-in"),
        original(uuid: "uuid-2", path: "/o/2.png", name: "External"),
        original(uuid: "uuid-9", path: "/o/9.png", name: "Projector"),
      ]
      let store = WallpaperOriginalStore(root: root)
      try store.persist(originals)
      let restorer = restorer(root, displays)

      let plan = restorer.plan()
      #expect(
        plan.lines == [
          "Would restore the original wallpaper on 'Built-in'.",
          "Kept the wallpaper on 'External', which was changed after Macarchy set it.",
          "Display 'Projector' is not connected; its original wallpaper was /o/9.png.",
        ])
      #expect(!plan.mutated)
      #expect(displays.restores() == [])

      let report = restorer.restoreHoldingActivationLock()
      #expect(report.lines.first == "Restored the original wallpaper on 'Built-in'.")
      #expect(report.mutated)
      #expect(displays.restores() == [FakeDisplays.Restore(path: "/o/1.png", displayID: 1)])
      #expect(displays.current(1) == URL(filePath: "/o/1.png"))
      #expect(displays.current(2) == URL(filePath: "/user/2.png"))
      // Until the theme is retired the record stays, so a failed teardown can retry.
      let kept = try store.load()
      #expect(kept == originals)

      let finished = restorer.removeRecord(after: report)
      #expect(finished.lines == report.lines)
      let removed = try store.load()
      #expect(removed == [])
    }
  }

  @Test func restorerReportsFailedAndUnsettledRestores() throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let displays = FakeDisplays(
        [
          WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: generated(root, "g-1")),
          WallpaperDisplay(id: 2, name: "External", wallpaperURL: generated(root, "g-1")),
        ],
        restoreBehavior: [1: .fail, 2: .ignore]
      )
      try WallpaperOriginalStore(root: root).persist([
        original(uuid: "uuid-1", path: "/o/1.png", name: "Built-in"),
        original(uuid: "uuid-2", path: "/o/2.png", name: "External"),
      ])
      let settles = Mutex(0)
      let restorer = WallpaperOriginalRestorer(
        root: root, control: displays.control, originalExists: { _ in true },
        waitForSettle: { settles.withLock { $0 += 1 } })

      let report = restorer.restoreHoldingActivationLock()

      #expect(report.lines.count == 2)
      #expect(
        report.lines.first?.hasPrefix(
          "Could not restore the original wallpaper on 'Built-in' (/o/1.png)") == true)
      #expect(
        report.lines.last
          == "macOS did not show the original wallpaper on 'External' (/o/2.png) after it "
          + "was restored.")
      #expect(settles.withLock { $0 } == 8)
      #expect(report.consumesRecord)
    }
  }

  @Test func restorerKeepsAnUnreadableRecord() throws {
    try withTemporaryRoot(named: "macarchy-wallpaper-originals") { root in
      let recordURL = root.appending(path: "state/wallpaper-originals.json")
      try FileManager.default.createDirectory(
        at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("not json".utf8).write(to: recordURL)
      let displays = FakeDisplays([
        WallpaperDisplay(id: 1, name: "Built-in", wallpaperURL: generated(root, "g-1"))
      ])
      let restorer = restorer(root, displays)

      let report = restorer.removeRecord(after: restorer.restoreHoldingActivationLock())

      #expect(report.lines.first?.hasPrefix("Original wallpapers could not be read") == true)
      #expect(!report.mutated)
      #expect(FileManager.default.fileExists(atPath: recordURL.path))
    }
  }
}

private func restorer(_ root: URL, _ displays: FakeDisplays) -> WallpaperOriginalRestorer {
  WallpaperOriginalRestorer(
    root: root, control: displays.control, originalExists: { _ in true }, waitForSettle: {})
}

private final class FakeDisplays: Sendable {
  struct Restore: Equatable, Sendable {
    let path: String
    let displayID: UInt32
  }

  enum RestoreBehavior: Sendable {
    case fail
    /// macOS accepts the request but keeps showing the previous image.
    case ignore
  }

  private let displays: Mutex<[WallpaperDisplay]>
  private let restored = Mutex<[Restore]>([])
  private let restoreBehavior: [UInt32: RestoreBehavior]

  init(_ displays: [WallpaperDisplay], restoreBehavior: [UInt32: RestoreBehavior] = [:]) {
    self.displays = Mutex(displays)
    self.restoreBehavior = restoreBehavior
  }

  static func presentation(_ displayID: UInt32) -> WallpaperPresentation {
    WallpaperPresentation(
      imageScaling: UInt(displayID), allowClipping: true, fillColor: [0, 0, 0, 1])
  }

  var control: WallpaperControl {
    WallpaperControl(
      inspect: { self.displays.withLock { $0 } },
      set: { url, displayID in self.show(url, on: displayID) },
      displayUUID: { "uuid-\($0)" },
      presentation: { Self.presentation($0) },
      restore: { url, presentation, displayID in
        #expect(presentation == Self.presentation(1))
        switch self.restoreBehavior[displayID] {
        case .fail: throw WallpaperAdapterError.unavailableDisplay(displayID)
        case .ignore: return
        case nil: break
        }
        self.restored.withLock { $0.append(Restore(path: url.path, displayID: displayID)) }
        self.show(url, on: displayID)
      }
    )
  }

  func show(_ url: URL, on displayID: UInt32) {
    displays.withLock { displays in
      guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
      displays[index] = WallpaperDisplay(
        id: displayID, name: displays[index].name, wallpaperURL: url)
    }
  }

  func current(_ displayID: UInt32) -> URL? {
    displays.withLock { $0.first(where: { $0.id == displayID })?.wallpaperURL }
  }

  func restores() -> [Restore] {
    restored.withLock { $0 }
  }
}

private func generated(_ root: URL, _ generationID: String) -> URL {
  root.appending(path: "generations/\(generationID)/generated/wallpaper.png")
}

private func path(_ root: URL, _ name: String) -> String {
  root.appending(path: name).standardizedFileURL.path
}

private func original(uuid: String, path: String, name: String = "Built-in")
  -> WallpaperOriginal
{
  WallpaperOriginal(
    displayUUID: uuid,
    displayName: name,
    imagePath: path,
    presentation: FakeDisplays.presentation(1),
    recordedAt: "2026-11-08T00:00:00Z"
  )
}

private func connected(_ index: Int, wallpaper: String) -> WallpaperConnectedDisplay {
  WallpaperConnectedDisplay(
    id: UInt32(index), uuid: "uuid-\(index)", name: "Display \(index)",
    wallpaperURL: URL(filePath: wallpaper))
}
