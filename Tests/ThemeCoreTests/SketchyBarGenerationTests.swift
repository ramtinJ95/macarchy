import Foundation
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct SketchyBarGenerationTests {
  @Test
  func validatesASelectedSealedGeneration() throws {
    try withTemporaryRoot(named: "macarchy-sketchybar-generation-tests") { root in
      let composition = try composition(root: root)
      let installed = try installGeneration(composition, root: root)

      let inspection = SketchyBarGenerationInspector(stateRoot: root).inspect()

      #expect(inspection.status == .current)
      #expect(inspection.generationID == installed.generationID)
      #expect(inspection.manifest?.inputDigest == composition.inputDigest)
      #expect(inspection.manifest?.renderedDigest == composition.renderedDigest)
    }
  }

  @Test
  func artifactDriftInvalidatesTheSelectedGeneration() throws {
    try withTemporaryRoot(named: "macarchy-sketchybar-generation-tests") { root in
      let installed = try installGeneration(try composition(root: root), root: root)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: installed.entry.path
      )
      try Data("drift\n".utf8).write(to: installed.entry)

      #expect(SketchyBarGenerationInspector(stateRoot: root).inspect().status == .invalid)
    }
  }

  @Test
  func sealsAndAuthenticatesTheCopiedTrustedHook() throws {
    try withTemporaryRoot(named: "macarchy-sketchybar-generation-tests") { root in
      let hook = root.appending(path: "hook.sh")
      try "\"$SKETCHYBAR\" --add item personal.demo center\n".write(
        to: hook,
        atomically: true,
        encoding: .utf8
      )
      let profile = try PortableProfileLoader().decode(
        """
        schema_version = 1
        [sketchybar]
        right = ["volume", "clock"]
        hook = "hook.sh"
        """,
        source: root.appending(path: "profile.toml")
      )
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
      let installed = try installGeneration(composition, root: root)
      let copied = root.appending(
        path: "desktop/sketchybar/generations/\(installed.generationID)/plugins/user-hook.sh"
      )

      #expect(try String(contentsOf: copied, encoding: .utf8).contains("personal.demo"))
      #expect(
        FileManager.default.fileExists(
          atPath: copied.deletingLastPathComponent().appending(path: "volume.sh").path
        )
      )
      #expect(SketchyBarGenerationInspector(stateRoot: root).inspect().status == .current)

      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied.path)
      try Data("drift\n".utf8).write(to: copied)
      #expect(SketchyBarGenerationInspector(stateRoot: root).inspect().status == .invalid)
    }
  }

  @Test
  func publicationSetsExactModesUnderARestrictiveUmask() throws {
    try withTemporaryRoot(named: "macarchy-sketchybar-generation-tests") { root in
      let previousUmask = Darwin.umask(0o077)
      defer { Darwin.umask(previousUmask) }

      _ = try installGeneration(try composition(root: root), root: root)

      #expect(SketchyBarGenerationInspector(stateRoot: root).inspect().status == .current)
    }
  }

  @Test
  func transactionResidueRemovalHandlesBoundedPartialStaging() throws {
    try withTemporaryRoot(named: "macarchy-sketchybar-generation-tests") { root in
      let generationID = "s-\(UUID().uuidString.lowercased())"
      let staging = root.appending(
        path: "desktop/sketchybar/generations/.staging-\(generationID)",
        directoryHint: .isDirectory
      )
      let plugins = staging.appending(path: "plugins", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
      try Data("#!/bin/sh\n".utf8).write(to: plugins.appending(path: "clock.sh"))

      try SketchyBarGenerationActivator(stateRoot: root).removeTransactionResidue(generationID)

      #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
  }

  private func installGeneration(
    _ composition: SketchyBarComposition,
    root: URL
  ) throws -> (generationID: String, entry: URL) {
    let generationID = "s-\(UUID().uuidString.lowercased())"
    let activator = SketchyBarGenerationActivator(stateRoot: root)
    try activator.publish(composition, generationID: generationID)
    try activator.select(generationID)
    return (
      generationID,
      root.appending(path: "desktop/sketchybar/generations/\(generationID)/sketchybarrc")
    )
  }

  private func composition(root: URL) throws -> SketchyBarComposition {
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    return try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )
  }

  private var defaultsURL: URL {
    repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml")
  }
}
