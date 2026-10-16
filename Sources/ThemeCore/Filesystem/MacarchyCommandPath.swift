import Foundation

package enum MacarchyCommandPath {
  /// Persist the Homebrew entry point, not the versioned binary that is running now.
  /// Resource discovery and process authentication must still use the physical path.
  package static func persistentURL(for executableURL: URL) -> URL {
    let physical = executableURL.resolvingSymlinksInPath().standardizedFileURL
    let components = physical.pathComponents
    if components.count == 8,
      Array(components.prefix(5)) == ["/", "opt", "homebrew", "Cellar", "macarchy"],
      components[6] == "bin", ["macarchy", "macarchy-focus-ring"].contains(components[7])
    {
      // Keep a broken/missing Homebrew link visible to normal command preflight;
      // falling back to this Cellar version would recreate the upgrade defect.
      return URL(filePath: "/opt/homebrew/bin/\(components[7])")
    }
    // A managed helper may also be launched through an explicitly stable source
    // build symlink. Keep that entry point; authenticate its current realpath.
    if executableURL.lastPathComponent == "macarchy-focus-ring" {
      return executableURL.standardizedFileURL
    }
    return physical
  }
}
