import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingProviderInspectionTests {
  private let inspector = KeybindingProviderInspector()

  @Test
  func legacyFallbackRequiresReviewedAdoptionWhenPreferredEntryIsAbsent() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    let fallback = fixture.home.appending(path: ".skhdrc")
    try "alt - j : fallback command\n".write(
      to: fallback,
      atomically: true,
      encoding: .utf8
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .adoptionRequired)
    #expect(inspection.ownership == "legacy_fallback")
    #expect(inspection.source == fallback.path)
    #expect(inspection.sourceConfiguration == "alt - j : fallback command\n")
    #expect(inspection.adoptionEvidenceDigest != nil)
  }

  @Test
  func unsupportedLegacyFallbackBlocksRatherThanBecomingACleanInstall() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: ".skhdrc"),
      withIntermediateDirectories: true
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "legacy_fallback_conflict")
  }

  @Test
  func directorySymlinkWithOnlySkhdrcIsEligibleForAdoption() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "alt - j : default\n".write(
      to: fixture.dotfiles.appending(path: "skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .adoptionRequired)
    #expect(inspection.ownership == "directory_symlink")
    #expect(inspection.source == fixture.dotfiles.appending(path: "skhdrc").path)
  }

  @Test
  func directorySymlinkWithUnknownSiblingBlocksAdoption() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for file in ["skhdrc", "partial.skhdrc"] {
      try "# fixture\n".write(
        to: fixture.dotfiles.appending(path: file),
        atomically: true,
        encoding: .utf8
      )
    }
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.message.contains("partial.skhdrc"))
  }

  @Test
  func matchingEntryLinkWithoutReadableGenerationBlocksAdoptionPreview() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.skhdDirectory.appending(path: "skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "matching_unclaimed_unreadable")
  }

  @Test
  func matchingEntryLinkWithExactManifestClaimIsManaged() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    let entry = fixture.skhdDirectory.appending(path: "skhdrc")
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let stateRoot = fixture.home.appending(
      path: ".config/macarchy",
      directoryHint: .isDirectory
    )
    try writeOwnershipClaim(stateRoot: stateRoot, entry: entry)
    try markClaim(entry)

    let inspection = inspect(fixture)

    #expect(inspection.status == .managed)
    #expect(inspection.ownership == "manifest_claimed_symlink")
  }

  @Test
  func matchingClaimedLinkWithoutOwnershipMarkerIsDrift() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory, withIntermediateDirectories: true)
    let entry = fixture.skhdDirectory.appending(path: "skhdrc")
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    try writeOwnershipClaim(
      stateRoot: fixture.home.appending(path: ".config/macarchy"),
      entry: entry
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "ownership_drift")
  }

  @Test
  func claimedMissingEntryIsOwnershipDrift() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let entry = fixture.skhdDirectory.appending(path: "skhdrc")
    let stateRoot = fixture.home.appending(
      path: ".config/macarchy",
      directoryHint: .isDirectory
    )
    try writeOwnershipClaim(stateRoot: stateRoot, entry: entry)

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "ownership_drift")
  }

  @Test
  func invalidSiblingOwnershipRecordBlocksManagedClassification() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    let entry = fixture.skhdDirectory.appending(path: "skhdrc")
    try FileManager.default.createSymbolicLink(
      atPath: entry.path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )
    let stateRoot = fixture.home.appending(
      path: ".config/macarchy",
      directoryHint: .isDirectory
    )
    let unknown = SetupOwnershipRecord(
      id: "unknown.integration",
      phase: .applied,
      kind: .symbolicLink,
      targetPath: fixture.home.appending(path: ".config/unknown").path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data("target".utf8)),
      linkDestination: "target"
    )
    try writeOwnershipClaim(stateRoot: stateRoot, entry: entry, additionalRecords: [unknown])

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "invalid_ownership_evidence")
  }

  @Test
  func symlinkedConfigurationAncestorBlocksInspection() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = fixture.home.appending(path: ".config", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: configuration)
    let external = fixture.root.appending(path: "external-config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: configuration, withDestinationURL: external)

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "unsafe_ancestor")
  }

  @Test
  func danglingDirectoryLevelEntrySymlinkBlocksAdoption() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createSymbolicLink(
      atPath: fixture.dotfiles.appending(path: "skhdrc").path,
      withDestinationPath: "missing.skhdrc"
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.message.contains("not a bounded regular file"))
  }

  @Test
  func directoryLevelInventoryRejectsAnSkhdrcSymlinkEvenWhenItsTargetExists() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let external = fixture.root.appending(path: "external.skhdrc")
    try "alt - j : external\n".write(to: external, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: fixture.dotfiles.appending(path: "skhdrc"),
      withDestinationURL: external
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspect(fixture)

    #expect(inspection.status == .blocked)
    #expect(inspection.message.contains("not a bounded regular file"))
  }

  @Test
  func selectedStateRootMustMatchTheExistingProviderLink() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.skhdDirectory.appending(path: "skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )

    let inspection = inspector.inspect(
      homeDirectory: fixture.home,
      stateRoot: fixture.root.appending(path: "other-state", directoryHint: .isDirectory),
      generation: .missing
    )

    #expect(inspection.status == .blocked)
    #expect(inspection.ownership == "state_root_mismatch")
  }

  private func inspect(
    _ fixture: (root: URL, home: URL, dotfiles: URL, skhdDirectory: URL)
  ) -> KeybindingProviderInspection {
    inspector.inspect(
      homeDirectory: fixture.home,
      stateRoot: fixture.home.appending(path: ".config/macarchy", directoryHint: .isDirectory),
      generation: .missing
    )
  }

  private func writeOwnershipClaim(
    stateRoot: URL,
    entry: URL,
    additionalRecords: [SetupOwnershipRecord] = []
  ) throws {
    let setup = stateRoot.appending(path: "state/setup", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
    let target = KeybindingProviderInspector.managedTarget
    let record = SetupOwnershipRecord(
      id: KeybindingProviderInspector.ownershipID,
      phase: .applied,
      kind: .symbolicLink,
      targetPath: entry.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(target.utf8)),
      linkDestination: target,
      originalKind: .absent,
      claimNonce: "01234567-89ab-cdef-0123-456789abcdef"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(SetupOwnershipManifest(records: [record] + additionalRecords)).write(
      to: setup.appending(path: "ownership.json")
    )
  }

  private func markClaim(_ entry: URL) throws {
    let descriptor = entry.path.withCString { Darwin.open($0, O_RDONLY | O_SYMLINK | O_CLOEXEC) }
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }
    let value = Data("01234567-89ab-cdef-0123-456789abcdef".utf8)
    let result = value.withUnsafeBytes { bytes in
      KeybindingProviderInspector.claimMarkerAttribute.withCString {
        Darwin.fsetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, XATTR_CREATE)
      }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
  }

  private func fixtureHome() throws -> (
    root: URL,
    home: URL,
    dotfiles: URL,
    skhdDirectory: URL
  ) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-provider-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let configuration = home.appending(path: ".config", directoryHint: .isDirectory)
    let dotfiles = root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    return (
      root,
      home,
      dotfiles,
      configuration.appending(path: "skhd", directoryHint: .isDirectory)
    )
  }
}
