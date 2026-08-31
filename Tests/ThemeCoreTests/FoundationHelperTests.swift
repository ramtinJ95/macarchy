import Darwin
import Foundation
import Testing

@testable import ThemeCore

struct FoundationHelperTests {
  @Test
  func pinnedFilesystemOpensOrCreatesOnlyTheRequestedChildDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-foundation-helper-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let childURL = root.appending(path: "child", directoryHint: .isDirectory)
    let created = try {
      let previousUmask = Darwin.umask(0)
      defer { Darwin.umask(previousUmask) }
      return try PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: parent,
        name: "child",
        url: childURL,
        mode: 0o700
      )
    }()
    defer { Darwin.close(created) }
    var createdMetadata = stat()
    #expect(fstat(created, &createdMetadata) == 0)
    #expect(createdMetadata.st_mode & 0o777 == 0o700)

    let reopened = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: parent,
      name: "child",
      url: childURL,
      mode: 0o755
    )
    defer { Darwin.close(reopened) }
    var reopenedMetadata = stat()
    #expect(fstat(reopened, &reopenedMetadata) == 0)
    #expect(createdMetadata.st_dev == reopenedMetadata.st_dev)
    #expect(createdMetadata.st_ino == reopenedMetadata.st_ino)

    let aliasURL = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: childURL)
    do {
      _ = try PinnedFilesystem.openOrCreateChildDirectory(
        parentDescriptor: parent,
        name: "alias",
        url: aliasURL
      )
      Issue.record("expected the no-follow open failure to propagate")
    } catch let error as PinnedFilesystemError {
      #expect(error.operation == "open pinned directory")
    }
  }

  @Test
  func adapterConfigurationReadsMapOnlySizeAndUnreadableFailures() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-adapter-file-helper-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = root.appending(path: "configuration")

    try Data("fixture\n".utf8).write(to: configuration)
    #expect(
      try AdapterConfigurationFile.readUTF8(
        at: configuration,
        tooLarge: AdapterReadError.tooLarge,
        unreadable: AdapterReadError.unreadable
      ) == "fixture\n"
    )

    try Data([0xff]).write(to: configuration)
    #expect(throws: AdapterReadError.unreadable) {
      try AdapterConfigurationFile.readUTF8(
        at: configuration,
        tooLarge: AdapterReadError.tooLarge,
        unreadable: AdapterReadError.unreadable
      )
    }

    try Data(count: BoundedRegularFile.maximumSize + 1).write(to: configuration)
    #expect(throws: AdapterReadError.tooLarge) {
      try AdapterConfigurationFile.readUTF8(
        at: configuration,
        tooLarge: AdapterReadError.tooLarge,
        unreadable: AdapterReadError.unreadable
      )
    }
  }
}

private enum AdapterReadError: Error, Equatable {
  case tooLarge
  case unreadable
}
