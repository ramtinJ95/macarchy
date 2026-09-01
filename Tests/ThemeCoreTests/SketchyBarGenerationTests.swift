import Foundation
import Testing

@testable import ThemeCore

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

  private func installGeneration(
    _ composition: SketchyBarComposition,
    root: URL
  ) throws -> (generationID: String, entry: URL) {
    let generationID = "s-\(UUID().uuidString.lowercased())"
    let provider = root.appending(path: "desktop/sketchybar", directoryHint: .isDirectory)
    let generation = provider.appending(
      path: "generations/\(generationID)",
      directoryHint: .isDirectory
    )
    let plugins = generation.appending(path: "plugins", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    for artifact in composition.artifacts {
      let file = generation.appending(path: artifact.path)
      try Data(artifact.contents.utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.path)
    }
    let manifest = SketchyBarGenerationManifest(
      generationID: generationID,
      composition: composition
    )
    let manifestURL = generation.appending(path: "manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    for directory in [plugins, generation] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555],
        ofItemAtPath: directory.path
      )
    }
    try FileManager.default.createSymbolicLink(
      atPath: provider.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
    return (generationID, generation.appending(path: "sketchybarrc"))
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
