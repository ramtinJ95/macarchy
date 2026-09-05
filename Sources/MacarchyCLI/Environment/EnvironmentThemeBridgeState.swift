import Darwin
import Foundation
import ThemeCore

struct EnvironmentThemeBridgeState: Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let path: String
    let data: Data?
    let mode: UInt16?

    var hasValidShape: Bool {
      switch (data, mode) {
      case (nil, nil):
        true
      case (.some, .some(let mode)):
        mode & ~0o7777 == 0
      default:
        false
      }
    }
  }

  let entries: [Entry]

  static func capture(profile: EnvironmentProfile, stateRoot: URL) throws -> Self {
    var ids = Set<EnvironmentEntryID>()
    if profile.terminal == .kitty { ids.insert(.kitty) }
    if profile.prompt == .starship { ids.insert(.starship) }
    return try capture(ids: ids, stateRoot: stateRoot)
  }

  static func capture(ids: Set<EnvironmentEntryID>, stateRoot: URL) throws -> Self {
    let urls = paths(ids: ids, stateRoot: stateRoot).map { URL(filePath: $0) }
    return try Self(
      entries: urls.map { url in
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
          if errno == ENOENT { return Entry(path: url.path, data: nil, mode: nil) }
          throw EnvironmentLifecycleError.system("inspect theme bridge", url, errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
          throw EnvironmentLifecycleError.blocked("theme bridge is not a regular file: \(url.path)")
        }
        return Entry(
          path: url.path,
          data: try BoundedRegularFile.read(at: url).data,
          mode: UInt16(metadata.st_mode & 0o7777)
        )
      }
    )
  }

  static func paths(ids: Set<EnvironmentEntryID>, stateRoot: URL) -> [String] {
    (ids.contains(.kitty)
      ? [stateRoot.appending(path: "state/adapters/kitty.conf").path] : [])
      + (ids.contains(.starship)
        ? [stateRoot.appending(path: StarshipAdapter.bridgePath).path] : [])
  }

  static func pathsAreValid(_ entries: [Entry], stateRoot: URL) -> Bool {
    let paths = entries.map(\.path)
    return entries.allSatisfy(\.hasValidShape)
      && Set(paths).count == paths.count
      && Set(paths).isSubset(of: Set(Self.paths(ids: [.kitty, .starship], stateRoot: stateRoot)))
  }

  func restore() throws {
    for entry in entries {
      let url = URL(filePath: entry.path)
      if let data = entry.data {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        if let mode = entry.mode, chmod(url.path, mode_t(mode)) != 0 {
          throw EnvironmentLifecycleError.system("restore theme bridge mode", url, errno)
        }
      } else if unlink(url.path) != 0, errno != ENOENT {
        throw EnvironmentLifecycleError.system("remove new theme bridge", url, errno)
      }
    }
  }
}
