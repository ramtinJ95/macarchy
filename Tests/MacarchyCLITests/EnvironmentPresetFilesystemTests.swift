import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentPresetFilesystemTests {
  private static let filesystems = [
    EnvironmentPresetFilesystem(
      configurationLabel: "Pi settings", residueLabel: "Pi transaction residue",
      nonRegularMessage: "Pi settings are not an ordinary file"),
    EnvironmentPresetFilesystem(
      configurationLabel: "tuicr configuration", residueLabel: "tuicr transaction residue",
      nonRegularMessage: "tuicr configuration is not an ordinary file"),
    EnvironmentPresetFilesystem(
      configurationLabel: "Codex configuration", residueLabel: "Codex transaction residue",
      nonRegularMessage: "Codex configuration is not an ordinary file"),
  ]

  @Test(arguments: filesystems)
  func readsRejectLinkedAndOversizedFiles(_ filesystem: EnvironmentPresetFilesystem) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try filesystem.read(fixture.target) == nil)
    try fixture.bytes.write(to: fixture.target)
    #expect(try filesystem.read(fixture.target) == fixture.bytes)
    try FileManager.default.linkItem(at: fixture.target, to: fixture.residue)
    do {
      _ = try filesystem.read(fixture.target)
      Issue.record("multiply linked configuration must be rejected")
    } catch let error as EnvironmentLifecycleError {
      #expect(
        error.description
          == EnvironmentLifecycleError.blocked(
            "\(filesystem.nonRegularMessage): \(fixture.target.path)"
          ).description)
    }
    try FileManager.default.removeItem(at: fixture.residue)
    try FileManager.default.createSymbolicLink(
      at: fixture.residue, withDestinationURL: fixture.target)
    #expect(throws: EnvironmentLifecycleError.self) { _ = try filesystem.read(fixture.residue) }
    try Data(count: BoundedRegularFile.maximumSize + 1).write(to: fixture.target)
    #expect(throws: BoundedRegularFileError.tooLarge(BoundedRegularFile.maximumSize)) {
      _ = try filesystem.read(fixture.target)
    }
    #expect(throws: EnvironmentLifecycleError.self) {
      _ = try filesystem.utf8(Data([0xff]), at: fixture.target)
    }
  }

  @Test(arguments: filesystems)
  func replacementPreservesNoOpIdentityAndAuthenticatesClaimedBytes(
    _ filesystem: EnvironmentPresetFilesystem
  ) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try filesystem.create(
      fixture.bytes, at: fixture.target, replacementName: fixture.replacementName)
    var original = stat()
    try #require(lstat(fixture.target.path, &original) == 0)
    try filesystem.replace(
      fixture.bytes, current: fixture.bytes, at: fixture.target,
      replacementName: fixture.replacementName, homeDirectory: fixture.root, label: "test selector")
    var unchanged = stat()
    try #require(lstat(fixture.target.path, &unchanged) == 0)
    #expect(unchanged.st_ino == original.st_ino)

    let replacement = Data("updated\n".utf8)
    try filesystem.replace(
      replacement, current: fixture.bytes, at: fixture.target,
      replacementName: fixture.replacementName, homeDirectory: fixture.root, label: "test selector")
    #expect(try filesystem.read(fixture.target) == replacement)
    #expect(throws: EnvironmentLifecycleError.self) {
      try filesystem.claimAndRemove(
        at: fixture.target, replacementName: fixture.replacementName, expected: fixture.bytes)
    }
    #expect(try filesystem.read(fixture.target) == nil)
    #expect(try filesystem.read(fixture.residue) == replacement)
    try FileManager.default.moveItem(at: fixture.residue, to: fixture.target)
    try filesystem.claimAndRemove(
      at: fixture.target, replacementName: fixture.replacementName, expected: replacement)
    #expect(try filesystem.read(fixture.residue) == nil)
  }

  @Test(arguments: filesystems)
  func publishesPrivateBytesAndValidatesBeforeRemoval(_ filesystem: EnvironmentPresetFilesystem)
    throws
  {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try filesystem.create(
      fixture.bytes, at: fixture.target, replacementName: fixture.replacementName)
    #expect(try Data(contentsOf: fixture.target) == fixture.bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
    var metadata = stat()
    try #require(lstat(fixture.target.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o777 == 0o600)

    var validated = false
    try filesystem.claimAndRemove(at: fixture.target, replacementName: fixture.replacementName) {
      residue in
      #expect(residue == fixture.residue)
      #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
      #expect(try Data(contentsOf: residue) == fixture.bytes)
      var claimed = stat()
      try #require(lstat(residue.path, &claimed) == 0)
      #expect(claimed.st_ino == metadata.st_ino)
      validated = true
    }
    #expect(validated)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
    try filesystem.remove(fixture.residue)
  }

  @Test(arguments: filesystems)
  func failedPublicationPreservesDestinationAndCleansTemporary(
    _ filesystem: EnvironmentPresetFilesystem
  ) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.bytes.write(to: fixture.target)
    do {
      try filesystem.create(
        Data("replacement".utf8), at: fixture.target, replacementName: fixture.replacementName)
      Issue.record("publication must not replace an existing destination")
    } catch let error as EnvironmentLifecycleError {
      #expect(
        error.description
          == EnvironmentLifecycleError.system(
            "publish \(filesystem.configurationLabel)", fixture.target, EEXIST
          ).description)
    }
    #expect(try Data(contentsOf: fixture.target) == fixture.bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test(arguments: filesystems)
  func failedTemporaryCreationPreservesExistingResidue(_ filesystem: EnvironmentPresetFilesystem)
    throws
  {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.bytes.write(to: fixture.residue)
    do {
      try filesystem.create(
        Data("replacement".utf8), at: fixture.target, replacementName: fixture.replacementName)
      Issue.record("temporary creation must not replace or remove existing residue")
    } catch let error as PinnedFilesystemError {
      #expect(error.operation == "create pinned regular file")
      #expect(error.url == fixture.residue)
      #expect(error.code == EEXIST)
    }
    #expect(try Data(contentsOf: fixture.residue) == fixture.bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
  }

  @Test(arguments: filesystems)
  func failedClaimPreservesBothFilesAndDoesNotValidate(_ filesystem: EnvironmentPresetFilesystem)
    throws
  {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.bytes.write(to: fixture.target)
    let residueBytes = Data("earlier residue".utf8)
    try residueBytes.write(to: fixture.residue)
    do {
      try filesystem.claimAndRemove(at: fixture.target, replacementName: fixture.replacementName) {
        _ in Issue.record("a failed claim must not validate")
      }
      Issue.record("claim must not replace existing residue")
    } catch let error as EnvironmentLifecycleError {
      #expect(
        error.description
          == EnvironmentLifecycleError.system(
            "claim \(filesystem.configurationLabel)", fixture.target, EEXIST
          ).description)
    }
    #expect(try Data(contentsOf: fixture.target) == fixture.bytes)
    #expect(try Data(contentsOf: fixture.residue) == residueBytes)
  }

  @Test(arguments: filesystems)
  func failedValidationRetainsClaimAndPropagatesProviderError(
    _ filesystem: EnvironmentPresetFilesystem
  ) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.bytes.write(to: fixture.target)
    do {
      try filesystem.claimAndRemove(at: fixture.target, replacementName: fixture.replacementName) {
        residue in
        #expect(residue == fixture.residue)
        #expect(try Data(contentsOf: residue) == fixture.bytes)
        throw EnvironmentLifecycleError.drift("provider validation")
      }
      Issue.record("validation failure must propagate")
    } catch let error as EnvironmentLifecycleError {
      #expect(error.description == "environment ownership drifted: provider validation")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    #expect(try Data(contentsOf: fixture.residue) == fixture.bytes)
    try filesystem.remove(fixture.residue)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test(arguments: filesystems)
  func removalFailureUsesTheResidueLabel(_ filesystem: EnvironmentPresetFilesystem) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(at: fixture.residue, withIntermediateDirectories: false)
    do {
      try filesystem.remove(fixture.residue)
      Issue.record("unlink must not remove a directory")
    } catch let error as EnvironmentLifecycleError {
      #expect(
        error.description
          == EnvironmentLifecycleError.system(
            "remove \(filesystem.residueLabel)", fixture.residue, EPERM
          ).description)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  private struct Fixture {
    let root: URL
    let replacementName = ".macarchy-preset-test.replacement"
    let bytes = Data("original\n".utf8)
    var target: URL { root.appending(path: "configuration") }
    var residue: URL { root.appending(path: replacementName) }

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-preset-filesystem-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
  }
}
