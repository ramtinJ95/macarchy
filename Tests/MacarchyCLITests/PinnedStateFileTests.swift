import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Regular files in a temporary directory only.
struct PinnedStateFileTests {
  @Test
  func writesSortedPrettyJSONAtOwnerOnlyModeAndRemovesIdempotently() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-pinned-state-file-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let url = root.appending(path: "state.json")

    try PinnedStateFile.write(
      ["b": 2, "a": 1], parentDescriptor: parent, name: "state.json", url: url)
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(text == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)

    let remove = { (syncWhenAbsent: Bool) in
      PinnedStateFile.remove("state.json", parentDescriptor: parent, syncWhenAbsent: syncWhenAbsent)
        .map { $0.code }
    }
    #expect(remove(false) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(remove(false) == nil)
    #expect(remove(true) == nil)
  }
}
