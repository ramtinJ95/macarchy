import ArgumentParser
import Darwin
import Foundation

enum MenuProfileSource {
  /// Resolve only declared profile files, never a generated-state editing surface.
  /// Return nil on declined creation; preserve existing links and bytes.
  static func prepare(
    _ target: URL, stateRoot: URL, confirmCreation: (URL) -> Bool
  ) throws -> URL? {
    let resolved = target.resolvingSymlinksInPath()
    for name in [
      "generations", "current", "previous", "keybindings", "desktop", "environment", "state",
    ] {
      let directory = stateRoot.appending(path: name)
      for forbidden in [
        directory.standardizedFileURL.path, directory.resolvingSymlinksInPath().path,
      ] {
        guard
          ![target.standardizedFileURL.path, resolved.path].contains(where: {
            $0 == forbidden || $0.hasPrefix(forbidden + "/")
          })
        else {
          throw ValidationError(
            "Generated Macarchy state is not an editable profile: \(target.path)")
        }
      }
    }
    var metadata = stat()
    if lstat(resolved.path, &metadata) == 0 {
      guard metadata.st_mode & S_IFMT == S_IFREG, access(resolved.path, R_OK | W_OK) == 0 else {
        throw ValidationError(
          "Profile must be an ordinary readable, writable file: \(resolved.path)")
      }
      return resolved
    }
    guard errno == ENOENT else {
      throw ValidationError(
        "Could not inspect profile \(resolved.path): \(String(cString: strerror(errno)))")
    }
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
      throw ValidationError("Profile is a dangling symlink; repair its destination before editing")
    }
    guard confirmCreation(resolved) else { return nil }
    try FileManager.default.createDirectory(
      at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema_version = 1\n".utf8).write(to: resolved, options: .withoutOverwriting)
    return resolved
  }
}
