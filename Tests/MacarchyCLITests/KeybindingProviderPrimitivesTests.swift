import Darwin
import Foundation
import Testing

@testable import MacarchyCLI

struct KeybindingProviderPrimitivesTests {
  @Test
  func resolvesRelativeAndAbsoluteSymlinkTextConsistently() {
    let parent = URL(filePath: "/tmp/macarchy/provider")

    #expect(
      KeybindingProviderPrimitives.resolveSymlink("../state/skhdrc", relativeTo: parent).path
        == "/tmp/macarchy/state/skhdrc"
    )
    #expect(
      KeybindingProviderPrimitives.resolveSymlink("/private/tmp/skhdrc", relativeTo: parent).path
        == "/private/tmp/skhdrc"
    )
  }

  @Test
  func markerLifecycleUsesThePinnedSymlinkWithoutFollowingIt() throws {
    let fixture = try markerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    defer {
      Darwin.close(fixture.targetDescriptor)
      Darwin.close(fixture.linkDescriptor)
    }
    let nonce = "01234567-89ab-cdef-0123-456789abcdef"

    try KeybindingProviderPrimitives.createClaimMarker(
      descriptor: fixture.linkDescriptor,
      nonce: nonce
    )

    #expect(try KeybindingProviderPrimitives.claimMarkerExists(descriptor: fixture.linkDescriptor))
    #expect(
      try KeybindingProviderPrimitives.claimMarkerMatches(
        descriptor: fixture.linkDescriptor,
        nonce: nonce
      ))
    #expect(
      try !KeybindingProviderPrimitives.claimMarkerMatches(
        descriptor: fixture.linkDescriptor,
        nonce: "fedcba98-7654-3210-fedc-ba9876543210"
      ))
    #expect(
      try !KeybindingProviderPrimitives.claimMarkerExists(
        descriptor: fixture.targetDescriptor
      ))

    try KeybindingProviderPrimitives.removeClaimMarker(descriptor: fixture.linkDescriptor)
    #expect(try !KeybindingProviderPrimitives.claimMarkerExists(descriptor: fixture.linkDescriptor))
  }

  @Test
  func oversizedForeignMarkerIsDetectedBySizeOnlyProbeAndFailsBoundedRead() throws {
    let fixture = try markerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    defer {
      Darwin.close(fixture.targetDescriptor)
      Darwin.close(fixture.linkDescriptor)
    }
    let oversizedValue = Data(repeating: 0x61, count: 65)
    let result = oversizedValue.withUnsafeBytes { bytes in
      KeybindingProviderPrimitives.claimMarkerAttribute.withCString {
        Darwin.fsetxattr(
          fixture.linkDescriptor,
          $0,
          bytes.baseAddress,
          bytes.count,
          0,
          XATTR_CREATE
        )
      }
    }
    try #require(result == 0)

    #expect(try KeybindingProviderPrimitives.claimMarkerExists(descriptor: fixture.linkDescriptor))
    do {
      _ = try KeybindingProviderPrimitives.claimMarkerMatches(
        descriptor: fixture.linkDescriptor,
        nonce: "01234567-89ab-cdef-0123-456789abcdef"
      )
      Issue.record("expected the bounded marker read to fail")
    } catch let failure as KeybindingProviderPrimitives.POSIXFailure {
      #expect(failure.code == ERANGE)
    }
  }

  private func markerFixture() throws -> (
    root: URL,
    linkDescriptor: Int32,
    targetDescriptor: Int32
  ) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-provider-primitives-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appending(path: "target")
    try Data("fixture\n".utf8).write(to: target)
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target")

    let linkDescriptor = link.path.withCString {
      Darwin.open($0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
    }
    guard linkDescriptor >= 0 else { throw POSIXError(.EIO) }
    let targetDescriptor = target.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard targetDescriptor >= 0 else {
      Darwin.close(linkDescriptor)
      throw POSIXError(.EIO)
    }
    return (root, linkDescriptor, targetDescriptor)
  }
}
