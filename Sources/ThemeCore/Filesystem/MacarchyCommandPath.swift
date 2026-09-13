import Foundation

package enum MacarchyCommandPath {
  /// Persist the Homebrew entry point, not the versioned binary that is running now.
  /// Resource discovery and process authentication must still use the physical path.
  package static func persistentURL(for executableURL: URL) -> URL {
    let physical = executableURL.resolvingSymlinksInPath().standardizedFileURL
    let components = physical.pathComponents
    if components.count == 8,
      Array(components.prefix(5)) == ["/", "opt", "homebrew", "Cellar", "macarchy"],
      components[6] == "bin", components[7] == "macarchy"
    {
      // Keep a broken/missing Homebrew link visible to normal command preflight;
      // falling back to this Cellar version would recreate the upgrade defect.
      return URL(filePath: "/opt/homebrew/bin/macarchy")
    }
    return physical
  }
}
