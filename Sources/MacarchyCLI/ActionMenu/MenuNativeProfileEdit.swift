import Darwin
import Foundation
import ThemeCore

/// Reviewed native-source intent only. Source publication is deliberately separate from
/// connection: a failed connection leaves the saved intent visible, not rolled
/// back over subsequent personal edits.
struct MenuNativeProfileEdit {
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

  static func prepare(
    context: UnifiedSetupPlanContext, source: URL,
    provider: EnvironmentNativeSeed.Provider = .neovim
  ) throws -> Self {
    let edit = try prepare(
      context: context, source: source, table: provider.profileTable, key: provider.profileKey,
      copiedKeys: provider.copiedProfileKeys,
      currentSource: { provider.source(in: $0.environment) })
    guard provider.copiedSource(in: edit.profile.environment) == nil
    else {
      throw EnvironmentLifecycleError.blocked(
        "layered \(provider.rawValue) intent does not select the reviewed native source")
    }
    return edit
  }

  static func keybindings(context: UnifiedSetupPlanContext, source: URL) throws -> Self {
    try prepare(
      context: context, source: source, table: KeybindingProfile.table,
      key: KeybindingProfile.key(\.overrideURL),
      copiedKeys: [], currentSource: { $0.keybindings.overrideURL })
  }

  static func desktop(
    context: UnifiedSetupPlanContext, source: URL, provider: DesktopPersonalProvider
  ) throws -> Self {
    try prepare(
      context: context, source: source, table: provider.profileTable,
      key: provider.configurationKey, copiedKeys: [provider.hookKey],
      currentSource: { provider.source(in: $0) })
  }

  private static func prepare(
    context: UnifiedSetupPlanContext, source: URL, table: String, key: String,
    copiedKeys: [String], currentSource: (PortableProfile) -> URL?
  ) throws -> Self {
    let layered = try load(context)
    let selected =
      layered.fieldOrigins[table + "." + key]
      ?? copiedKeys.first.flatMap { layered.fieldOrigins[table + "." + $0] } ?? .portable
    var files = try [context.profileURL, context.machineProfileURL].map {
      try inspect($0, stateRoot: context.stateRoot)
    }
    guard files[0].physical != files[1].physical else {
      throw EnvironmentLifecycleError.blocked(
        "portable and machine profiles resolve to the same file")
    }
    for index in files.indices {
      let layer: PortableProfileLayerKind = index == 0 ? .portable : .machine
      for copiedKey in copiedKeys
      where layered.layers[index].declaredFields.contains(table + "." + copiedKey) {
        let selector = CanonicalTOMLSelector(
          configuration: files[index].after, table: table, key: copiedKey)
        guard selector.assignments.count == 1 else {
          throw EnvironmentLifecycleError.blocked(
            "cannot safely locate \(table).\(copiedKey); edit this profile field manually")
        }
        files[index].after.removeSubrange(selector.assignments[0].fullRange)
      }
      guard layer == selected else { continue }
      if currentSource(layered.profile)?.path == source.path {
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
      let assignment = "\(key) = \(value)"
      let selector = CanonicalTOMLSelector(
        configuration: files[index].after, table: table, key: key)
      guard selector.tableHeaderCount <= 1, selector.assignments.count <= 1 else {
        throw EnvironmentLifecycleError.blocked("ambiguous \(table) profile declaration")
      }
      if let existing = selector.assignments.first {
        files[index].after.replaceSubrange(existing.contentRange, with: assignment)
      } else if let header = selector.selectionTableHeader {
        files[index].after.insert(
          contentsOf: (header.terminator.isEmpty ? "\n" : "") + assignment + "\n",
          at: header.fullRange.upperBound)
      } else {
        if !files[index].after.hasSuffix("\n") { files[index].after += "\n" }
        files[index].after += "\n[\(table)]\n" + assignment + "\n"
      }
    }
    // An absent, unselected layer stays absent rather than becoming an empty file.
    let proposed = Dictionary(
      uniqueKeysWithValues: files.filter(\.changed).map { ($0.physical, $0.after) })
    let profile = try load(context, proposed: proposed).profile
    guard currentSource(profile)?.path == source.path
    else {
      throw EnvironmentLifecycleError.blocked(
        "layered \(table) intent does not select the reviewed native source")
    }
    return Self(context: context, files: files, profile: profile)
  }

  func validateBefore() throws {
    for file in files {
      let current = try Self.inspect(file.declared, stateRoot: context.stateRoot)
      guard current.physical == file.physical, current.before == file.before,
        current.snapshot == file.snapshot
      else { throw EnvironmentLifecycleError.blocked("profile changed; review native setup again") }
    }
  }

  func publish() throws {
    try validateBefore()
    let manager = SetupOwnershipManager()
    for file in files where file.changed {
      if let before = file.before {
        try manager.replaceRegularFile(
          target: file.physical,
          replacementName: ".\(file.physical.lastPathComponent).macarchy-native-profile",
          homeDirectory: URL(filePath: "/"), expectedDigest: sha256Digest(Data(before.utf8)),
          data: Data(file.after.utf8), label: "Native profile intent",
          expectedSnapshot: file.snapshot)
      } else {
        try GuidedSetupProfileWriter.write(file.after, to: file.physical)
      }
    }
  }

  /// Finishes one reviewed menu step whose plan was already shown. Only an approved step
  /// takes `lock`; under it `replan` throws unless the reviewed step is unchanged, then this
  /// intent is published and `effect` runs. Returns nil when the user declined.
  func publishReviewed<Value>(
    approved: Bool, lock: MenuMutationLock,
    replan: () throws -> Void, effect: () throws -> Value
  ) throws -> Value? {
    guard approved else { return nil }
    return try lock.withLock(stateRoot: context.stateRoot) {
      try replan()
      try publish()
      return try effect()
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
      throw EnvironmentLifecycleError.system("open native profile", physical, errno)
    }
    defer { Darwin.close(descriptor) }
    let manager = SetupOwnershipManager()
    let snapshot = try manager.regularFileSnapshot(
      descriptor: descriptor, url: physical, label: "Native profile")
    guard snapshot.linkCount == 1 else {
      throw EnvironmentLifecycleError.blocked("hard-linked profiles require manual editing")
    }
    let data = try BoundedRegularFile.read(descriptor: descriptor, maximumSize: 65_536).data
    guard let text = String(data: data, encoding: .utf8),
      snapshot
        == (try manager.regularFileSnapshot(
          descriptor: descriptor, url: physical, label: "Native profile"))
    else {
      throw EnvironmentLifecycleError.blocked("profile changed during inspection or is not UTF-8")
    }
    return File(
      declared: declared, physical: physical, before: text, snapshot: snapshot, after: text)
  }
}

/// The lock a reviewed menu step publishes under. Each call site names its flow's lock:
/// the flows deliberately differ, and lock order stays with the caller.
enum MenuMutationLock {
  /// Activation only, as keybinding and desktop connections serialize.
  case activation
  /// The environment lifecycle lock, then activation, as native environment sources serialize.
  case environmentLifecycle

  func withLock<Value>(stateRoot: URL, _ body: () throws -> Value) throws -> Value {
    switch self {
    case .activation:
      return try ActivationLock(root: stateRoot).withLock(body)
    case .environmentLifecycle:
      return try EnvironmentLifecycleLock(stateRoot: stateRoot).withActivationLock(body)
    }
  }
}
