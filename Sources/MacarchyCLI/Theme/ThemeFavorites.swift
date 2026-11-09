import ArgumentParser
import Foundation
import ThemeCore

enum ThemeFavoriteError: Error, CustomStringConvertible, Equatable {
  case notInstalled(String)

  var description: String {
    switch self {
    case .notInstalled(let themeID):
      "Theme '\(themeID)' is not installed; see 'macarchy theme list'"
    }
  }
}

/// A command's output lines and the notices it prints to standard error.
struct ThemeFavoritesOutput: Equatable, Sendable {
  var lines: [String]
  var notices: [String] = []
}

/// Favorite themes, a preference record that puts themes first in every theme list. It is never
/// canonical state: an unreadable record is a notice, and favorites that are no longer installed
/// are pruned with a notice whenever the favorites are changed or listed. Those commands read the
/// installed themes (`packages`) only once they hold ThemePackageLock, so a theme installed or
/// removed meanwhile is never judged on a stale inventory.
struct ThemeFavorites: Sendable {
  let load: @Sendable (URL) throws -> [String]
  let persist: @Sendable ([String], URL) throws -> Void

  static let live = Self(
    load: { try ThemeFavoritesStore(root: $0).load() },
    persist: { try ThemeFavoritesStore(root: $1).persist($0) }
  )

  /// `theme list`: installed themes matching `search`, favorites first. It never writes, so a
  /// stale favorite is simply not installed here and goes unmentioned.
  func list(
    _ packages: [ThemePackage], search: ThemeSearch, stateRoot: URL
  ) -> ThemeFavoritesOutput {
    var notices: [String] = []
    let favorites: Set<String>
    do {
      favorites = Set(try load(stateRoot))
    } catch {
      favorites = []
      notices.append("Theme favorites could not be read, so they are not listed first: \(error).")
    }
    let matching = packages.filter {
      search.matches(id: $0.id, displayName: $0.displayName, appearance: $0.appearance)
    }
    return ThemeFavoritesOutput(
      lines: favoritesFirst(matching, favorites: favorites, id: \.id).map(Self.line),
      notices: notices
    )
  }

  /// `theme favorite list`: installed favorites in the order they were added.
  func favorites(
    _ packages: @escaping @Sendable () throws -> [ThemePackage], stateRoot: URL
  ) async throws -> ThemeFavoritesOutput {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: false) {
      let packages = try packages()
      let resolved = resolveLocked(installed: Swift.Set(packages.map(\.id)), stateRoot: stateRoot)
      let byID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
      return ThemeFavoritesOutput(
        lines: resolved.themeIDs.compactMap { byID[$0] }.map(Self.line),
        notices: resolved.notices
      )
    }
  }

  func add(
    _ themeID: String, packages: @escaping @Sendable () throws -> [ThemePackage], stateRoot: URL
  ) async throws -> ThemeFavoritesOutput {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: false) {
      let installed = Swift.Set(try packages().map(\.id))
      guard installed.contains(themeID) else {
        throw ThemeFavoriteError.notInstalled(themeID)
      }
      var resolved = resolveLocked(installed: installed, stateRoot: stateRoot)
      guard !resolved.themeIDs.contains(themeID) else {
        return ThemeFavoritesOutput(
          lines: ["'\(themeID)' is already a favorite."], notices: resolved.notices)
      }
      if !resolved.readable {
        resolved.notices.append("The unreadable theme favorites were started again.")
      }
      try persist(resolved.themeIDs + [themeID], stateRoot)
      return ThemeFavoritesOutput(
        lines: ["Added '\(themeID)' to favorites."], notices: resolved.notices)
    }
  }

  func remove(
    _ themeID: String, packages: @escaping @Sendable () throws -> [ThemePackage], stateRoot: URL
  ) async throws -> ThemeFavoritesOutput {
    try await withThemePackageLock(stateRoot: stateRoot, unlessDryRun: false) {
      let installed = Swift.Set(try packages().map(\.id))
      let resolved = resolveLocked(installed: installed, stateRoot: stateRoot)
      guard resolved.themeIDs.contains(themeID) else {
        return ThemeFavoritesOutput(
          lines: ["'\(themeID)' is not a favorite."], notices: resolved.notices)
      }
      try persist(resolved.themeIDs.filter { $0 != themeID }, stateRoot)
      return ThemeFavoritesOutput(
        lines: ["Removed '\(themeID)' from favorites."], notices: resolved.notices)
    }
  }

  struct Resolved: Equatable, Sendable {
    var themeIDs: [String]
    var notices: [String]
    /// False when the record could not be read; it is then left as it is unless replaced.
    var readable: Bool
  }

  /// The installed favorites, oldest first. Favorites no longer installed are removed from the
  /// record with a notice. The caller holds ThemePackageLock.
  func resolveLocked(installed: Swift.Set<String>, stateRoot: URL) -> Resolved {
    let recorded: [String]
    do {
      recorded = try load(stateRoot)
    } catch {
      return Resolved(
        themeIDs: [], notices: ["Theme favorites could not be read: \(error)."], readable: false)
    }
    let kept = recorded.filter(installed.contains)
    let removed = recorded.filter { !installed.contains($0) }
    var notices = removed.map { "Removed favorite '\($0)', which is no longer installed." }
    if !removed.isEmpty {
      do {
        try persist(kept, stateRoot)
      } catch {
        notices.append("Theme favorites were not updated: \(error).")
      }
    }
    return Resolved(themeIDs: kept, notices: notices, readable: true)
  }

  static func line(_ package: ThemePackage) -> String {
    "\(package.id)\t\(package.appearance.rawValue)\t\(package.displayName)"
  }
}

extension Theme {
  struct Favorite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Mark themes as favorites, which every theme list shows first.",
      subcommands: [Add.self, Remove.self, List.self]
    )

    struct Options: ParsableArguments {
      @OptionGroup var roots: ThemeRootOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = StateLayout.defaultRootPath

      var stateRootURL: URL {
        URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      }

      /// Reads the installed themes when called, so the runner can call it under the lock.
      var packages: @Sendable () throws -> [ThemePackage] {
        let repository = roots.repository(userRoot: StateLayout(root: stateRootURL).userThemes)
        return { try repository.packages() }
      }
    }

    struct Add: AsyncParsableCommand {
      static let configuration = CommandConfiguration(abstract: "Add a theme to favorites.")

      @OptionGroup var options: Options

      @Argument(help: "Theme package identifier.")
      var themeID: String

      mutating func run() async throws {
        emit(
          try await ThemeFavorites.live.add(
            themeID, packages: options.packages, stateRoot: options.stateRootURL))
      }
    }

    struct Remove: AsyncParsableCommand {
      static let configuration = CommandConfiguration(abstract: "Remove a theme from favorites.")

      @OptionGroup var options: Options

      @Argument(help: "Theme package identifier.")
      var themeID: String

      mutating func run() async throws {
        emit(
          try await ThemeFavorites.live.remove(
            themeID, packages: options.packages, stateRoot: options.stateRootURL))
      }
    }

    struct List: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "List favorite themes in the order they were added.")

      @OptionGroup var options: Options

      mutating func run() async throws {
        emit(
          try await ThemeFavorites.live.favorites(
            options.packages, stateRoot: options.stateRootURL))
      }
    }
  }
}

/// Prints `output`'s lines, and its notices to standard error so the lines stay parseable.
func emit(_ output: ThemeFavoritesOutput) {
  for line in output.lines { print(line) }
  for notice in output.notices {
    FileHandle.standardError.write(Data("\(notice)\n".utf8))
  }
}
