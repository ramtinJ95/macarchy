import Darwin
import Foundation

enum KeybindingProviderStatus: String, Encodable, Sendable {
  case managed
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case blocked
}

struct KeybindingProviderInspection: Encodable, Sendable {
  let status: KeybindingProviderStatus
  let entryPoint: String
  let ownership: String
  let source: String?
  let originalTarget: String?
  let message: String
}

struct KeybindingProviderInspector: Sendable {
  static let managedTarget = "../macarchy/keybindings/current/skhdrc"

  func inspect(homeDirectory: URL) -> KeybindingProviderInspection {
    let directory = homeDirectory.appending(
      path: ".config/skhd",
      directoryHint: .isDirectory
    )
    let entry = directory.appending(path: "skhdrc")
    var directoryMetadata = stat()
    guard lstat(directory.path, &directoryMetadata) == 0 else {
      if errno == ENOENT {
        return result(
          .installRequired,
          entry: entry,
          ownership: "absent",
          message: "skhd configuration directory and entry point are absent"
        )
      }
      return result(
        .blocked,
        entry: entry,
        ownership: "unknown",
        message: "cannot inspect skhd configuration directory: \(Self.systemError(errno))"
      )
    }

    switch directoryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      return inspectDirectorySymlink(directory: directory, entry: entry)
    case S_IFDIR:
      return inspectEntry(in: directory, entry: entry)
    default:
      return result(
        .blocked,
        entry: entry,
        ownership: "conflict",
        message: "~/.config/skhd is neither a directory nor a symbolic link"
      )
    }
  }

  private func inspectDirectorySymlink(
    directory: URL,
    entry: URL
  ) -> KeybindingProviderInspection {
    let target: String
    do {
      target = try FileManager.default.destinationOfSymbolicLink(atPath: directory.path)
    } catch {
      return result(
        .blocked,
        entry: entry,
        ownership: "directory_symlink",
        message: "cannot read skhd directory symlink: \(error)"
      )
    }
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    var resolvedMetadata = stat()
    guard lstat(resolvedDirectory.path, &resolvedMetadata) == 0,
      resolvedMetadata.st_mode & S_IFMT == S_IFDIR
    else {
      return result(
        .blocked,
        entry: entry,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "skhd directory symlink does not resolve to a directory"
      )
    }

    let inventory: [String]
    do {
      inventory = try FileManager.default.contentsOfDirectory(atPath: resolvedDirectory.path)
        .sorted()
    } catch {
      return result(
        .blocked,
        entry: entry,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "cannot inventory the skhd directory symlink target: \(error)"
      )
    }
    guard inventory == ["skhdrc"] else {
      let entries = inventory.isEmpty ? "none" : inventory.joined(separator: ", ")
      return result(
        .blocked,
        entry: entry,
        ownership: "directory_symlink",
        originalTarget: target,
        message: "directory-level adoption requires only skhdrc; found: \(entries)"
      )
    }

    let source = resolvedDirectory.appending(path: "skhdrc")
    var sourceMetadata = stat()
    guard lstat(source.path, &sourceMetadata) == 0,
      [S_IFREG, S_IFLNK].contains(sourceMetadata.st_mode & S_IFMT)
    else {
      return result(
        .blocked,
        entry: entry,
        ownership: "directory_symlink",
        source: source,
        originalTarget: target,
        message: "directory-level skhdrc is not a file or symbolic link"
      )
    }
    return result(
      .adoptionRequired,
      entry: entry,
      ownership: "directory_symlink",
      source: source,
      originalTarget: target,
      message: "eligible directory-level symlink requires explicit adoption"
    )
  }

  private func inspectEntry(in directory: URL, entry: URL) -> KeybindingProviderInspection {
    var entryMetadata = stat()
    guard lstat(entry.path, &entryMetadata) == 0 else {
      if errno == ENOENT {
        return result(
          .installRequired,
          entry: entry,
          ownership: "ordinary_directory",
          message: "skhd entry point is absent"
        )
      }
      return result(
        .blocked,
        entry: entry,
        ownership: "ordinary_directory",
        message: "cannot inspect skhd entry point: \(Self.systemError(errno))"
      )
    }

    switch entryMetadata.st_mode & S_IFMT {
    case S_IFLNK:
      do {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        if target == Self.managedTarget {
          return result(
            .managed,
            entry: entry,
            ownership: "managed_symlink",
            originalTarget: target,
            message: "provider entry point targets the current keybinding generation"
          )
        }
        return result(
          .adoptionRequired,
          entry: entry,
          ownership: "entry_symlink",
          source: entry.resolvingSymlinksInPath(),
          originalTarget: target,
          message: "existing skhd entry-point symlink requires explicit adoption"
        )
      } catch {
        return result(
          .blocked,
          entry: entry,
          ownership: "entry_symlink",
          message: "cannot read skhd entry-point symlink: \(error)"
        )
      }
    case S_IFREG:
      return result(
        .adoptionRequired,
        entry: entry,
        ownership: "regular_file",
        source: entry,
        message: "existing skhd file requires explicit adoption"
      )
    default:
      return result(
        .blocked,
        entry: entry,
        ownership: "conflict",
        message: "skhd entry point is neither a file nor a symbolic link"
      )
    }
  }

  private func result(
    _ status: KeybindingProviderStatus,
    entry: URL,
    ownership: String,
    source: URL? = nil,
    originalTarget: String? = nil,
    message: String
  ) -> KeybindingProviderInspection {
    KeybindingProviderInspection(
      status: status,
      entryPoint: entry.path,
      ownership: ownership,
      source: source?.path,
      originalTarget: originalTarget,
      message: message
    )
  }

  private static func systemError(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}
