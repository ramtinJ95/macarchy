import CryptoKit
import Foundation
import Testing

@testable import ThemeCore

struct ActivationSliceTests {
  @Test
  func activationCreatesCompleteGenerationAndReplacesCurrentWithRelativeSymlink() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let previousMarker = try installPreviousGeneration(at: root)
    let package = try catppuccinPackage()

    let activation = try ThemeActivator(root: root).activate(package: package)

    let current = root.appending(path: "current")
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
    #expect(destination == "generations/\(activation.generationID)")
    #expect(try String(contentsOf: previousMarker, encoding: .utf8) == "previous\n")

    let generationURL = root.appending(
      path: "generations/\(activation.generationID)", directoryHint: .isDirectory)
    let manifest = try JSONDecoder().decode(
      GenerationManifest.self,
      from: Data(contentsOf: generationURL.appending(path: "manifest.json")))
    #expect(manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion)
    #expect(manifest.generationID == activation.generationID)
    #expect(manifest.themeID == package.id)
    #expect(manifest.themeSchemaVersion == package.schemaVersion)
    #expect(manifest.inputDigest == activation.inputDigest)
    #expect(manifest.rendererVersions == ["kitty": 1, "normalized_theme": 1])
    #expect(manifest.inputDigest.hasPrefix("sha256:"))
    #expect(manifest.inputDigest.count == 71)
    #expect(Set(manifest.artifacts.keys) == ["theme.json", "generated/kitty.conf"])

    for (path, expectedDigest) in manifest.artifacts {
      #expect(expectedDigest == sha256(try Data(contentsOf: generationURL.appending(path: path))))
    }

    let normalizedData = try Data(contentsOf: current.appending(path: "theme.json"))
    let normalized = try JSONDecoder().decode(NormalizedTheme.self, from: normalizedData)
    #expect(normalized.themeID == package.id)
    #expect(normalized.generationID == manifest.generationID)

    for path in ["manifest.json", "theme.json", "generated/kitty.conf"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: generationURL.appending(path: path).path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o222 == 0)
    }
    for path in ["", "generated"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: generationURL.appending(path: path).path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o222 == 0)
    }
  }

  @Test
  func everyPreReplacementFaultPreservesPreviousCanonicalGeneration() throws {
    let package = try catppuccinPackage()
    for checkpoint in ActivationCheckpoint.allCases {
      let root = try temporaryDirectory()
      defer {
        makeWritableForRemoval(root)
        try? FileManager.default.removeItem(at: root)
      }
      let previousMarker = try installPreviousGeneration(at: root)
      let activator = ThemeActivator(root: root) { reached in
        if reached == checkpoint { throw InjectedFault.expected }
      }

      #expect(throws: InjectedFault.self) {
        _ = try activator.activate(package: package)
      }

      let current = root.appending(path: "current")
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
          == "generations/previous")
      #expect(try String(contentsOf: previousMarker, encoding: .utf8) == "previous\n")

      let rootChildren = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      #expect(!rootChildren.contains { $0.lastPathComponent.hasPrefix(".current-") })
      let generationChildren = try FileManager.default.contentsOfDirectory(
        at: root.appending(path: "generations"), includingPropertiesForKeys: nil)
      #expect(!generationChildren.contains { $0.lastPathComponent.hasPrefix(".staging-") })
    }
  }

  @Test
  func inputDigestUsesValidatedContentRatherThanSourceFormatting() throws {
    let fixtureRoot = try temporaryDirectory()
    defer {
      makeWritableForRemoval(fixtureRoot)
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    let source = repositoryRoot.appending(
      path: "Themes/catppuccin-mocha", directoryHint: .isDirectory)
    let equivalentURL = fixtureRoot.appending(path: "equivalent", directoryHint: .isDirectory)
    let changedURL = fixtureRoot.appending(path: "changed", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: equivalentURL)
    try FileManager.default.copyItem(at: source, to: changedURL)

    for file in ["theme.toml", "mappings.toml"] {
      let url = equivalentURL.appending(path: file)
      let original = try String(contentsOf: url, encoding: .utf8)
      try ("# Equivalent source comment\n" + original).write(
        to: url, atomically: true, encoding: .utf8)
    }
    let changedMappings = changedURL.appending(path: "mappings.toml")
    let originalMappings = try String(contentsOf: changedMappings, encoding: .utf8)
    try originalMappings.replacingOccurrences(
      of: "neovim = \"catppuccin-mocha\"", with: "neovim = \"catppuccin-mocha-updated\""
    ).write(to: changedMappings, atomically: true, encoding: .utf8)

    let originalManifest = try activate(try catppuccinPackage())
    let equivalentManifest = try activate(
      ThemePackageLoader().load(packageURL: equivalentURL)
    )
    let changedManifest = try activate(
      ThemePackageLoader().load(packageURL: changedURL)
    )

    #expect(originalManifest.inputDigest == equivalentManifest.inputDigest)
    #expect(originalManifest.inputDigest != changedManifest.inputDigest)
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func catppuccinPackage() throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha", directoryHint: .isDirectory))
  }

  private func activate(_ package: ThemePackage) throws -> GenerationManifest {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    return try ThemeActivator(root: root).activate(package: package)
  }

  private func installPreviousGeneration(at root: URL) throws -> URL {
    let previous = root.appending(path: "generations/previous", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    let marker = previous.appending(path: "marker.txt")
    try "previous\n".write(to: marker, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "current").path,
      withDestinationPath: "generations/previous"
    )
    return marker
  }

  private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(
        path: "macarchy-activation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeWritableForRemoval(_ root: URL) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      }
    }
    for directory in directories.reversed() {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }

  private enum InjectedFault: Error {
    case expected
  }
}
