import Darwin
import Foundation
import Testing

@testable import ThemeCore

struct BoundedRegularFileTests {
  @Test
  func subMebibyteLimitsUseExactDiagnosticUnits() {
    #expect(
      BoundedRegularFileError.tooLarge(65_536).description
        == "exceeds the 64 KiB file limit"
    )
  }

  @Test
  func fifoInputsFailAsNonregularWithoutBlocking() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-bounded-file-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appending(path: "input.fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)

    #expect(throws: BoundedRegularFileError.self) {
      _ = try BoundedRegularFile.read(at: fifo)
    }

    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    #expect(throws: BoundedRegularFileError.self) {
      _ = try PinnedFilesystem.readRegularFile(
        parentDescriptor: parent,
        name: fifo.lastPathComponent,
        url: fifo
      )
    }
  }
}
