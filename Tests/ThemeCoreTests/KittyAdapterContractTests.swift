import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func kittyFirstConnectionBridgePreparationIsAbsentOnlyAndDoesNotReload() async throws {
    try await withTemporaryRoot(named: "macarchy-kitty-connection-tests") { root in
      let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
      let bridge = root.appending(path: KittyAdapter.bridgePath)
      let generated = root.appending(
        path: "generations/\(manifest.generationID)/generated/kitty.conf")
      try KittyAdapter.prepareBridge(root: root)
      #expect(try Data(contentsOf: bridge) == Data(contentsOf: generated))
      let before = try bridge.resourceValues(forKeys: [.fileResourceIdentifierKey])
      try KittyAdapter.prepareBridge(root: root)
      let after = try bridge.resourceValues(forKeys: [.fileResourceIdentifierKey])
      #expect(
        String(describing: before.fileResourceIdentifier)
          == String(describing: after.fileResourceIdentifier))
      let personal = Data("foreign bridge\n".utf8)
      try personal.write(to: bridge)
      #expect(throws: (any Error).self) { try KittyAdapter.prepareBridge(root: root) }
      #expect(try Data(contentsOf: bridge) == personal)
      try FileManager.default.removeItem(at: bridge)
      try FileManager.default.createSymbolicLink(
        at: bridge, withDestinationURL: root.appending(path: "missing"))
      #expect(throws: (any Error).self) { try KittyAdapter.prepareBridge(root: root) }
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: bridge.path)
          == root.appending(path: "missing").path)
    }
  }

  @Test
  func kittyRejectsInvalidBridgeFilesAndRebuildsSymlinks() async throws {
    try await withTemporaryRoot(named: "macarchy-adapter-tests") { root in
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

      try Data([0xff]).write(to: configurationSourceURL)
      #expect(
        adapter.inspection().message
          == "Cannot read Kitty configuration at \(configurationURL.path)"
      )
      try Data(count: BoundedRegularFile.maximumSize + 1).write(to: configurationSourceURL)
      let oversized = adapter.inspection()
      #expect(oversized.status == .failed)
      #expect(
        oversized.message
          == "Kitty configuration at \(configurationURL.path) exceeds 1 MiB"
      )
    }
  }

}
