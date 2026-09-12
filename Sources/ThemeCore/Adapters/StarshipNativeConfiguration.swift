import Darwin
import Foundation
import TOMLDecoder

/// Native behavior is opaque. Only the canonical reserved palette's assignments
/// are replaceable; unfamiliar ownership syntax is drift, never rewrite permission.
package struct StarshipNativeConfiguration {
  package let url: URL

  package init(url: URL) { self.url = url }

  package func seed(behavior: Data, palette: Data) throws -> Data {
    let data =
      Data(
        "# Writable personal Starship configuration. Macarchy owns only palette selection and palettes.macarchy_current.\npalette = \"macarchy_current\"\n\n"
          .utf8
      ) + behavior + Data("\n\n".utf8) + palette
    _ = try replacingPalette(in: data, with: String(decoding: palette, as: UTF8.self))
    return data
  }

  package func read() throws -> Data {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let file = try PinnedFilesystem.readRegularFile(
      parentDescriptor: parent, name: url.lastPathComponent, url: url)
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_nlink == 1,
      metadata.st_mode & 0o200 != 0
    else { throw StarshipAdapterError.bridgeIsNotRegularFile(url) }
    return file.data
  }

  package func replacingPalette(in data: Data, with palette: String) throws -> Data {
    guard let source = String(data: data, encoding: .utf8) else {
      throw StarshipAdapterError.invalidBehavior(url)
    }
    let current = try TOMLDecoder().decode(Ownership.self, from: source)
    let desired = try TOMLDecoder().decode(Ownership.self, from: palette)
    let name = StarshipAdapter.paletteName
    let selection = CanonicalTOMLSelector(configuration: source, key: "palette")
    guard current.palette == name, selection.assignments.count == 1,
      selection.values == ["\"\(name)\""],
      let colors = desired.palettes?[name], let existing = current.palettes?[name],
      Set(existing.keys) == Set(colors.keys),
      Set(colors.keys) == Set(["blue", "bright-black", "cyan", "green", "purple", "red", "yellow"])
    else { throw StarshipAdapterError.bridgeDoesNotMatch(url) }

    var changes = [(Range<String.Index>, String)]()
    for (key, value) in colors {
      let field = CanonicalTOMLSelector(
        configuration: source, table: "palettes.\(name)", key: key)
      guard field.tableHeaderCount == 1, field.assignments.count == 1,
        value.hasPrefix("#"), value.count == 7,
        value.dropFirst().allSatisfy({ $0.isHexDigit })
      else { throw StarshipAdapterError.bridgeDoesNotMatch(url) }
      // Leave even owned comments/spacing intact when the value is unchanged.
      if existing[key] != value {
        changes.append((field.assignments[0].contentRange, "\(key) = \"\(value)\""))
      }
    }
    var result = source
    for (range, replacement) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
      result.replaceSubrange(range, with: replacement)
    }
    _ = try TOMLDecoder().decode(Ownership.self, from: result)
    return Data(result.utf8)
  }

  /// Exchange rather than clobber: retain the displaced file on any ambiguous
  /// publication failure, including an editor racing the final name swap.
  func publish(_ data: Data, replacing expected: Data) throws {
    guard data != expected else { return }
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let residue = ".\(url.lastPathComponent).macarchy-palette"
    let residueURL = url.deletingLastPathComponent().appending(path: residue)
    let original = url.lastPathComponent.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard original >= 0 else {
      throw PinnedFilesystemError(operation: "open native Starship", url: url, code: errno)
    }
    defer { Darwin.close(original) }
    var before = stat()
    guard fstat(original, &before) == 0, before.st_nlink == 1,
      before.st_mode & S_IFMT == S_IFREG,
      try BoundedRegularFile.read(descriptor: original).data == expected
    else { throw StarshipAdapterError.bridgeDoesNotMatch(url) }
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: parent, name: residue, url: residueURL, data: data, mode: 0o600)
    var disposable = true
    defer { if disposable { _ = Darwin.unlinkat(parent, residue, 0) } }
    let staged = Darwin.openat(parent, residue, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
    guard staged >= 0 else {
      throw PinnedFilesystemError(operation: "open staged palette", url: residueURL, code: errno)
    }
    defer { Darwin.close(staged) }
    guard fcopyfile(original, staged, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
      fsync(staged) == 0
    else {
      throw PinnedFilesystemError(operation: "preserve native metadata", url: url, code: errno)
    }
    guard try read() == expected else { throw StarshipAdapterError.bridgeDoesNotMatch(url) }
    guard
      Darwin.renameatx_np(parent, residue, parent, url.lastPathComponent, UInt32(RENAME_SWAP)) == 0
    else {
      throw PinnedFilesystemError(operation: "exchange native palette", url: url, code: errno)
    }
    disposable = false
    var displaced = stat()
    guard fstatat(parent, residue, &displaced, AT_SYMLINK_NOFOLLOW) == 0,
      displaced.st_dev == before.st_dev, displaced.st_ino == before.st_ino,
      displaced.st_nlink == 1,
      try PinnedFilesystem.readRegularFile(parentDescriptor: parent, name: residue, url: residueURL)
        .data
        == expected,
      try read() == data
    else {
      throw StarshipAdapterError.cannotPublishBridge(
        url,
        "concurrent edit; displaced configuration retained at \(residueURL.path); inspect both files before retrying"
      )
    }
    guard Darwin.unlinkat(parent, residue, 0) == 0, fsync(parent) == 0 else {
      throw PinnedFilesystemError(
        operation: "finish native palette publication", url: url, code: errno)
    }
  }
}

private struct Ownership: Decodable {
  let palette: String?
  let palettes: [String: [String: String]]?
}
