import Darwin
import Foundation
import ThemeCore

/// Absent-only preparation of the supported LazyVim theme seam. This grants no
/// active connection authority and never replaces personal Lua or a lockfile.
struct EnvironmentNeovimThemePreparation {
  let source: URL
  let homeDirectory: URL
  let stateRoot: URL

  struct Plan: Equatable {
    let root: URL
    let directories: [String]
    let links: [String]
    let approval: String
  }

  func plan() throws -> Plan {
    let migration = EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: source)
    guard migration.targetIsAllowed(source.path, userOwnedPublicEntry: true) else {
      throw EnvironmentLifecycleError.blocked("Neovim source overlaps managed configuration")
    }
    let root = source.resolvingSymlinksInPath()
    let descriptor = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(descriptor) }
    guard access(root.path, W_OK) == 0 else {
      throw EnvironmentLifecycleError.blocked("Neovim source is not writable")
    }
    let initURL = try migration.writableInitURL(at: source)
    let initial = try BoundedRegularFile.read(at: initURL).data
    var evidence = [source.path, root.path, initURL.path, sha256Digest(initial)]
    var directories: Set<String> = []
    var links: [String] = []
    var identity = stat()
    guard fstat(descriptor, &identity) == 0 else {
      throw EnvironmentLifecycleError.system("inspect Neovim source", root, errno)
    }
    evidence.append("root:\(identity.st_dev):\(identity.st_ino)")
    for path in EnvironmentNeovimMigration.themePaths.sorted() {
      let parts = path.split(separator: "/").map(String.init)
      var parent = descriptor
      var opened: [Int32] = []
      defer { for fd in opened { Darwin.close(fd) } }
      var missingParent = false
      for index in 0..<(parts.count - 1) {
        let relative = parts[...index].joined(separator: "/")
        if missingParent {
          directories.insert(relative)
          continue
        }
        let rc = parts[index].withCString { fstatat(parent, $0, &identity, AT_SYMLINK_NOFOLLOW) }
        if rc != 0 {
          guard errno == ENOENT else {
            throw EnvironmentLifecycleError.system(
              "inspect Neovim theme parent", root.appending(path: relative), errno)
          }
          missingParent = true
          directories.insert(relative)
          continue
        }
        guard identity.st_mode & S_IFMT == S_IFDIR else {
          throw EnvironmentLifecycleError.blocked(
            "Neovim theme parent must be an ordinary directory: \(relative)")
        }
        let next = parts[index].withCString {
          openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else {
          throw EnvironmentLifecycleError.system(
            "open Neovim theme parent", root.appending(path: relative), errno)
        }
        opened.append(next)
        parent = next
        evidence.append("\(relative):\(identity.st_dev):\(identity.st_ino)")
      }
      if missingParent {
        links.append(path)
        continue
      }
      let leaf = parts.last!
      let rc = leaf.withCString { fstatat(parent, $0, &identity, AT_SYMLINK_NOFOLLOW) }
      if rc != 0 {
        guard errno == ENOENT else {
          throw EnvironmentLifecycleError.system(
            "inspect Neovim theme seam", root.appending(path: path), errno)
        }
        links.append(path)
      } else {
        guard identity.st_mode & S_IFMT == S_IFLNK,
          try PinnedFilesystem.symlinkDestination(
            parentDescriptor: parent, name: leaf, url: root.appending(path: path))
            == target(path)
        else {
          throw EnvironmentLifecycleError.blocked(
            "Neovim theme path already contains personal configuration; it will not be overwritten: \(root.appending(path: path).path)"
          )
        }
        evidence.append("\(path):\(identity.st_dev):\(identity.st_ino):\(target(path))")
      }
    }
    let lock = root.appending(path: "lazy-lock.json")
    if lstat(lock.path, &identity) == 0 {
      guard identity.st_mode & S_IFMT == S_IFREG, access(lock.path, W_OK) == 0 else {
        throw EnvironmentLifecycleError.blocked(
          "Neovim lazy-lock.json must be an ordinary writable file")
      }
    } else if errno != ENOENT {
      throw EnvironmentLifecycleError.system("inspect Neovim lockfile", lock, errno)
    }
    let orderedDirectories = directories.sorted {
      $0.split(separator: "/").count == $1.split(separator: "/").count
        ? $0 < $1 : $0.split(separator: "/").count < $1.split(separator: "/").count
    }
    let digest = sha256Digest(
      try JSONEncoder().encode(
        [evidence, orderedDirectories, links, [stateRoot.path]]))
    return Plan(root: root, directories: orderedDirectories, links: links, approval: digest)
  }

  /// Completed absent-only additions deliberately remain on interruption. A
  /// fresh review recognizes exact links and resumes; user files never roll back.
  func prepare(approval: String) throws {
    let plan = try plan()
    guard plan.approval == approval else {
      throw EnvironmentLifecycleError.blocked("Neovim theme preparation changed; review it again")
    }
    for path in plan.directories {
      let url = plan.root.appending(path: path)
      let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      let directory = try PinnedFilesystem.createDirectory(
        parentDescriptor: parent, name: url.lastPathComponent, url: url)
      Darwin.close(directory)
      guard fsync(parent) == 0 else {
        throw EnvironmentLifecycleError.system("sync Neovim theme parent", url, errno)
      }
    }
    for path in plan.links {
      let url = plan.root.appending(path: path)
      let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      let rc = target(path).withCString { destination in
        url.lastPathComponent.withCString { symlinkat(destination, parent, $0) }
      }
      guard rc == 0, fsync(parent) == 0 else {
        throw EnvironmentLifecycleError.system("publish absent Neovim theme link", url, errno)
      }
    }
    try EnvironmentNeovimMigration(
      homeDirectory: homeDirectory, stateRoot: stateRoot, sourceURL: source
    ).validateNativeTree(userOwnedPublicEntry: true)
  }

  private func target(_ path: String) -> String {
    stateRoot.appending(path: "environment/current/neovim/\(path)").path
  }
}
