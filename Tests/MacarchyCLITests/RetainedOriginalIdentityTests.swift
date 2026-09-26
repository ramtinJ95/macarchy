import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct RetainedOriginalIdentityTests {
  @Test
  func identityUsesTheContainingVolumeOfADanglingLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "original")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "missing/target")
    var metadata = stat()
    #expect(lstat(link.path, &metadata) == 0)
    let uuid = try RetainedOriginalIdentity.volumeUUID(at: link, matching: metadata)
    #expect(uuid == (try root.resourceValues(forKeys: [.volumeUUIDStringKey])).volumeUUIDString)
    #expect(
      try RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: uuid, device: UInt64(metadata.st_dev) + 2))
    #expect(
      try !RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: UUID().uuidString, device: UInt64(metadata.st_dev)))
    #expect(
      try !RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: nil, device: UInt64(metadata.st_dev) + 2))
    metadata.st_ino += 1
    #expect(throws: (any Error).self) {
      try RetainedOriginalIdentity.volumeUUID(at: link, matching: metadata)
    }
  }
}
