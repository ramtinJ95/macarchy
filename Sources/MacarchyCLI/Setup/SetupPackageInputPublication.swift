import Darwin
import Foundation
import ThemeCore

/// Bounded, already-approved source publication, never package execution authority.
struct SetupPackageInputPublication: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let edit: SetupPackageInputEdit
    var savedSnapshot: SetupOwnershipManager.RegularFileSnapshot?
  }
  let schemaVersion: Int
  let contextDigest: String
  let approvalDigest: String
  let sourceBindings: [String: String]
  var entries: [Entry]
  var complete = false
}

struct SetupPackageInputPublicationStore: Sendable {
  let context: UnifiedSetupPlanContext
  var url: URL { context.stateRoot.appending(path: "state/setup/package-input-publication.json") }
  var contextDigest: String {
    SetupPackageInstallationStore(context: context).contextDigest
  }

  func read() throws -> SetupPackageInputPublication? {
    let data: Data
    do { data = try BoundedRegularFile.read(at: url).data } catch BoundedRegularFileError.system(
      operation: "open", code: ENOENT)
    { return nil }
    _ = try StrictJSONObjectDocument(data: data, id: "package_input_publication", target: url)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let record = try decoder.decode(SetupPackageInputPublication.self, from: data)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard
      try JSONSerialization.jsonObject(with: data) as? NSDictionary
        == JSONSerialization.jsonObject(with: encoder.encode(record)) as? NSDictionary
    else { throw SetupPackageAdoptionError("Unknown source publication evidence fields.") }
    try validate(record)
    return record
  }

  func requireResolved() throws {
    guard try read()?.complete != false else {
      throw SetupPackageAdoptionError(
        "Interrupted input publication requires setup add-packages --recover with the same profile/state options. Recovery never starts Homebrew."
      )
    }
  }

  func publish(
    edits: [SetupPackageInputEdit], sourceBindings: [String: String], approval: String,
    checkpoint: @Sendable (Int) throws -> Void
  ) throws {
    guard edits.contains(where: \.changed) else { return }
    var record = SetupPackageInputPublication(
      schemaVersion: 1, contextDigest: contextDigest, approvalDigest: approval,
      sourceBindings: sourceBindings, entries: edits.map { .init(edit: $0) })
    try write(record)
    try finish(&record, checkpoint: checkpoint)
  }

  func recover() throws -> Bool {
    guard var record = try read(), !record.complete else { return false }
    try finish(&record, checkpoint: { _ in })
    return true
  }

  private func finish(
    _ record: inout SetupPackageInputPublication,
    checkpoint: @Sendable (Int) throws -> Void
  ) throws {
    // Inspect EVERY affected input before writing any remaining one. An external
    // change to even an already-published file blocks the whole recovery.
    for index in record.entries.indices {
      try check(record)
      let entry = record.entries[index]
      if entry.savedSnapshot == nil {
        try entry.edit.publish()
        let saved = try SetupPackageInputEdit.inspect(url: entry.edit.url)
        guard saved.before == entry.edit.after, let snapshot = saved.snapshot else {
          throw SetupPackageAdoptionError("Cannot confirm saved input at \(entry.edit.path).")
        }
        record.entries[index].savedSnapshot = snapshot
        // A crash between file replacement and this evidence write is deliberately
        // manual: identical bytes alone cannot authenticate a replacement inode.
        try write(record)
      }
      try checkpoint(index)
    }
    try check(record)
    record.complete = true
    try write(record)
  }

  private func check(_ record: SetupPackageInputPublication) throws {
    for (source, resolved) in record.sourceBindings {
      guard URL(filePath: source).resolvingSymlinksInPath().standardizedFileURL.path == resolved
      else { throw SetupPackageAdoptionError("Profile source resolution drift at \(source).") }
    }
    for entry in record.entries {
      let current = try SetupPackageInputEdit.inspect(url: entry.edit.url)
      let matches: Bool
      if let saved = entry.savedSnapshot {
        matches = current.before == entry.edit.after && current.snapshot == saved
      } else {
        matches = entry.edit.matchesBefore(current)
      }
      guard matches else {
        throw SetupPackageAdoptionError(
          "Input publication drift or unconfirmed replacement at \(entry.edit.path). Preserve the publication record at \(url.path) and inspect manually; no remaining input or package action was started."
        )
      }
    }
  }

  private func write(_ record: SetupPackageInputPublication) throws {
    try validate(record)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(record)
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw SetupPackageAdoptionError("Input publication evidence exceeds 1 MiB.")
    }
    let parentURL = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let parent = try PinnedFilesystem.openDirectory(at: parentURL)
    defer { Darwin.close(parent) }
    try PinnedFilesystem.replaceRegularFileAtomically(
      parentDescriptor: parent, name: url.lastPathComponent, url: url, data: data, mode: 0o600)
  }

  private func validate(_ record: SetupPackageInputPublication) throws {
    let paths = record.entries.map(\.edit.path)
    guard record.schemaVersion == 1, record.contextDigest == contextDigest,
      record.approvalDigest.hasPrefix("sha256:"), record.approvalDigest.count == 71,
      record.approvalDigest.dropFirst(7).allSatisfy({
        $0.isASCII && $0.isHexDigit && !$0.isUppercase
      }),
      record.entries.count == 2, Set(paths).count == paths.count,
      record.sourceBindings.count == 2,
      record.complete
        || Set(record.sourceBindings.keys) == [
          context.profileURL.path, context.machineProfileURL.path,
        ],
      Set(record.sourceBindings.values).count == 2,
      record.entries.allSatisfy({
        let edit = $0.edit
        return edit.path.hasPrefix("/") && edit.url.standardizedFileURL.path == edit.path
          && (edit.before == nil) == (edit.snapshot == nil)
          && edit.after.utf8.count <= BoundedRegularFile.maximumSize
          && (edit.before?.utf8.count ?? 0) <= BoundedRegularFile.maximumSize
          && (edit.snapshot == nil || edit.snapshot?.linkCount == 1)
          && ($0.savedSnapshot == nil || $0.savedSnapshot?.linkCount == 1)
          && (!record.complete || $0.savedSnapshot != nil)
      })
    else { throw SetupPackageAdoptionError("Invalid input publication context or evidence.") }
    let fragment = record.entries[0].edit
    let profile = record.entries[1].edit
    guard record.sourceBindings.values.contains(profile.path),
      !record.sourceBindings.values.contains(fragment.path),
      profile.after.utf8.count <= 65_536,
      try PortableProfileLoader().decode(profile.after, source: profile.url)
        .packages.layers.first?.brewfileURL == fragment.url
    else {
      throw SetupPackageAdoptionError("Recorded inputs do not match the approved profile wiring.")
    }
  }
}
