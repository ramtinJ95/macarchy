import Darwin
import Foundation
import ThemeCore

/// Explicitly approved source editing, not setup ownership or teardown state.
struct SetupPackageInputEdit: Codable, Sendable {
  let path: String
  let before: String?
  var after: String
  let snapshot: SetupOwnershipManager.RegularFileSnapshot?

  var changed: Bool { before != after }
  var url: URL { URL(filePath: path) }
  var replacementName: String { ".\(url.lastPathComponent).macarchy-add-packages" }

  static func prepare(url: URL, targets: [HomebrewPackageIdentity]) throws -> Self {
    var edit = try inspect(url: url)
    let parsed = try SetupBrewfile.parse(edit.after)
    let additions = targets.filter { !parsed.packages.contains($0) }
    if !additions.isEmpty {
      if !edit.after.isEmpty && !edit.after.hasSuffix("\n") { edit.after += "\n" }
      edit.after += SetupBrewfile(packages: additions).text
    }
    _ = try SetupBrewfile.parse(edit.after)
    return edit
  }

  static func inspect(url: URL) throws -> Self {
    let manager = SetupOwnershipManager()
    // Absent parents are allowed for new inputs, but existing ancestors must
    // pass the same non-symlink directory walk used during publication.
    var ancestor = url.deletingLastPathComponent()
    var metadata = stat()
    while lstat(ancestor.path, &metadata) != 0 {
      guard errno == ENOENT, ancestor.path != "/" else {
        throw manager.posixError("inspect personal input parent", ancestor)
      }
      ancestor.deleteLastPathComponent()
    }
    let parent = try PinnedFilesystem.openDirectory(at: ancestor)
    defer { Darwin.close(parent) }
    if ancestor != url.deletingLastPathComponent() {
      return Self(path: url.path, before: nil, after: "", snapshot: nil)
    }
    let residue = ".\(url.lastPathComponent).macarchy-add-packages"
    let inspected = residue.withCString { fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
    guard inspected != 0, errno == ENOENT else {
      throw SetupPackageAdoptionError(
        "Inspect retained publication residue at \(url.deletingLastPathComponent().appending(path: residue).path) before retrying. Ambiguous per-file publication requires manual inspection; no package action is permitted."
      )
    }
    let descriptor = url.lastPathComponent.withCString {
      openat(parent, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ENOENT {
        return Self(path: url.path, before: nil, after: "", snapshot: nil)
      }
      throw manager.posixError("open personal package input", url)
    }
    defer { Darwin.close(descriptor) }
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor, url: url, label: "personal package input")
    guard snapshot.linkCount == 1 else {
      throw SetupPackageAdoptionError("Hard-linked personal package inputs require manual editing.")
    }
    let file = try BoundedRegularFile.read(descriptor: descriptor)
    guard let before = String(data: file.data, encoding: .utf8) else {
      throw SetupPackageAdoptionError("Personal package input must be UTF-8: \(url.path).")
    }
    guard
      snapshot
        == (try manager.regularFileSnapshot(
          descriptor: descriptor, url: url, label: "personal package input"))
    else {
      throw SetupPackageAdoptionError("Personal package input changed during inspection.")
    }
    return Self(path: url.path, before: before, after: before, snapshot: snapshot)
  }

  func matchesBefore(_ current: Self) -> Bool {
    current.before == before && current.snapshot == snapshot
  }

  func publish(using manager: SetupOwnershipManager = .init()) throws {
    guard changed else { return }
    guard matchesBefore(try Self.inspect(url: url)) else {
      throw SetupPackageAdoptionError("Personal input drift at \(path); nothing was overwritten.")
    }
    guard let before else {
      try GuidedSetupProfileWriter.write(after, to: url)
      let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
      defer { Darwin.close(parent) }
      guard fsync(parent) == 0 else { throw manager.posixError("sync new personal input", url) }
      return
    }
    try manager.replaceRegularFile(
      target: url, replacementName: replacementName, homeDirectory: URL(filePath: "/"),
      expectedDigest: sha256Digest(Data(before.utf8)), data: Data(after.utf8),
      label: "personal package input", expectedSnapshot: snapshot)
  }
}
