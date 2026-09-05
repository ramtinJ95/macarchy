import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentPresetFilesystemTests {
  private static let filesystems = [
    EnvironmentPresetFilesystem(
      configurationLabel: "Pi settings", residueLabel: "Pi transaction residue"),
    EnvironmentPresetFilesystem(
      configurationLabel: "tuicr configuration", residueLabel: "tuicr transaction residue"),
    EnvironmentPresetFilesystem(
      configurationLabel: "Codex configuration", residueLabel: "Codex transaction residue"),
  ]

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
