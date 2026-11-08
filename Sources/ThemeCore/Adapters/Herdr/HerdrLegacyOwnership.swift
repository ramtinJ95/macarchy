import Foundation

package struct HerdrLegacyOwnershipEvidence: Equatable, Sendable {
  package let originalConfiguration: String
  package let currentConfiguration: String
}

extension HerdrAdapter {
  private var backupURL: URL {
    root.appending(path: "state/adapters/herdr-config.toml.backup")
  }

  private var ownershipURL: URL {
    root.appending(path: "state/adapters/herdr-theme-ownership.json")
  }

  package func legacyOwnershipEvidence() throws -> HerdrLegacyOwnershipEvidence? {
    guard try authenticatedLegacyOwnershipMatchesCurrentGeneration() else { return nil }
    guard let state = try readOwnership() else {
      throw HerdrAdapterError.invalidOwnership
    }
    let current = try readConfiguration()
    let currentParsed = try Self.parseConfiguration(current.text)
    guard currentParsed.surface == state.desired else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence does not authenticate the current theme surface"
      )
    }
    let original = try readBackupText()
    return HerdrLegacyOwnershipEvidence(
      originalConfiguration: original,
      currentConfiguration: current.text
    )
  }

  package func authenticatedLegacyOwnershipMatchesCurrentGeneration() throws -> Bool {
    let hasOwnership = FileManager.default.fileExists(atPath: ownershipURL.path)
    let hasBackup = FileManager.default.fileExists(atPath: backupURL.path)
    guard hasOwnership || hasBackup else { return false }
    guard hasOwnership, hasBackup, let state = try readOwnership(), state.before == nil else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence is incomplete or interrupted"
      )
    }
    try verifyBackup(state.backupDigest)
    let expected = try Self.desiredTheme(root: root)
    guard state.desired.matches(expected) else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy adapter evidence does not match the active generation"
      )
    }
    let original = try readBackupText()
    let originalParsed = try Self.parseConfiguration(original)
    guard originalParsed.selection == Self.importedBaseTheme, originalParsed.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict(
        "legacy original is not the authenticated Catppuccin selector boundary"
      )
    }
    return true
  }

  package func discardLegacyOwnershipEvidence() throws {
    for url in [ownershipURL, backupURL] {
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else {
        if errno == ENOENT { continue }
        throw HerdrAdapterError.cannotReadOwnership(url)
      }
      guard metadata.st_mode & S_IFMT == S_IFREG else {
        throw HerdrAdapterError.ownershipConflict(
          "legacy adapter evidence is not a regular file"
        )
      }
      try FileManager.default.removeItem(at: url)
    }
  }

  func verifyTransitionPossible(_ parsed: ParsedConfiguration) throws {
    guard let state = try readOwnership() else {
      guard parsed.custom.isEmpty else {
        throw HerdrAdapterError.ownershipConflict(
          "pre-existing [theme.custom] colors are not Macarchy-managed"
        )
      }
      return
    }

    try verifyBackup(state.backupDigest)
    if let before = state.before {
      guard parsed.surface == before || parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict(
          "interrupted transaction no longer matches its before or desired state"
        )
      }
    } else {
      guard parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
      }
    }
  }

  func verifyCurrentTheme(
    _ desired: GeneratedHerdrTheme,
    parsed: ParsedConfiguration
  ) throws {
    if let state = try readOwnership() {
      guard state.before == nil else {
        throw HerdrAdapterError.ownershipConflict(
          "an interrupted theme transaction must be reconciled"
        )
      }
      guard parsed.surface == state.desired else {
        throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
      }
      try verifyBackup(state.backupDigest)
      guard state.desired.matches(desired) else {
        throw HerdrAdapterError.ownershipConflict(
          "managed values do not match the active generation"
        )
      }
      return
    }

    guard parsed.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict(
        "pre-existing [theme.custom] colors are not Macarchy-managed"
      )
    }
    guard parsed.selection == desired.name else {
      throw HerdrAdapterError.wrongThemeSelection(
        expected: desired.name,
        actual: parsed.selection
      )
    }
    guard desired.custom.isEmpty else {
      throw HerdrAdapterError.ownershipConflict("the active custom palette has not been adopted")
    }
  }

  func transition(to desired: GeneratedHerdrTheme) throws {
    var configuration = try readConfiguration()
    var parsed = try Self.parseConfiguration(configuration.text)
    var state = try readOwnership()

    if let existing = state {
      if let before = existing.before {
        try ensureBackup(existing.backupDigest, currentData: configuration.data)
        if parsed.surface == existing.desired {
          let committed = existing.committed()
          try writeOwnership(committed)
          state = committed
        } else if parsed.surface != before {
          throw HerdrAdapterError.ownershipConflict(
            "interrupted transaction no longer matches its before or desired state"
          )
        }
      } else {
        try verifyBackup(existing.backupDigest)
        guard parsed.surface == existing.desired else {
          throw HerdrAdapterError.ownershipConflict("managed selector or custom colors drifted")
        }
      }
    } else {
      guard parsed.custom.isEmpty else {
        throw HerdrAdapterError.ownershipConflict(
          "pre-existing [theme.custom] colors are not Macarchy-managed"
        )
      }
      if desired.custom.isEmpty {
        let target = ManagedSurface(
          name: desired.name,
          custom: [:]
        )
        guard parsed.surface != target else { return }
        let updated = try Self.replacingManagedSurface(
          in: configuration.text,
          parsed: parsed,
          with: target
        )
        try FileManager.default.createDirectory(
          at: backupURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data(configuration.text.utf8).write(to: backupURL, options: .atomic)
        try writeConfiguration(updated)
        return
      }
    }

    let target = ManagedSurface(
      name: desired.name,
      custom: desired.custom
    )
    if state?.before == nil, parsed.surface == target { return }

    let backupDigest = state?.backupDigest ?? sha256Digest(configuration.data)
    let pending = HerdrOwnershipState(
      before: parsed.surface,
      desired: target,
      backupDigest: backupDigest
    )
    try writeOwnership(pending)
    try faultInjector(.ownershipPrepared)
    try ensureBackup(backupDigest, currentData: configuration.data)

    let updated = try Self.replacingManagedSurface(
      in: configuration.text,
      parsed: parsed,
      with: target
    )
    let verified = try Self.parseConfiguration(updated)
    guard verified.surface == target else {
      throw HerdrAdapterError.invalidThemeConfiguration
    }
    try writeConfiguration(updated)
    try faultInjector(.configurationWritten)
    try writeOwnership(pending.committed())

    configuration = try readConfiguration()
    parsed = try Self.parseConfiguration(configuration.text)
    guard parsed.surface == target else {
      throw HerdrAdapterError.ownershipConflict("the published config does not match ownership")
    }
  }

  private func writeConfiguration(_ configuration: String) throws {
    let target = configurationURL.resolvingSymlinksInPath()
    try Data(configuration.utf8).write(to: target, options: .atomic)
  }

  private func ensureBackup(_ digest: String, currentData: Data) throws {
    if backupMatches(digest) { return }
    guard sha256Digest(currentData) == digest else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
    try FileManager.default.createDirectory(
      at: backupURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try currentData.write(to: backupURL, options: .atomic)
  }

  private func readBackupText() throws -> String {
    let data = try BoundedRegularFile.read(at: backupURL).data
    guard let text = String(data: data, encoding: .utf8) else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
    return text
  }

  private func verifyBackup(_ digest: String) throws {
    guard backupMatches(digest) else {
      throw HerdrAdapterError.backupUnavailable(backupURL)
    }
  }

  private func backupMatches(_ digest: String) -> Bool {
    guard let backup = try? BoundedRegularFile.read(at: backupURL) else { return false }
    return sha256Digest(backup.data) == digest
  }

  private struct HerdrOwnershipState: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let before: ManagedSurface?
    let desired: ManagedSurface
    let backupDigest: String

    init(
      before: ManagedSurface?,
      desired: ManagedSurface,
      backupDigest: String
    ) {
      schemaVersion = Self.currentSchemaVersion
      self.before = before
      self.desired = desired
      self.backupDigest = backupDigest
    }

    func validated() throws -> Self {
      guard schemaVersion == Self.currentSchemaVersion,
        backupDigest.count == 71,
        backupDigest.hasPrefix("sha256:"),
        backupDigest.dropFirst(7).allSatisfy({ $0.isHexDigit && $0.isASCII }),
        desired.name.map(HerdrAdapter.supportedThemes.contains) == true,
        Self.isValidCustom(desired.custom),
        before.map({ Self.isValidCustom($0.custom) }) != false
      else {
        throw HerdrAdapterError.invalidOwnership
      }
      return self
    }

    private static func isValidCustom(_ custom: [String: String]) -> Bool {
      (custom.isEmpty
        || [HerdrAdapter.legacyCustomKeySet, HerdrAdapter.customKeySet].contains(
          Set(custom.keys)))
        && custom.values.allSatisfy({ SRGBColor(rawValue: $0) != nil })
    }

    func committed() -> Self {
      HerdrOwnershipState(
        before: nil,
        desired: desired,
        backupDigest: backupDigest
      )
    }

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case before, desired
      case backupDigest = "backup_digest"
    }
  }

  private func readOwnership() throws -> HerdrOwnershipState? {
    guard FileManager.default.fileExists(atPath: ownershipURL.path) else { return nil }
    do {
      let data = try BoundedRegularFile.read(at: ownershipURL).data
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HerdrAdapterError.invalidOwnership
      }
      let hasBefore = object["before"] != nil
      let expected =
        hasBefore
        ? Set(["schema_version", "before", "desired", "backup_digest"])
        : Set(["schema_version", "desired", "backup_digest"])
      guard Set(object.keys) == expected,
        Self.hasExactSurfaceShape(object["desired"], requiresName: true),
        !hasBefore || Self.hasExactSurfaceShape(object["before"], requiresName: false)
      else {
        throw HerdrAdapterError.invalidOwnership
      }
      return try JSONDecoder().decode(HerdrOwnershipState.self, from: data).validated()
    } catch let error as HerdrAdapterError {
      throw error
    } catch {
      throw HerdrAdapterError.cannotReadOwnership(ownershipURL)
    }
  }

  private static func hasExactSurfaceShape(_ value: Any?, requiresName: Bool) -> Bool {
    guard let surface = value as? [String: Any] else { return false }
    let keys = Set(surface.keys)
    let complete = Set(["name", "custom"])
    return requiresName
      ? keys == complete
      : keys == complete || keys == complete.subtracting(["name"])
  }

  private func writeOwnership(_ state: HerdrOwnershipState) throws {
    let data = try prettyJSONDocument(state)
    try FileManager.default.createDirectory(
      at: ownershipURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: ownershipURL, options: .atomic)
  }
}
