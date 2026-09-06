import Darwin
import Foundation
import ThemeCore

/// Explicitly approved source editing, not setup ownership or teardown state.
struct SetupPackageInputEdit: Encodable, Sendable {
  let path: String
  let before: String
  let after: String
  let snapshot: SetupOwnershipManager.RegularFileSnapshot

  var changed: Bool { before != after }
  var url: URL { URL(filePath: path) }
  var replacementName: String { ".\(url.lastPathComponent).macarchy-add-packages" }

  static func prepare(url: URL, targets: [HomebrewPackageIdentity]) throws -> Self {
    let manager = SetupOwnershipManager()
    let parent = try manager.openPinnedParent(
      target: url, homeDirectory: URL(filePath: "/"), label: "personal Brewfile")
    defer { Darwin.close(parent) }
    let residue = ".\(url.lastPathComponent).macarchy-add-packages"
    var metadata = stat()
    let inspected = residue.withCString { fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
    guard inspected != 0, errno == ENOENT else {
      throw SetupPackageAdoptionError(
        "Inspect retained publication residue at \(url.deletingLastPathComponent().appending(path: residue).path) before retrying. No automatic recovery or package action is permitted."
      )
    }
    let descriptor = url.lastPathComponent.withCString {
      openat(parent, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw manager.posixError("open personal Brewfile", url) }
    defer { Darwin.close(descriptor) }
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor, url: url, label: "personal Brewfile")
    guard snapshot.linkCount == 1 else {
      throw SetupPackageAdoptionError("Hard-linked personal Brewfiles require manual editing.")
    }
    let file = try BoundedRegularFile.read(descriptor: descriptor)
    guard let before = String(data: file.data, encoding: .utf8) else {
      throw SetupPackageAdoptionError("Personal Brewfile must be UTF-8.")
    }
    let parsed = try SetupBrewfile.parse(before)
    let additions = targets.filter { !parsed.packages.contains($0) }
    var after = before
    if !additions.isEmpty {
      if !after.isEmpty && !after.hasSuffix("\n") { after += "\n" }
      after += SetupBrewfile(packages: additions).text
    }
    _ = try SetupBrewfile.parse(after)
    guard
      snapshot
        == (try manager.regularFileSnapshot(
          descriptor: descriptor, url: url, label: "personal Brewfile"))
    else {
      throw SetupPackageAdoptionError("Personal Brewfile changed during inspection.")
    }
    return Self(path: url.path, before: before, after: after, snapshot: snapshot)
  }

  func publish(using manager: SetupOwnershipManager = .init()) throws {
    guard changed else { return }
    try manager.replaceRegularFile(
      target: url, replacementName: replacementName, homeDirectory: URL(filePath: "/"),
      expectedDigest: sha256Digest(Data(before.utf8)), data: Data(after.utf8),
      label: "personal Brewfile", expectedSnapshot: snapshot)
  }
}
