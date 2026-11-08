import Darwin
import Foundation

/// Mechanics the generation stores share (ADR-0297): staging names and the pinned `current`
/// pointer swap. Each store keeps its records, validation, messages and durability policy.
package enum GenerationStore {
  /// The directory a generation is written in before it is published under its ID.
  package static func stagingName(_ generationID: String) -> String {
    ".staging-\(generationID)"
  }

  package static func isStagingName(_ name: String, isGenerationID: (String) -> Bool) -> Bool {
    name.hasPrefix(".staging-") && isGenerationID(String(name.dropFirst(9)))
  }

  /// The failed step of `replaceCurrent`, so each store keeps its own messages.
  package enum PointerStep: Sendable {
    /// Creating the temporary symbolic link.
    case create
    /// Renaming it over `current`, or syncing the store directory afterwards.
    case replace
  }

  /// Points `current` in the pinned store directory at `generationID` by creating the symbolic
  /// link `temporaryName` and renaming it over `current`, then unlinks the temporary name.
  /// `beforeReplace` runs once the link exists. When `syncs`, the store directory is synced
  /// after the rename. A failed step throws `failure(step, errno)`.
  package static func replaceCurrent(
    in storeDescriptor: Int32,
    with generationID: String,
    through temporaryName: String,
    syncs: Bool,
    beforeReplace: () throws -> Void = {},
    failure: (PointerStep, Int32) -> any Error
  ) throws {
    let created = StateLayout.generationPath(generationID).withCString { destination in
      temporaryName.withCString { Darwin.symlinkat(destination, storeDescriptor, $0) }
    }
    guard created == 0 else { throw failure(.create, errno) }
    defer { temporaryName.withCString { _ = Darwin.unlinkat(storeDescriptor, $0, 0) } }
    try beforeReplace()
    let replaced = temporaryName.withCString { source in
      "current".withCString { Darwin.renameat(storeDescriptor, source, storeDescriptor, $0) }
    }
    guard replaced == 0, !syncs || fsync(storeDescriptor) == 0 else {
      throw failure(.replace, errno)
    }
  }
}
