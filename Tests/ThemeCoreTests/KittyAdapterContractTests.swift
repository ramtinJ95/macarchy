import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func kittyRejectsInvalidBridgeFilesAndRebuildsSymlinks() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let includeDirective = "include \(root.path)/state/adapters/kitty.conf"
    let configurationSourceURL = root.appending(path: "kitty-source.conf")
    let configurationURL = root.appending(path: "kitty.conf")
    try "\(includeDirective)\n".write(
      to: configurationSourceURL,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: configurationURL,
      withDestinationURL: configurationSourceURL
    )
    let bridgeURL = root.appending(path: KittyAdapter.bridgePath)
    try FileManager.default.createDirectory(
      at: bridgeURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let generatedURL = root.appending(
      path: "generations/\(manifest.generationID)/generated/kitty.conf"
    )
    try FileManager.default.createSymbolicLink(
      at: bridgeURL,
      withDestinationURL: generatedURL
    )
    let adapter = KittyAdapter(
      root: root,
      configurationURL: configurationURL,
      includeDirective: includeDirective,
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "no matching process")
      }
    )

    #expect(adapter.inspection().status == .failed)
    #expect(try await adapter.reconciliation().run().status == .applied)
    let values = try bridgeURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    #expect(values.isRegularFile == true)
    #expect(values.isSymbolicLink != true)
    #expect(adapter.inspection().status == .ready)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: bridgeURL.path
    )
    #expect(adapter.inspection().status == .failed)
  }

}
