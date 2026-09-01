import Darwin
import Foundation

extension SetupOwnershipManager {
  func pathContainsSymlink(_ target: URL, below home: URL) throws -> Bool {
    let home = home.standardizedFileURL
    let target = target.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("integration target is outside the selected home")
    }

    let relative = String(target.path.dropFirst(prefix.count))
    var candidate = home
    for component in relative.split(separator: "/") {
      candidate.append(path: String(component))
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0 else {
        let cause = String(cString: strerror(errno))
        throw SetupOwnershipError.system("inspect", candidate, cause)
      }
      if metadata.st_mode & S_IFMT == S_IFLNK { return true }
    }
    return false
  }

  func regularFilePathContainsSymlink(
    id: String,
    target: URL,
    context: Context
  ) throws -> Bool {
    do {
      return try pathContainsSymlink(target, below: context.homeDirectory)
    } catch SetupOwnershipError.system(let operation, _, let cause) {
      throw SetupOwnershipError.system("\(operation) for \(id)", target, cause)
    }
  }

  func parentPathContainsSymlink(_ target: URL, below home: URL) throws -> Bool {
    let parent = target.deletingLastPathComponent()
    let home = home.standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard parent.path == home.path || parent.path.hasPrefix(prefix) else {
      throw SetupOwnershipError.invalidManifest("integration target is outside the selected home")
    }
    let relative = parent.path == home.path ? "" : String(parent.path.dropFirst(prefix.count))
    var candidate = home
    for component in relative.split(separator: "/") {
      candidate.append(path: String(component))
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0 else {
        throw posixError("inspect integration parent", candidate)
      }
      if metadata.st_mode & S_IFMT == S_IFLNK { return true }
      guard metadata.st_mode & S_IFMT == S_IFDIR else {
        throw SetupOwnershipError.system("inspect integration parent", candidate, "not a directory")
      }
    }
    return false
  }
}
