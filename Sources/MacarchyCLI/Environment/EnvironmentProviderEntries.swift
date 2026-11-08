import Darwin
import Foundation
import ThemeCore

/// Installs and restores managed provider entries and the user originals they displace. A
/// displaced original is renamed aside to a `.retained` name in its own parent directory, so
/// restoring it is one pinned `renameat`, and its identity is the inspector's full evidence.
struct EnvironmentProviderEntries: Sendable {
  let homeDirectory: URL
  let inspector: EnvironmentProviderInspector

  func install(_ record: EnvironmentOwnershipRecord) throws {
    let entry = inspector.managedEntry(from: record)
    // An original that already equals the managed entry is retained too: the managed entry is
    // complete only once the retained original exists, so restore never deletes the original.
    if let retained = record.retainedPath {
      let retainedURL = URL(filePath: retained)
      if try itemExists(retainedURL) {
        guard
          try evidence(
            at: retainedURL,
            matches: record.original,
            directoryLink: record.id.directoryLinkKind
          )
        else { throw EnvironmentLifecycleError.drift(entry.url.path) }
        if try inspector.managedEntryIsExact(entry) { return }
        guard !(try itemExists(entry.url)) else {
          throw EnvironmentLifecycleError.drift(entry.url.path)
        }
      } else {
        guard
          try evidence(
            at: entry.url,
            matches: record.original,
            directoryLink: record.id.directoryLinkKind
          )
        else {
          throw EnvironmentLifecycleError.drift(entry.url.path)
        }
        try retainOriginal(record)
      }
    } else if try inspector.managedEntryIsExact(entry) {
      return
    } else if try itemExists(entry.url) {
      throw EnvironmentLifecycleError.drift(entry.url.path)
    }
    try publishManaged(entry)
  }

  func restore(_ record: EnvironmentOwnershipRecord) throws {
    let entry = inspector.managedEntry(from: record)
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: entry.url.deletingLastPathComponent())
    } catch let error as PinnedFilesystemError
      where error.code == ENOENT && record.original.kind == .absent
    {
      return
    }
    defer { Darwin.close(parent) }
    let managedExact = try inspector.managedEntryIsExact(entry, parentDescriptor: parent)
    let emptyKittyResidue =
      try entry.kind == .kittyDirectory
      && kittyDirectoryIsEmpty(entry, parentDescriptor: parent)
    let publicIsManaged = managedExact || emptyKittyResidue
    // The managed entry is the original itself only if that original already was the managed link.
    let publicMayBeOriginal =
      !publicIsManaged
      || (entry.kind == .symbolicLink && record.original.kind == .symbolicLink
        && record.original.linkDestination == entry.target)
    if publicMayBeOriginal {
      let publicEvidence = try inspector.capturePinned(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url,
        directoryLink: record.id.directoryLinkKind
      )
      if publicEvidence == record.original {
        return
      }
      guard publicIsManaged || publicEvidence.kind == .absent else {
        throw EnvironmentLifecycleError.drift(entry.url.path)
      }
    }
    if let retained = record.retainedPath {
      let retainedURL = URL(filePath: retained)
      let retainedEvidence = try inspector.capturePinned(
        parentDescriptor: parent,
        name: retainedURL.lastPathComponent,
        url: retainedURL,
        directoryLink: record.id.directoryLinkKind
      )
      guard retainedEvidence == record.original else {
        throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
      }
    }
    if entry.kind == .kittyDirectory, managedExact {
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let removedConfiguration = "kitty.conf".withCString {
        Darwin.unlinkat(directory, $0, 0)
      }
      guard removedConfiguration == 0, fsync(directory) == 0 else {
        throw EnvironmentLifecycleError.system(
          "remove managed Kitty configuration bridge",
          entry.url.appending(path: "kitty.conf"),
          errno
        )
      }
    }
    if publicIsManaged {
      let removed = entry.url.lastPathComponent.withCString {
        Darwin.unlinkat(parent, $0, entry.kind == .kittyDirectory ? AT_REMOVEDIR : 0)
      }
      guard removed == 0 else {
        throw EnvironmentLifecycleError.system("remove managed provider entry", entry.url, errno)
      }
    }
    if let retained = record.retainedPath {
      let retainedName = URL(filePath: retained).lastPathComponent
      let restored = retainedName.withCString { source in
        entry.url.lastPathComponent.withCString { destination in
          Darwin.renameat(parent, source, parent, destination)
        }
      }
      guard restored == 0 else {
        throw EnvironmentLifecycleError.system("restore provider entry", entry.url, errno)
      }
    }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: entry.url.lastPathComponent,
        url: entry.url,
        directoryLink: record.id.directoryLinkKind
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift("restored \(entry.url.path)")
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync restored provider entry", entry.url, errno)
    }
  }

  func retainOriginal(_ record: EnvironmentOwnershipRecord) throws {
    guard let retainedPath = record.retainedPath else { return }
    let publicURL = URL(filePath: record.publicPath)
    let retained = URL(filePath: retainedPath)
    let parent = try PinnedFilesystem.openDirectory(at: publicURL.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: publicURL.lastPathComponent,
        url: publicURL,
        directoryLink: record.id.directoryLinkKind
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift(publicURL.path)
    }
    let retainedExists: Bool
    do {
      _ = try PinnedFilesystem.metadata(
        parentDescriptor: parent,
        name: retained.lastPathComponent,
        url: retained
      )
      retainedExists = true
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      retainedExists = false
    }
    guard !retainedExists else {
      throw EnvironmentLifecycleError.blocked("retained path already exists: \(retained.path)")
    }
    let retainedResult = publicURL.lastPathComponent.withCString { source in
      retained.lastPathComponent.withCString { destination in
        Darwin.renameat(parent, source, parent, destination)
      }
    }
    guard retainedResult == 0 else {
      throw EnvironmentLifecycleError.system("retain provider entry", publicURL, errno)
    }
    guard
      try inspector.capturePinned(
        parentDescriptor: parent,
        name: retained.lastPathComponent,
        url: retained,
        directoryLink: record.id.directoryLinkKind
      ) == record.original
    else {
      throw EnvironmentLifecycleError.drift("retained original for \(record.id.rawValue)")
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync retained provider entry", publicURL, errno)
    }
  }

  private func kittyDirectoryIsEmpty(
    _ entry: EnvironmentManagedEntry,
    parentDescriptor: Int32
  ) throws -> Bool {
    guard entry.kind == .kittyDirectory else { return false }
    do {
      let directory = try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: entry.url.lastPathComponent,
        url: entry.url
      )
      defer { Darwin.close(directory) }
      let contents = try PinnedFilesystem.directoryEntries(
        descriptor: directory,
        url: entry.url,
        limit: 1
      )
      return !contents.truncated && contents.entries.isEmpty
    } catch let error as PinnedFilesystemError
      where error.code == ENOENT || error.code == ENOTDIR
    {
      return false
    }
  }

  func publishManaged(_ entry: EnvironmentManagedEntry) throws {
    try ensureSafeEnvironmentParent(
      of: entry.url, homeDirectory: homeDirectory,
      outsideHomeMessage: "provider entry is outside the selected home")
    let parent = entry.url.deletingLastPathComponent()
    let parentDescriptor = try PinnedFilesystem.openDirectory(at: parent)
    defer { Darwin.close(parentDescriptor) }
    let temporaryName = ".macarchy-environment-\(UUID().uuidString.lowercased())"
    let temporary = parent.appending(path: temporaryName)
    switch entry.kind {
    case .symbolicLink:
      let created = entry.target.withCString { target in
        temporaryName.withCString { name in
          Darwin.symlinkat(target, parentDescriptor, name)
        }
      }
      guard created == 0 else {
        throw EnvironmentLifecycleError.system("create provider bridge", temporary, errno)
      }
    case .kittyDirectory:
      let directory = try PinnedFilesystem.createDirectory(
        parentDescriptor: parentDescriptor,
        name: temporaryName,
        url: temporary
      )
      defer { Darwin.close(directory) }
      let configuration = temporary.appending(path: "kitty.conf")
      let created = entry.target.withCString { target in
        Darwin.symlinkat(target, directory, "kitty.conf")
      }
      guard created == 0 else {
        throw EnvironmentLifecycleError.system(
          "create Kitty configuration bridge", configuration, errno)
      }
    }
    defer {
      switch entry.kind {
      case .symbolicLink:
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
      case .kittyDirectory:
        if let directory = try? PinnedFilesystem.openDirectory(
          parentDescriptor: parentDescriptor,
          name: temporaryName,
          url: temporary
        ) {
          "kitty.conf".withCString { _ = Darwin.unlinkat(directory, $0, 0) }
          Darwin.close(directory)
        }
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
      }
    }
    guard
      PinnedFilesystem.renameExclusively(
        temporaryName, to: entry.url.lastPathComponent, in: parentDescriptor)
    else {
      throw EnvironmentLifecycleError.system("publish provider bridge", entry.url, errno)
    }
    guard try inspector.managedEntryIsExact(entry, parentDescriptor: parentDescriptor),
      fsync(parentDescriptor) == 0
    else {
      throw EnvironmentLifecycleError.drift(entry.url.path)
    }
  }

  func evidence(
    at url: URL,
    matches expected: EnvironmentEntryEvidence,
    directoryLink: EnvironmentDirectoryLinkKind?
  ) throws -> Bool {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    return try inspector.capturePinned(
      parentDescriptor: parent,
      name: url.lastPathComponent,
      url: url,
      directoryLink: directoryLink
    ) == expected
  }

  func retainedURL(for entry: EnvironmentManagedEntry) -> URL {
    entry.url.deletingLastPathComponent().appending(
      path: ".macarchy-environment-\(entry.id.rawValue)-\(UUID().uuidString.lowercased()).retained"
    )
  }

  private func itemExists(_ url: URL) throws -> Bool {
    guard let exists = PinnedFilesystem.entryExists(at: url) else {
      throw EnvironmentLifecycleError.system("inspect path", url, errno)
    }
    return exists
  }

  func removeCreatedDirectories(_ paths: [String]) throws {
    for path in paths.sorted(by: { $0.count > $1.count }) {
      let url = URL(filePath: path)
      let home = homeDirectory.standardizedFileURL
      guard url.path.hasPrefix(home.path + "/") else {
        throw EnvironmentLifecycleError.blocked(
          "created provider directory is outside the selected home")
      }
      let parent: Int32
      do {
        parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        continue
      }
      defer { Darwin.close(parent) }
      let removed = url.lastPathComponent.withCString {
        Darwin.unlinkat(parent, $0, AT_REMOVEDIR)
      }
      guard removed == 0 || errno == ENOENT || errno == ENOTEMPTY else {
        throw EnvironmentLifecycleError.system("remove created provider directory", url, errno)
      }
      if removed == 0, fsync(parent) != 0 {
        throw EnvironmentLifecycleError.system("sync removed provider directory", url, errno)
      }
    }
  }
}

/// Opens each directory from `homeDirectory` down to `url`'s parent without following symbolic
/// links, creating the missing ones.
func ensureSafeEnvironmentParent(
  of url: URL, homeDirectory: URL, outsideHomeMessage: String
) throws {
  let home = homeDirectory.standardizedFileURL
  let parent = url.deletingLastPathComponent().standardizedFileURL
  guard parent.path == home.path || parent.path.hasPrefix(home.path + "/") else {
    throw EnvironmentLifecycleError.blocked(outsideHomeMessage)
  }
  var descriptor = try PinnedFilesystem.openDirectory(at: home)
  defer { Darwin.close(descriptor) }
  var current = home
  if parent.path != home.path {
    for component in parent.path.dropFirst(home.path.count + 1).split(separator: "/") {
      current.append(path: String(component), directoryHint: .isDirectory)
      let next: Int32
      do {
        next = try PinnedFilesystem.openDirectory(
          parentDescriptor: descriptor,
          name: String(component),
          url: current
        )
      } catch let error as PinnedFilesystemError where error.code == ENOENT {
        next = try PinnedFilesystem.createDirectory(
          parentDescriptor: descriptor,
          name: String(component),
          url: current
        )
      }
      Darwin.close(descriptor)
      descriptor = next
    }
  }
}
