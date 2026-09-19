import Darwin
import Foundation
import ThemeCore

/// Reviewed Neovim intent only. Source publication is deliberately separate from
/// connection: a failed connection leaves the saved intent visible, not rolled
/// back over subsequent personal edits.
struct MenuNeovimProfileEdit {
  struct File {
    let declared: URL
    let physical: URL
    let before: String?
    let snapshot: SetupOwnershipManager.RegularFileSnapshot?
    var after: String
    var changed: Bool { before.map { $0 != after } ?? !after.isEmpty }
  }

  let context: UnifiedSetupPlanContext
  let files: [File]
  let profile: PortableProfile

  static func prepare(context: UnifiedSetupPlanContext, source: URL) throws -> Self {
    let layered = try load(context)
    let selected =
      layered.fieldOrigins["neovim.native_configuration"]
      ?? layered.fieldOrigins["neovim.configuration"] ?? .portable
    var files = try [context.profileURL, context.machineProfileURL].map {
      try inspect($0, stateRoot: context.stateRoot)
    }
    guard files[0].physical != files[1].physical else {
      throw EnvironmentLifecycleError.blocked(
        "portable and machine profiles resolve to the same file")
    }
    for index in files.indices {
      let layer: PortableProfileLayerKind = index == 0 ? .portable : .machine
      let declaresCopied = layered.layers[index].declaredFields.contains("neovim.configuration")
      if declaresCopied {
        let selector = CanonicalTOMLSelector(
          configuration: files[index].after, table: "neovim", key: "configuration")
        guard selector.assignments.count == 1 else {
          throw EnvironmentLifecycleError.blocked(
            "cannot safely locate neovim.configuration; edit this profile field manually")
        }
        files[index].after.removeSubrange(selector.assignments[0].fullRange)
      }
      guard layer == selected else { continue }
      if layered.profile.environment.neovim.nativeConfigurationDirectoryURL?.path == source.path {
        continue
      }
      if files[index].before == nil { files[index].after = "schema_version = 1\n" }
      let parent = files[index].physical.deletingLastPathComponent().pathComponents
      let destination = source.standardizedFileURL.pathComponents
      let common = zip(parent, destination).prefix { $0 == $1 }.count
      let relative =
        (Array(repeating: "..", count: parent.count - common)
        + destination.dropFirst(common)).joined(separator: "/")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      let value = String(
        decoding: try encoder.encode(relative.isEmpty ? "." : relative), as: UTF8.self)
      let assignment = "native_configuration = \(value)"
      let selector = CanonicalTOMLSelector(
        configuration: files[index].after, table: "neovim", key: "native_configuration")
      guard selector.tableHeaderCount <= 1, selector.assignments.count <= 1 else {
        throw EnvironmentLifecycleError.blocked("ambiguous Neovim profile declaration")
      }
      if let existing = selector.assignments.first {
        files[index].after.replaceSubrange(existing.contentRange, with: assignment)
      } else if let header = selector.selectionTableHeader {
        files[index].after.insert(
          contentsOf: (header.terminator.isEmpty ? "\n" : "") + assignment + "\n",
          at: header.fullRange.upperBound)
      } else {
        if !files[index].after.hasSuffix("\n") { files[index].after += "\n" }
        files[index].after += "\n[neovim]\n" + assignment + "\n"
      }
    }
    // An absent, unselected layer stays absent rather than becoming an empty file.
    let proposed = Dictionary(
      uniqueKeysWithValues: files.filter(\.changed).map { ($0.physical, $0.after) })
    let profile = try load(context, proposed: proposed).profile
    guard profile.environment.neovim.nativeConfigurationDirectoryURL?.path == source.path,
      profile.environment.neovim.configurationDirectoryURL == nil
    else {
      throw EnvironmentLifecycleError.blocked(
        "layered Neovim intent does not select the reviewed native source")
    }
    return Self(context: context, files: files, profile: profile)
  }

  func validateBefore() throws {
    for file in files {
      let current = try Self.inspect(file.declared, stateRoot: context.stateRoot)
      guard current.physical == file.physical, current.before == file.before,
        current.snapshot == file.snapshot
      else { throw EnvironmentLifecycleError.blocked("profile changed; review Neovim setup again") }
    }
  }

  func publish() throws {
    try validateBefore()
    let manager = SetupOwnershipManager()
    for file in files where file.changed {
      if let before = file.before {
        try manager.replaceRegularFile(
          target: file.physical,
          replacementName: ".\(file.physical.lastPathComponent).macarchy-neovim-profile",
          homeDirectory: URL(filePath: "/"), expectedDigest: sha256Digest(Data(before.utf8)),
          data: Data(file.after.utf8), label: "Neovim profile intent",
          expectedSnapshot: file.snapshot)
      } else {
        try GuidedSetupProfileWriter.write(file.after, to: file.physical)
      }
    }
  }

  static func load(_ context: UnifiedSetupPlanContext, proposed: [URL: String] = [:]) throws
    -> LayeredPortableProfile
  {
    try PortableProfileLoader(proposedSources: proposed).load(
      portableAt: context.profileURL, portableRequired: context.profileRequired,
      machineAt: context.machineProfileURL, machineRequired: context.machineProfileRequired)
  }

  private static func inspect(_ declared: URL, stateRoot: URL) throws -> File {
    let physical = declared.resolvingSymlinksInPath()
    // Reuse the editor's generated-state exclusion and dangling-link rejection;
    // inspection never consents to creating a missing profile.
    guard
      try MenuProfileSource.prepare(declared, stateRoot: stateRoot, confirmCreation: { _ in false })
        != nil
    else {
      return File(declared: declared, physical: physical, before: nil, snapshot: nil, after: "")
    }
    let parent = try PinnedFilesystem.openDirectory(at: physical.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let descriptor = physical.lastPathComponent.withCString {
      openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open Neovim profile", physical, errno)
    }
    defer { Darwin.close(descriptor) }
    let manager = SetupOwnershipManager()
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor, url: physical, label: "Neovim profile")
    guard snapshot.linkCount == 1 else {
      throw EnvironmentLifecycleError.blocked("hard-linked profiles require manual editing")
    }
    let data = try BoundedRegularFile.read(descriptor: descriptor, maximumSize: 65_536).data
    guard let text = String(data: data, encoding: .utf8),
      snapshot
        == (try manager.regularFileSnapshot(
          descriptor: descriptor, url: physical, label: "Neovim profile"))
    else {
      throw EnvironmentLifecycleError.blocked("profile changed during inspection or is not UTF-8")
    }
    return File(
      declared: declared, physical: physical, before: text, snapshot: snapshot, after: text)
  }
}
