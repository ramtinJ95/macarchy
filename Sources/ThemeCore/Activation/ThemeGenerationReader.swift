import Darwin
import Foundation

/// Reads the theme generation store: the `current` pointer and each generation's
/// `manifest.json`. Active-theme errors stay `ReconciliationStatusError`, whose cases and
/// messages callers already match and report.
package struct ThemeGenerationReader: Sendable {
  /// How strictly a theme generation's `manifest.json` is accepted. Each case is one released
  /// acceptance rule; its checks and their order are part of the rule.
  enum ManifestPolicy: Sendable {
    /// The `current` target or a collectible generation: a read-only manifest with exactly the
    /// keys of its declared supported schema, naming its directory, whose sealed artifacts
    /// validate.
    case published
    /// A generation an interrupted activation published but did not seal: a read-only manifest
    /// with exactly the current schema's keys, naming its directory, whose artifacts validate
    /// while the generation directory is still writable. The declared schema version is not
    /// consulted.
    case unsealed
    /// A reuse candidate the caller already matched by input digest: the current schema's keys
    /// are checked before read-only-ness. The caller validates identity and artifacts.
    case reuseCandidate
  }

  private let root: URL

  package init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// The active manifest, or nil when no generation has been activated yet.
  package func activeManifestIfPresent() throws -> GenerationManifest? {
    do {
      return try activeManifest()
    } catch ReconciliationStatusError.noActiveGeneration {
      return nil
    }
  }

  package func activeManifest() throws -> GenerationManifest {
    for _ in 0..<3 {
      let generationID = try activeGenerationID()
      let generationURL = root.appending(
        path: StateLayout.generationPath(generationID),
        directoryHint: .isDirectory
      )
      do {
        try requireDirectory(generationURL, role: "generation '\(generationID)'")
        let manifest = try Self.manifest(in: generationURL, policy: .published)
        if try activeGenerationID() == generationID {
          return manifest
        }
      } catch {
        if (try? activeGenerationID()) != generationID { continue }
        if let error = error as? ReconciliationStatusError { throw error }
        throw ReconciliationStatusError.invalidActiveGeneration(String(describing: error))
      }
    }
    throw ReconciliationStatusError.invalidActiveGeneration(
      "current changed repeatedly while it was being read"
    )
  }

  /// The generation `current` names, or nil when it is unreadable or names anything other
  /// than `generations/g-<uuid>`.
  func currentGenerationIDIfValid() -> String? {
    guard
      let destination = try? FileManager.default.destinationOfSymbolicLink(
        atPath: StateLayout(root: root).currentTheme.path
      )
    else { return nil }
    return Self.generationID(inCurrentTarget: destination)
  }

  private func activeGenerationID() throws -> String {
    let currentURL = StateLayout(root: root).currentTheme
    var metadata = stat()
    guard lstat(currentURL.path, &metadata) == 0 else {
      let code = errno
      if code == ENOENT { throw ReconciliationStatusError.noActiveGeneration }
      throw ReconciliationStatusError.invalidActiveGeneration(
        "cannot inspect current (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    guard metadata.st_mode & S_IFMT == S_IFLNK else {
      throw ReconciliationStatusError.invalidActiveGeneration("current is not a symbolic link")
    }

    let destination: String
    do {
      destination = try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
    } catch {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "cannot read current symbolic link: \(String(describing: error))"
      )
    }
    guard let generationID = Self.generationID(inCurrentTarget: destination) else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "current target '\(destination)' is not generations/g-<uuid>"
      )
    }
    return generationID
  }

  /// The generation ID in a `current` target that is exactly `generations/g-<uuid>`.
  private static func generationID(inCurrentTarget destination: String) -> String? {
    let components = destination.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components[0] == "generations" else { return nil }
    let generationID = String(components[1])
    return isGenerationID(generationID) ? generationID : nil
  }

  private func requireDirectory(_ url: URL, role: String) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      let code = errno
      throw ReconciliationStatusError.invalidActiveGeneration(
        "\(role) cannot be inspected (errno \(code)): \(String(cString: strerror(code)))"
      )
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
      throw ReconciliationStatusError.invalidActiveGeneration("\(role) is not a directory")
    }
  }

  /// Reads and accepts `manifest.json` in `generationURL` under `policy`. File errors propagate;
  /// a rejected manifest throws `GenerationIntegrityError` with its released reason.
  static func manifest(
    in generationURL: URL,
    policy: ManifestPolicy
  ) throws -> GenerationManifest {
    try manifest(
      from: BoundedRegularFile.read(at: generationURL.appending(path: "manifest.json")),
      in: generationURL,
      policy: policy
    )
  }

  /// Accepts an already read `manifest.json` of `generationURL` under `policy`.
  static func manifest(
    from file: BoundedRegularFile,
    in generationURL: URL,
    policy: ManifestPolicy
  ) throws -> GenerationManifest {
    func requireReadOnly() throws {
      guard file.permissions & 0o222 == 0 else {
        throw GenerationIntegrityError(reason: "manifest.json is writable")
      }
    }

    if policy != .reuseCandidate { try requireReadOnly() }
    let object: [String: Any]?
    do {
      object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any]
    } catch {
      throw GenerationIntegrityError(
        reason: "manifest.json cannot be decoded: \(String(describing: error))"
      )
    }
    let declaredSchemaVersion = object?["manifest_schema_version"] as? Int
    let expectedKeys: Set<String>? =
      policy == .published
      ? declaredSchemaVersion.flatMap(GenerationManifest.encodedKeys(schemaVersion:))
      : GenerationManifest.encodedKeys
    guard let object, let expectedKeys, Set(object.keys) == expectedKeys else {
      throw GenerationIntegrityError(reason: "manifest.json contains unknown or missing fields")
    }
    if policy == .reuseCandidate { try requireReadOnly() }

    let manifest: GenerationManifest
    do {
      manifest = try JSONDecoder().decode(GenerationManifest.self, from: file.data)
    } catch {
      throw GenerationIntegrityError(
        reason: "manifest.json cannot be decoded: \(String(describing: error))"
      )
    }
    if policy == .published, manifest.manifestSchemaVersion != declaredSchemaVersion {
      throw GenerationIntegrityError(reason: "manifest schema version changed while decoding")
    }
    if policy == .reuseCandidate { return manifest }

    let generationID = generationURL.lastPathComponent
    guard manifest.generationID == generationID else {
      throw GenerationIntegrityError(
        reason: "manifest generation_id '\(manifest.generationID)' does not match '\(generationID)'"
      )
    }
    try manifest.validateArtifacts(
      at: generationURL,
      requireReadOnlyGenerationDirectory: policy == .published
    )
    return manifest
  }
}
