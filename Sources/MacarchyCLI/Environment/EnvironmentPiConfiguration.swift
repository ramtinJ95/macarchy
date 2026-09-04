import Darwin
import Foundation
import ThemeCore

struct EnvironmentPiOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalMember: Data?

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalMember = "original_member"
  }

  var hasValidShape: Bool {
    guard path.hasPrefix("/"), originalFileExisted || originalMember == nil else { return false }
    guard let originalMember else { return true }
    guard originalMember.count <= 65_536 else { return false }
    return (try? EnvironmentPiDocument.member(in: Data("{".utf8) + originalMember + Data("}".utf8)))
      != nil
  }
}

struct EnvironmentPiDocument {
  private static let managedMember = Data(
    "\"\(PiAdapter.selectionKey)\": \"\(PiAdapter.themeName)\"".utf8
  )

  static func matchesManaged(_ data: Data, source: URL) throws -> Bool {
    guard let member = try member(in: data, source: source) else { return false }
    let document = try parsed(data, source: source)
    return document.bytes[member.keyRange] == Array("\"\(PiAdapter.selectionKey)\"".utf8)[...]
      && document.bytes[member.valueRange] == Array("\"\(PiAdapter.themeName)\"".utf8)[...]
  }

  static func ownership(for data: Data, source: URL) throws -> EnvironmentPiOwnership {
    let document = try parsed(data, source: source)
    let original = document.members.first(where: { $0.key == PiAdapter.selectionKey }).map {
      Data(document.bytes[$0.keyRange.lowerBound..<$0.valueRange.upperBound])
    }
    return EnvironmentPiOwnership(
      path: source.path,
      originalFileExisted: true,
      originalMember: original
    )
  }

  static func applyingManaged(to data: Data, source: URL) throws -> Data {
    let document = try parsed(data, source: source)
    let candidate: Data
    if let member = document.members.first(where: { $0.key == PiAdapter.selectionKey }) {
      var bytes = Array(document.bytes[..<member.keyRange.lowerBound])
      bytes.append(contentsOf: managedMember)
      bytes.append(contentsOf: document.bytes[member.valueRange.upperBound...])
      candidate = Data(bytes)
    } else {
      do {
        candidate = try SetupOwnershipManager().addingJSONSelection(
          to: data,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: SetupOwnershipManager.piSelectorID,
          target: source
        )
      } catch {
        throw EnvironmentLifecycleError.blocked("invalid Pi settings at \(source.path): \(error)")
      }
    }
    guard try matchesManaged(candidate, source: source) else {
      throw EnvironmentLifecycleError.blocked("cannot install the Pi theme member")
    }
    return candidate
  }

  static func restoringOriginal(
    in data: Data,
    ownership: EnvironmentPiOwnership,
    source: URL
  ) throws -> Data {
    let document = try parsed(data, source: source)
    guard let managed = document.members.first(where: { $0.key == PiAdapter.selectionKey }),
      try matchesManaged(data, source: source)
    else { throw EnvironmentLifecycleError.drift(source.path) }
    let candidate: Data
    if let original = ownership.originalMember {
      var bytes = Array(document.bytes[..<managed.keyRange.lowerBound])
      bytes.append(contentsOf: original)
      bytes.append(contentsOf: document.bytes[managed.valueRange.upperBound...])
      candidate = Data(bytes)
    } else {
      do {
        candidate = try SetupOwnershipManager().removingJSONSelection(
          from: data,
          key: PiAdapter.selectionKey,
          value: PiAdapter.themeName,
          id: SetupOwnershipManager.piSelectorID,
          target: source
        )
      } catch {
        throw EnvironmentLifecycleError.blocked("cannot remove the Pi theme member: \(error)")
      }
    }
    guard try matchesOriginal(candidate, ownership: ownership, source: source) else {
      throw EnvironmentLifecycleError.drift(source.path)
    }
    return candidate
  }

  static func matchesOriginal(
    _ data: Data,
    ownership: EnvironmentPiOwnership,
    source: URL
  ) throws -> Bool {
    let document = try parsed(data, source: source)
    guard let original = ownership.originalMember else {
      return !document.members.contains { $0.key == PiAdapter.selectionKey }
    }
    guard let member = document.members.first(where: { $0.key == PiAdapter.selectionKey }) else {
      return false
    }
    return Data(document.bytes[member.keyRange.lowerBound..<member.valueRange.upperBound])
      == original
  }

  static func isEmptyObject(_ data: Data, source: URL) throws -> Bool {
    try parsed(data, source: source).members.isEmpty
  }

  static func member(in data: Data, source: URL = URL(filePath: "/pi-settings.json")) throws
    -> StrictJSONObjectDocument.Member?
  {
    try parsed(data, source: source).members.first { $0.key == PiAdapter.selectionKey }
  }

  private static func parsed(_ data: Data, source: URL) throws -> StrictJSONObjectDocument {
    do {
      return try StrictJSONObjectDocument(
        data: data,
        id: SetupOwnershipManager.piSelectorID,
        target: source
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("invalid Pi settings at \(source.path): \(error)")
    }
  }
}

struct EnvironmentPiFileTransaction: Sendable {
  private enum ExpectedState {
    case original(EnvironmentPiOwnership)
    case managed
  }

  let homeDirectory: URL

  func preflight(_ ownership: EnvironmentPiOwnership) throws {
    let url = URL(filePath: ownership.path)
    guard try matches(try read(url), .managed, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String
  ) throws {
    guard let ownership = old?.pi ?? new?.pi else { return }
    if let oldPi = old?.pi, let newPi = new?.pi, oldPi != newPi {
      throw EnvironmentLifecycleError.blocked("Pi ownership changed unexpectedly")
    }
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    let source: ExpectedState = old?.pi == nil ? .original(ownership) : .managed
    let target: ExpectedState = new?.pi == nil ? .original(ownership) : .managed
    var current = try read(url)
    if let residueData = try read(residue) {
      if try matches(current, target, ownership: ownership, at: url),
        try matches(residueData, source, ownership: ownership, at: residue)
      {
        try remove(residue)
        return
      }
      if try matches(current, source, ownership: ownership, at: url),
        try matches(residueData, target, ownership: ownership, at: residue)
      {
        try remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("Pi replacement residue")
      }
      current = try read(url)
    }
    if try matches(current, target, ownership: ownership, at: url) { return }
    guard try matches(current, source, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }

    switch target {
    case .managed:
      let updated = try EnvironmentPiDocument.applyingManaged(
        to: current ?? Data("{}\n".utf8),
        source: url
      )
      if let current {
        try replace(updated, current: current, at: url, replacementName: replacementName)
      } else {
        try create(updated, at: url, replacementName: replacementName)
      }
    case .original(let original):
      guard let current else { return }
      let restored = try EnvironmentPiDocument.restoringOriginal(
        in: current,
        ownership: original,
        source: url
      )
      if !original.originalFileExisted,
        try EnvironmentPiDocument.isEmptyObject(restored, source: url)
      {
        try claimAndRemove(at: url, replacementName: replacementName, expected: current)
      } else {
        try replace(restored, current: current, at: url, replacementName: replacementName)
      }
    }
    guard try matches(try read(url), target, ownership: ownership, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(
    _ data: Data?,
    _ state: ExpectedState,
    ownership: EnvironmentPiOwnership,
    at url: URL
  ) throws -> Bool {
    switch state {
    case .managed:
      guard let data else { return false }
      return try EnvironmentPiDocument.matchesManaged(data, source: url)
    case .original(let original):
      guard let data else { return !original.originalFileExisted }
      return try EnvironmentPiDocument.matchesOriginal(data, ownership: original, source: url)
    }
  }

  private func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect Pi settings", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked("Pi settings are not an ordinary file: \(url.path)")
    }
    return try BoundedRegularFile.read(at: url, maximumSize: 1_048_576).data
  }

  private func replace(_ data: Data, current: Data, at url: URL, replacementName: String) throws {
    guard data != current else { return }
    do {
      try SetupOwnershipManager().replaceRegularFile(
        target: url,
        replacementName: replacementName,
        homeDirectory: homeDirectory,
        expectedDigest: sha256Digest(current),
        data: data,
        label: "Pi theme member"
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace Pi theme member: \(error)")
    }
  }

  private func create(_ data: Data, at url: URL, replacementName: String) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let temporary = url.deletingLastPathComponent().appending(path: replacementName)
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: parent,
      name: replacementName,
      url: temporary,
      data: data,
      mode: 0o600
    )
    var removeTemporary = true
    defer {
      if removeTemporary { _ = replacementName.withCString { Darwin.unlinkat(parent, $0, 0) } }
    }
    let published = replacementName.withCString { source in
      url.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard published == 0 else {
      throw EnvironmentLifecycleError.system("publish Pi settings", url, errno)
    }
    removeTemporary = false
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync Pi settings parent", url, errno)
    }
  }

  private func claimAndRemove(at url: URL, replacementName: String, expected: Data) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let claimed = url.lastPathComponent.withCString { source in
      replacementName.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard claimed == 0 else {
      throw EnvironmentLifecycleError.system("claim Pi settings", url, errno)
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync claimed Pi settings", url, errno)
    }
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    guard try read(residue) == expected else {
      throw EnvironmentLifecycleError.drift("claimed Pi settings")
    }
    try remove(residue)
  }

  private func remove(_ url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let removed = url.lastPathComponent.withCString { Darwin.unlinkat(parent, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove Pi transaction residue", url, errno)
    }
    if removed == 0, fsync(parent) != 0 {
      throw EnvironmentLifecycleError.system("sync Pi transaction residue", url, errno)
    }
  }
}
