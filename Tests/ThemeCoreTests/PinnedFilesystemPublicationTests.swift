import Darwin
import Foundation
import Testing

@testable import ThemeCore

/// Regular files in a temporary directory only.
struct PinnedFilesystemPublicationTests {
  @Test
  func renameExclusivelyNeverReplacesAnExistingEntry() throws {
    try withDirectory { root, parent in
      try Data("source".utf8).write(to: root.appending(path: "source"))
      try Data("existing".utf8).write(to: root.appending(path: "existing"))

      let replaced = PinnedFilesystem.renameExclusively("source", to: "existing", in: parent)
      let code = errno
      #expect(!replaced)
      #expect(code == EEXIST)
      #expect(try Data(contentsOf: root.appending(path: "existing")) == Data("existing".utf8))

      #expect(PinnedFilesystem.renameExclusively("source", to: "moved", in: parent))
      #expect(try Data(contentsOf: root.appending(path: "moved")) == Data("source".utf8))
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: "source").path))
    }
  }

  @Test
  func publishNewRegularFilePublishesWithModeAndReportsTheFailedStep() throws {
    try withDirectory { root, parent in
      let url = root.appending(path: "published")
      try PinnedFilesystem.publishNewRegularFile(
        Data("first".utf8), as: "published", through: ".first", parentDescriptor: parent,
        url: url, mode: 0o600)
      #expect(try Data(contentsOf: url) == Data("first".utf8))
      let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      #expect(mode as? Int == 0o600)
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".first").path))

      do {
        try PinnedFilesystem.publishNewRegularFile(
          Data("second".utf8), as: "published", through: ".second", parentDescriptor: parent,
          url: url, mode: 0o600)
        Issue.record("publication replaced an existing file")
      } catch let failure as PinnedFilesystem.PublicationError {
        #expect(failure.step == .publish)
        #expect(failure.code == EEXIST)
      }
      #expect(try Data(contentsOf: url) == Data("first".utf8))
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".second").path))

      #expect(throws: PinnedFilesystem.PublicationError.self) {
        try PinnedFilesystem.publishNewRegularFile(
          Data("kept".utf8), as: "published", through: ".kept", parentDescriptor: parent,
          url: url, mode: 0o600, keepsTemporaryOnFailure: true)
      }
      #expect(try Data(contentsOf: root.appending(path: ".kept")) == Data("kept".utf8))
    }
  }

  private func withDirectory(_ body: (URL, Int32) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-pinned-publication-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    try body(root, parent)
  }
}
