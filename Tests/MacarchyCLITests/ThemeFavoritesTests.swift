import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ThemeFavoritesTests {
  @Test(arguments: [
    ("tok ni", true),
    ("TOKYO night", true),
    ("night dark", true),
    ("ky", false),
    ("tokyo light", false),
    ("night-tok", true),
    ("", true),
  ])
  func searchMatchesWhenEveryWordStartsAThemeWord(query: String, matches: Bool) {
    #expect(
      ThemeSearch(query).matches(id: "tokyo-night", displayName: "Tokyo Night", appearance: .dark)
        == matches)
  }

  @Test func searchIgnoresAccentsAndCase() {
    func roséPine(_ query: String) -> Bool {
      ThemeSearch(query).matches(id: "rose-pine", displayName: "Rosé Pine", appearance: .dark)
    }
    #expect(roséPine("rose pi"))
    #expect(ThemeSearch("ROSÉ").matches(id: "rp", displayName: "Rose Pine", appearance: .dark))
    #expect(!roséPine("ose"))
  }

  @Test func favoritesComeFirstAndEachGroupKeepsItsOrder() {
    #expect(
      favoritesFirst(["a", "b", "c", "d"], favorites: ["d", "b"], id: { $0 })
        == ["b", "d", "a", "c"])
  }

  @Test func listShowsMatchingThemesWithFavoritesFirst() throws {
    try withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      let packages = try builtInPackages()
      try ThemeFavoritesStore(root: root).persist(["tokyo-night"])

      let all = ThemeFavorites.live.list(packages, search: ThemeSearch(""), stateRoot: root)
      #expect(all.lines.first?.hasPrefix("tokyo-night\tdark\t") == true)
      #expect(all.lines.count == packages.count)
      #expect(all.notices == [])

      let searched = ThemeFavorites.live.list(
        packages, search: ThemeSearch("kana wa"), stateRoot: root)
      #expect(searched.lines.map { $0.split(separator: "\t").first } == ["kanagawa-wave"])
    }
  }

  @Test func listReportsAnUnreadableRecordAndStillLists() throws {
    try withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      try writeRecord("not json", root: root)
      let packages = try builtInPackages()

      let output = ThemeFavorites.live.list(packages, search: ThemeSearch(""), stateRoot: root)

      #expect(output.lines.count == packages.count)
      #expect(output.notices.first?.hasPrefix("Theme favorites could not be read") == true)
    }
  }

  @Test func addListAndRemoveFavorites() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      let installed: @Sendable () throws -> [ThemePackage] = { try builtInPackages() }
      let favorites = ThemeFavorites.live

      let added = try await favorites.add("kanagawa-wave", packages: installed, stateRoot: root)
      #expect(added.lines == ["Added 'kanagawa-wave' to favorites."])
      _ = try await favorites.add("tokyo-night", packages: installed, stateRoot: root)
      let again = try await favorites.add("tokyo-night", packages: installed, stateRoot: root)
      #expect(again.lines == ["'tokyo-night' is already a favorite."])
      await #expect(throws: ThemeFavoriteError.notInstalled("no-such-theme")) {
        _ = try await favorites.add("no-such-theme", packages: installed, stateRoot: root)
      }

      let listed = try await favorites.favorites(installed, stateRoot: root)
      #expect(
        listed.lines.map { $0.split(separator: "\t").first } == ["kanagawa-wave", "tokyo-night"])

      let removed = try await favorites.remove(
        "kanagawa-wave", packages: installed, stateRoot: root)
      #expect(removed.lines == ["Removed 'kanagawa-wave' from favorites."])
      let missing = try await favorites.remove(
        "kanagawa-wave", packages: installed, stateRoot: root)
      #expect(missing.lines == ["'kanagawa-wave' is not a favorite."])
      let stored = try ThemeFavoritesStore(root: root).load()
      #expect(stored == ["tokyo-night"])
    }
  }

  @Test func favoritesNoLongerInstalledArePrunedWithANotice() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      try ThemeFavoritesStore(root: root).persist(["removed-theme", "tokyo-night"])

      let listed = try await ThemeFavorites.live.favorites(
        { try builtInPackages() }, stateRoot: root)

      #expect(listed.lines.map { $0.split(separator: "\t").first } == ["tokyo-night"])
      #expect(listed.notices == ["Removed favorite 'removed-theme', which is no longer installed."])
      let stored = try ThemeFavoritesStore(root: root).load()
      #expect(stored == ["tokyo-night"])
    }
  }

  @Test func theInventoryIsReadOnlyOnceTheLockIsHeld() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      try ThemeFavoritesStore(root: root).persist(["tokyo-night"])
      let packages = try builtInPackages()
      // A concurrent install holds the lock and finishes before the favorites read the inventory.
      let reinstalled = Flag()
      let installed: @Sendable () throws -> [ThemePackage] = {
        reinstalled.isSet ? packages : packages.filter { $0.id != "tokyo-night" }
      }
      let listing = try await ThemePackageLock(root: root).withLock {
        let listing = Task { try await ThemeFavorites.live.favorites(installed, stateRoot: root) }
        try await Task.sleep(for: .milliseconds(100))
        reinstalled.set()
        return listing
      }

      let listed = try await listing.value

      #expect(listed.lines.map { $0.split(separator: "\t").first } == ["tokyo-night"])
      #expect(listed.notices == [])
    }
  }

  @Test func addingStartsAnUnreadableRecordAgainWithANotice() async throws {
    try await withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      try writeRecord(#"{"schema_version":2,"theme_ids":[]}"#, root: root)

      let added = try await ThemeFavorites.live.add(
        "tokyo-night", packages: { try builtInPackages() }, stateRoot: root)

      #expect(added.lines == ["Added 'tokyo-night' to favorites."])
      #expect(added.notices.count == 2)
      #expect(added.notices.last == "The unreadable theme favorites were started again.")
      let stored = try ThemeFavoritesStore(root: root).load()
      #expect(stored == ["tokyo-night"])
    }
  }

  @Test(arguments: [
    #"{"schema_version":1,"theme_ids":[],"extra":1}"#,
    #"{"schema_version":1,"theme_ids":["Bad Theme"]}"#,
    #"{"schema_version":1,"theme_ids":["tokyo-night","tokyo-night"]}"#,
  ])
  func storeRejectsInvalidRecords(contents: String) throws {
    try withTemporaryRoot(named: "macarchy-theme-favorites") { root in
      try writeRecord(contents, root: root)

      #expect(throws: ThemeFavoritesStoreError.self) {
        try ThemeFavoritesStore(root: root).load()
      }
    }
  }
}

private func builtInPackages() throws -> [ThemePackage] {
  try ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes")).packages()
}

private func writeRecord(_ contents: String, root: URL) throws {
  let url = root.appending(path: "state/theme-favorites.json")
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(contents.utf8).write(to: url)
}

private final class Flag: Sendable {
  private let value = Mutex(false)

  var isSet: Bool { value.withLock { $0 } }
  func set() { value.withLock { $0 = true } }
}
