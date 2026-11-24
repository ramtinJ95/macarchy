import Darwin
import Foundation
import ThemeCore

/// Bounded guided-setup ownership, not general dotfile management. Originals and
/// displaced starters are never deleted, even after successful restoration.
struct SetupNativeReplacement: Sendable {
  struct Proposal: Codable, Equatable, Sendable {
    let id: String
    let provider: EnvironmentNativeSeed.Provider
    let destination: String
    let backup: String
    let staging: String
    let originalDigest: String
    let linkTarget: String?
    let enclosesKittyFile: Bool

    var summary: String {
      "Move \(destination)\(linkTarget.map { " (link → \($0); target untouched)" } ?? "") to \(backup); install a writable \(provider.rawValue) starter. Teardown restores the original and retains all backups."
    }
  }

  enum Phase: String, Codable, Sendable {
    case preparing, staged, backedUp, installed, restoring, restored, cancelled
  }

  struct Record: Codable, Equatable, Sendable {
    let proposal: Proposal
    var phase: Phase
    var starterDigest: String?
    var displacedStarter: String?
    var restoreStaging: String?
    var restoreDigest: String?
    var partialRestorations: [String]?
  }

  struct Ledger: Codable, Sendable {
    var schemaVersion = 1
    var records: [Record] = []
  }

  enum Checkpoint: CaseIterable, Sendable {
    case journaled, staged, originalMoved, installed, restoreJournaled
    case starterRetained, restoreStaged, originalRestored, restorationRecorded
  }

  let homeDirectory: URL
  let stateRoot: URL
  var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }

  var url: URL { stateRoot.appending(path: "state/setup/native-replacements.json") }

  static let providers: [EnvironmentNativeSeed.Provider] = [.zsh, .kitty, .neovim]

  func propose(_ provider: EnvironmentNativeSeed.Provider) throws -> Proposal? {
    guard Self.providers.contains(provider) else { return nil }
    let standard = provider.standardURL(homeDirectory: homeDirectory)
    var destination = standard
    var enclosesKittyFile = false
    if provider == .kitty, try Self.kind(standard.deletingLastPathComponent()) == S_IFLNK {
      destination = standard.deletingLastPathComponent()
      enclosesKittyFile = true
    }
    guard let kind = try Self.kind(destination) else { return nil }
    guard kind == S_IFLNK || kind == (provider == .neovim ? S_IFDIR : S_IFREG) else {
      throw Self.blocked("Unexpected configuration type at \(destination.path)")
    }
    if try read().records.contains(where: {
      $0.proposal.provider == provider && ![.restored, .cancelled].contains($0.phase)
    }) {
      return nil
    }
    let target: String?
    if kind == S_IFLNK {
      target = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
      var metadata = stat()
      guard stat(destination.path, &metadata) == 0,
        metadata.st_mode & S_IFMT == (provider == .neovim || enclosesKittyFile ? S_IFDIR : S_IFREG),
        access(destination.path, R_OK) == 0
      else {
        throw Self.blocked(
          "Configuration link has an unreadable, looping or unexpected target: \(destination.path)")
      }
    } else {
      target = nil
    }
    let id = UUID().uuidString.lowercased()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
    let backup = destination.path + ".macarchy-backup-\(timestamp)-\(id)"
    let proposal = Proposal(
      id: id, provider: provider, destination: destination.path, backup: backup,
      staging: destination.path + ".macarchy-starter-\(id)",
      originalDigest: try Self.digest(destination), linkTarget: target,
      enclosesKittyFile: enclosesKittyFile)
    try validate(proposal)
    try requireAbsent(URL(filePath: backup))
    try requireAbsent(URL(filePath: proposal.staging))
    return proposal
  }

  func validateReviewed(_ proposal: Proposal) throws {
    try validate(proposal)
    guard try Self.digest(URL(filePath: proposal.destination)) == proposal.originalDigest else {
      throw Self.blocked("Configuration changed after review: \(proposal.destination)")
    }
    try requireAbsent(URL(filePath: proposal.backup))
    try requireAbsent(URL(filePath: proposal.staging))
  }

  func install(_ seed: EnvironmentNativeSeed, approval: String) throws -> EnvironmentNativeSeed.Plan
  {
    let plan = try seed.plan()
    guard let proposal = seed.replacement, plan.approval == approval else {
      throw Self.blocked("Replacement approval changed; review guided setup again")
    }
    return try EnvironmentLifecycleLock(stateRoot: stateRoot).withLock {
      try validateReviewed(proposal)
      var ledger = try read()
      guard !ledger.records.contains(where: { $0.proposal.id == proposal.id }) else {
        throw Self.blocked("Replacement already journaled; run macarchy setup recover")
      }
      guard ledger.records.count < 100 else {
        throw Self.blocked(
          "Replacement ownership is full; retained backups require explicit manual review")
      }
      var record = Record(proposal: proposal, phase: .preparing)
      ledger.records.append(record)
      try write(ledger)
      try checkpoint(.journaled)
      var staged = seed
      staged.replacement = nil
      let staging = URL(filePath: proposal.staging)
      staged.destination =
        proposal.enclosesKittyFile ? staging.appending(path: "kitty.conf") : staging
      staged.createParentDirectory = false
      if proposal.enclosesKittyFile {
        let parent = try PinnedFilesystem.openDirectory(at: staging.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let directory = try PinnedFilesystem.createDirectory(
          parentDescriptor: parent, name: staging.lastPathComponent, url: staging, mode: 0o700)
        Darwin.close(directory)
      }
      // The standard-path starter bytes must retain standard-path semantics while
      // being published to a private sibling. The publisher takes reviewed bytes.
      try staged.publish(plan)
      record.starterDigest = try Self.digest(staging)
      record.phase = .staged
      try update(record)
      try checkpoint(.staged)
      guard try Self.digest(URL(filePath: proposal.destination)) == proposal.originalDigest else {
        throw Self.blocked("Reviewed configuration changed before backup: \(proposal.destination)")
      }
      try move(URL(filePath: proposal.destination), to: URL(filePath: proposal.backup))
      guard try Self.digest(URL(filePath: proposal.backup)) == proposal.originalDigest else {
        throw Self.blocked("Original changed during backup; retained at \(proposal.backup)")
      }
      try checkpoint(.originalMoved)
      record.phase = .backedUp
      try update(record)
      try move(staging, to: URL(filePath: proposal.destination))
      try checkpoint(.installed)
      record.phase = .installed
      try update(record)
      return plan
    }
  }

  /// Called only after provider rollback/teardown, with the owning setup journal
  /// still durable. A recorded ID cannot acquire a newer replacement lifecycle.
  func restore(_ proposals: [Proposal], dryRun: Bool = false) throws -> [String] {
    guard !proposals.isEmpty else { return [] }
    func operation() throws -> [String] {
      var messages = [String]()
      for proposal in proposals.reversed() {
        try validate(proposal)
        guard var record = try read().records.first(where: { $0.proposal.id == proposal.id }) else {
          // An interruption before the per-entry write is safe only if every
          // original is still exactly where review found it and no backup exists.
          try validateReviewed(proposal)
          continue
        }
        guard record.proposal == proposal else {
          throw Self.blocked("Replacement recovery intent changed")
        }
        let destination = URL(filePath: proposal.destination)
        let backup = URL(filePath: proposal.backup)
        if record.phase == .restored || record.phase == .cancelled { continue }
        let backupExists = try Self.kind(backup) != nil
        if !backupExists {
          guard [.preparing, .staged].contains(record.phase),
            try Self.digest(destination) == proposal.originalDigest
          else { throw Self.blocked("Original backup missing: \(proposal.backup)") }
          messages.append(
            "Original unchanged: \(proposal.destination). Any staged starter is retained at \(proposal.staging)."
          )
          if !dryRun {
            record.phase = .cancelled
            try update(record)
          }
          continue
        }
        guard try Self.digest(backup) == proposal.originalDigest else {
          throw Self.blocked("Original backup changed; refusing restoration: \(proposal.backup)")
        }
        if dryRun {
          if try Self.kind(destination) != nil { _ = try Self.digest(destination) }
          messages.append(
            "Restore \(proposal.destination) from retained \(proposal.backup); preserve its current starter in a timestamped sibling backup."
          )
          continue
        }
        if record.phase != .restoring {
          let suffix = Self.restoreSuffix()
          record.displacedStarter = proposal.destination + ".macarchy-backup-\(suffix)-starter"
          record.restoreStaging = proposal.destination + ".macarchy-restore-\(suffix)"
          record.phase = .restoring
          try update(record)
          try checkpoint(.restoreJournaled)
        }
        let retained = URL(filePath: record.displacedStarter!)
        let staging = URL(filePath: record.restoreStaging!)
        // If a complete restore has already been published, only acknowledge it.
        if let digest = record.restoreDigest, try Self.kind(destination) != nil,
          try Self.digest(destination) == digest, try Self.kind(staging) == nil
        {
          record.phase = .restored
          try update(record)
          try checkpoint(.restorationRecorded)
          messages.append(
            "Restored \(proposal.destination); original backup retained at \(proposal.backup); starter retained at \(retained.path)."
          )
          continue
        }
        if try Self.kind(destination) != nil {
          try requireAbsent(retained)
          // Reading through a replacement link is never needed. A new link is
          // preserved as a link, just like the originally reviewed link.
          _ = try Self.digest(destination)
          try move(destination, to: retained)
        }
        let unpublished = URL(filePath: proposal.staging)
        if try Self.kind(unpublished) != nil, try Self.kind(retained) == nil {
          guard try Self.digest(unpublished) == record.starterDigest else {
            throw Self.blocked("Unpublished starter changed: \(unpublished.path)")
          }
          try move(unpublished, to: retained)
        }
        try checkpoint(.starterRetained)
        if try Self.kind(staging) != nil {
          if try record.restoreDigest == nil || Self.digest(staging) != proposal.originalDigest {
            // An interrupted directory copy is not an original backup. Preserve
            // it visibly rather than deleting or overwriting unknown residue.
            let partial = URL(filePath: staging.path + ".partial-" + UUID().uuidString.lowercased())
            record.partialRestorations = (record.partialRestorations ?? []) + [partial.path]
            try update(record)
            try move(staging, to: partial)
            messages.append("Partial restoration retained at \(partial.path)")
          }
        }
        if try Self.kind(staging) == nil {
          try copyTree(backup, to: staging)
        }
        guard try Self.digest(staging) == proposal.originalDigest else {
          throw Self.blocked("Restoration copy differs from retained backup: \(staging.path)")
        }
        record.restoreDigest = proposal.originalDigest
        try update(record)
        try checkpoint(.restoreStaged)
        try move(staging, to: destination)
        try checkpoint(.originalRestored)
        record.phase = .restored
        try update(record)
        try checkpoint(.restorationRecorded)
        messages.append(
          "Restored \(proposal.destination); original backup retained at \(proposal.backup); starter retained at \(retained.path)."
        )
      }
      return messages
    }
    // Like unified dry-run, preview must neither create operational state nor
    // acquire a mutating lifecycle lock. Apply revalidates under both owners.
    return try dryRun
      ? operation() : EnvironmentLifecycleLock(stateRoot: stateRoot).withLock(operation)
  }

  func activeProposals() throws -> [Proposal] {
    try read().records.filter { ![.restored, .cancelled].contains($0.phase) }.map(\.proposal)
  }

  func read() throws -> Ledger {
    guard let data = try BoundedRegularFile.readIfPresent(at: url)?.data else { return Ledger() }
    let ledger = try decodeCanonicalEvidenceJSON(
      Ledger.self, from: data, mismatch: Self.blocked("Invalid replacement ownership ledger"))
    guard ledger.schemaVersion == 1, ledger.records.count <= 100,
      Set(ledger.records.map { $0.proposal.id }).count == ledger.records.count
    else { throw Self.blocked("Invalid replacement ownership ledger") }
    let active = ledger.records.filter { ![.restored, .cancelled].contains($0.phase) }
    guard Set(active.map { $0.proposal.provider }).count == active.count else {
      throw Self.blocked("Conflicting active replacement ownership")
    }
    for record in ledger.records {
      try validate(record.proposal)
      guard
        (record.partialRestorations ?? []).allSatisfy({ path in
          path.hasPrefix((record.restoreStaging ?? "") + ".partial-")
            && URL(filePath: path).deletingLastPathComponent()
              == URL(filePath: record.proposal.destination).deletingLastPathComponent()
        })
      else { throw Self.blocked("Invalid partial restoration paths") }
      if record.phase == .restoring || record.phase == .restored {
        guard let retained = record.displacedStarter, let staging = record.restoreStaging,
          retained.hasPrefix(record.proposal.destination + ".macarchy-backup-"),
          retained.hasSuffix("-starter"),
          staging.hasPrefix(record.proposal.destination + ".macarchy-restore-"),
          URL(filePath: retained).deletingLastPathComponent()
            == URL(filePath: record.proposal.destination).deletingLastPathComponent(),
          URL(filePath: staging).deletingLastPathComponent()
            == URL(filePath: record.proposal.destination).deletingLastPathComponent()
        else { throw Self.blocked("Invalid replacement restoration paths") }
      }
    }
    return ledger
  }

  func status() throws -> [String] {
    var lines = [String]()
    for record in try read().records {
      lines += [
        "\(record.proposal.provider.rawValue) [\(record.phase.rawValue)]: \(record.proposal.destination)",
        "Original backup\(record.phase == .cancelled ? " (not created)" : ""): \(record.proposal.backup)",
      ]
      if let target = record.proposal.linkTarget {
        lines.append("Original link target: \(target) (target untouched)")
      }
      if let retained = record.displacedStarter, try Self.kind(URL(filePath: retained)) != nil {
        lines.append("Retained starter: \(retained)")
      }
      for partial in record.partialRestorations ?? [] {
        if try Self.kind(URL(filePath: partial)) != nil {
          lines.append("Retained partial restoration: \(partial)")
        }
      }
      if try Self.kind(URL(filePath: record.proposal.staging)) != nil {
        lines.append("Retained publication staging: \(record.proposal.staging)")
      }
    }
    return lines
  }

  private func validate(_ proposal: Proposal) throws {
    let standard = proposal.provider.standardURL(homeDirectory: homeDirectory)
    let expected = proposal.enclosesKittyFile ? standard.deletingLastPathComponent() : standard
    guard Self.providers.contains(proposal.provider), UUID(uuidString: proposal.id) != nil,
      proposal.destination == expected.path,
      !proposal.enclosesKittyFile || proposal.provider == .kitty,
      proposal.backup.hasPrefix(expected.path + ".macarchy-backup-"),
      proposal.backup.hasSuffix("-" + proposal.id),
      URL(filePath: proposal.backup).deletingLastPathComponent()
        == expected.deletingLastPathComponent(),
      proposal.staging == expected.path + ".macarchy-starter-" + proposal.id,
      isSHA256Digest(proposal.originalDigest),
      proposal.linkTarget.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true
    else { throw Self.blocked("Invalid replacement paths or ownership") }
    let parent = try PinnedFilesystem.openDirectory(at: expected.deletingLastPathComponent())
    Darwin.close(parent)
  }

  private func write(_ ledger: Ledger) throws {
    let data = try encodeBoundedEvidenceJSON(ledger)
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw Self.blocked("Replacement ownership exceeds the 1 MiB limit")
    }
    let parent = try Self.openJournalDirectory(stateRoot: stateRoot)
    defer { Darwin.close(parent) }
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: parent, name: url.lastPathComponent, url: url, data: data, mode: 0o600)

  }

  private func update(_ record: Record) throws {
    var ledger = try read()
    guard let index = ledger.records.firstIndex(where: { $0.proposal.id == record.proposal.id })
    else {
      throw Self.blocked("Replacement ownership disappeared")
    }
    ledger.records[index] = record
    try write(ledger)
  }

  private func requireAbsent(_ path: URL) throws {
    guard try Self.kind(path) == nil else {
      throw Self.blocked(
        "Backup/staging destination already exists; refusing overwrite: \(path.path)")
    }
  }

  private func move(_ source: URL, to destination: URL) throws {
    guard source.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
      throw Self.blocked("Replacement move must stay beside the original")
    }
    let parent = try PinnedFilesystem.openDirectory(at: source.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    guard
      PinnedFilesystem.renameExclusively(
        source.lastPathComponent, to: destination.lastPathComponent, in: parent)
    else {
      throw EnvironmentLifecycleError.system("exclusively move configuration", destination, errno)
    }
    guard fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("sync configuration move", destination, errno)
    }
  }

  static func kind(_ url: URL) throws -> mode_t? {
    let parent: Int32
    do {
      parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    } catch let error as PinnedFilesystemError where error.code == ENOENT { return nil }
    defer { Darwin.close(parent) }
    var metadata = stat()
    let result = url.lastPathComponent.withCString {
      fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    if result != 0 {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect replacement entry", url, errno)
    }
    return metadata.st_mode & S_IFMT
  }

  /// Never follows links or opens a special file. Bounded inspection makes stale
  /// consent and changed retained originals explicit rather than silently copied.
  static func digest(_ url: URL, depth: Int = 0) throws -> String {
    guard depth < 32, let kind = try kind(url) else {
      throw blocked("Missing or excessively nested configuration: \(url.path)")
    }
    switch kind {
    case S_IFREG:
      return try sha256Digest(Data("file\0".utf8) + BoundedRegularFile.read(at: url).data)
    case S_IFLNK:
      return sha256Digest(
        Data(
          ("link\0" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))).utf8))
    case S_IFDIR:
      let directory = try PinnedFilesystem.openDirectory(at: url)
      defer { Darwin.close(directory) }
      let entries = try PinnedFilesystem.directoryEntries(
        descriptor: directory, url: url, limit: 10000)
      guard !entries.truncated else {
        throw blocked("Configuration directory exceeds 10000 entries: \(url.path)")
      }
      let children = try entries.entries.map { name in
        [name, try digest(url.appending(path: name), depth: depth + 1)]
      }
      return try sha256Digest(Data("directory\0".utf8) + sortedKeysJSON(children))
    default: throw blocked("Special files cannot be replaced or restored: \(url.path)")
    }
  }

  /// Copy without following any source/destination link or opening special files.
  /// Exclusive destination creation and metadata copy operate on pinned descriptors.
  private func copyTree(_ source: URL, to destination: URL, depth: Int = 0) throws {
    guard depth < 32 else { throw Self.blocked("Restoration tree is too deep") }
    let sourceParent = try PinnedFilesystem.openDirectory(at: source.deletingLastPathComponent())
    defer { Darwin.close(sourceParent) }
    let destinationParent = try PinnedFilesystem.openDirectory(
      at: destination.deletingLastPathComponent())
    defer { Darwin.close(destinationParent) }
    var metadata = stat()
    guard
      source.lastPathComponent.withCString({
        fstatat(sourceParent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }) == 0
    else {
      throw EnvironmentLifecycleError.system("inspect restoration source", source, errno)
    }
    if metadata.st_mode & S_IFMT == S_IFLNK {
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
      let result = target.withCString { target in
        destination.lastPathComponent.withCString { symlinkat(target, destinationParent, $0) }
      }
      guard result == 0, fsync(destinationParent) == 0 else {
        throw EnvironmentLifecycleError.system("copy original link", destination, errno)
      }
      return
    }
    let sourceDescriptor = source.lastPathComponent.withCString {
      openat(sourceParent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard sourceDescriptor >= 0 else {
      throw EnvironmentLifecycleError.system("open restoration source", source, errno)
    }
    defer { Darwin.close(sourceDescriptor) }
    guard fstat(sourceDescriptor, &metadata) == 0 else {
      throw EnvironmentLifecycleError.system("inspect pinned restoration source", source, errno)
    }
    let destinationDescriptor: Int32
    switch metadata.st_mode & S_IFMT {
    case S_IFDIR:
      destinationDescriptor = try PinnedFilesystem.createDirectory(
        parentDescriptor: destinationParent, name: destination.lastPathComponent, url: destination,
        mode: 0o700)
      let entries = try PinnedFilesystem.directoryEntries(
        descriptor: sourceDescriptor, url: source, limit: 10000)
      guard !entries.truncated else {
        Darwin.close(destinationDescriptor)
        throw Self.blocked("Restoration directory is too large")
      }
      do {
        for name in entries.entries {
          try copyTree(
            source.appending(path: name), to: destination.appending(path: name), depth: depth + 1)
        }
      } catch {
        Darwin.close(destinationDescriptor)
        throw error
      }
    case S_IFREG:
      let file = try BoundedRegularFile.read(descriptor: sourceDescriptor)
      try PinnedFilesystem.writeNewRegularFile(
        parentDescriptor: destinationParent, name: destination.lastPathComponent,
        url: destination, data: file.data, mode: 0o600)
      destinationDescriptor = destination.lastPathComponent.withCString {
        openat(destinationParent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      }
      guard destinationDescriptor >= 0 else {
        throw EnvironmentLifecycleError.system("open restoration copy", destination, errno)
      }
    default: throw Self.blocked("Special files cannot be restored: \(source.path)")
    }
    defer { Darwin.close(destinationDescriptor) }
    guard
      fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_METADATA))
        == 0,
      fsync(destinationDescriptor) == 0, fsync(destinationParent) == 0
    else {
      throw EnvironmentLifecycleError.system(
        "preserve and sync original metadata", destination, errno)
    }
  }

  static func openJournalDirectory(stateRoot: URL) throws -> Int32 {
    let root = try PinnedFilesystem.openDirectory(at: stateRoot)
    defer { Darwin.close(root) }
    let stateURL = stateRoot.appending(path: "state")
    let state = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: root, name: "state", url: stateURL, mode: 0o700)
    defer { Darwin.close(state) }
    return try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: state, name: "setup", url: stateURL.appending(path: "setup"), mode: 0o700)
  }

  private static func restoreSuffix() -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "") + "-"
      + UUID().uuidString.lowercased()
  }

  private static func blocked(_ message: String) -> EnvironmentLifecycleError {
    .blocked(message + "; use macarchy setup recover for an interrupted replacement")
  }
}
