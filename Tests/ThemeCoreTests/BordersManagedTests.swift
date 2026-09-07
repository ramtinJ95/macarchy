import Foundation
import Testing

@testable import ThemeCore

struct BordersManagedTests {
  @Test
  func focusRingDefaultsOnIndependentlyOfWindowManagerAndHasClosedOptOut() throws {
    let loader = PortableProfileLoader()
    let source = URL(filePath: "/fixtures/profile.toml")
    let noWM = try loader.decode(
      "schema_version = 1\n[desktop]\nprovider = \"disabled\"\n", source: source)
    #expect(noWM.environment.focusRing == .borders)
    let optOut = try loader.decode(
      "schema_version = 1\n[focus_ring]\nprovider = \"disabled\"\n", source: source)
    #expect(optOut.environment.focusRing == .disabled)
    #expect(optOut.desktop.provider == .yabaiSkhd)
    #expect(throws: (any Error).self) {
      try loader.decode(
        "schema_version = 1\n[focus_ring]\nprovider = \"custom\"\n", source: source)
    }
  }

  @Test
  func startupArtifactReadsCanonicalStateAndIsSealedExecutable() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Environment")
    let composition = try EnvironmentConfigurationComposer().compose(
      resourcesRoot: resources, profile: .defaults, stateRoot: root)
    let store = EnvironmentGenerationStore(stateRoot: root)
    let staged = try store.stage(composition)
    let artifact = root.appending(
      path:
        "environment/generations/\(staged.manifest.generationID)/\(BordersConfiguration.artifactPath)"
    )
    #expect(try BoundedRegularFile.read(at: artifact).permissions & 0o777 == 0o555)
    let data = try store.validatedArtifact(
      generationID: staged.manifest.generationID, path: BordersConfiguration.artifactPath)
    #expect(String(decoding: data, as: UTF8.self).contains("current/theme.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("#cba6f7"))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: artifact.path)
    #expect(throws: (any Error).self) {
      try store.validatedArtifact(
        generationID: staged.manifest.generationID, path: BordersConfiguration.artifactPath)
    }
  }

  @Test
  func focusRingSelectionLayersThroughTheExistingPortableProfile() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    try Data("schema_version = 1\n[focus_ring]\nprovider = 'disabled'\n".utf8).write(to: portable)
    try Data("schema_version = 1\n[focus_ring]\nprovider = 'borders'\n".utf8).write(to: machine)
    let result = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true, machineAt: machine, machineRequired: true)
    #expect(result.profile.environment.focusRing == .borders)
    #expect(result.fieldOrigins["focus_ring.provider"] == .machine)
  }

  @Test(arguments: ["#cba6f7", "#ABCDE0", "red", "#12zz34", "#123456;touch nope"])
  func startupValidatesColorBeforeAnyNativeRequest(accent: String) throws {
    let root = try temporaryRoot().appending(path: "state 'quoted' $literal")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: root.appending(path: "current"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["semantic": ["accent": accent]])
      .write(to: root.appending(path: "current/theme.json"))
    let script = root.appending(path: "startup.sh")
    // Keep the generated shell parser and quote handling real; replace only the
    // final provider executable so this fixture cannot touch the host singleton.
    let contents = BordersConfiguration.contents(stateRoot: root)
      .replacingOccurrences(
        of: "exec \(BordersService.executableURL.path)", with: "exec /usr/bin/printf '%s\\n'")
    try Data(contents.utf8).write(to: script)
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/sh"), arguments: [script.path], timeout: 2))
    let valid = ["#cba6f7", "#ABCDE0"].contains(accent)
    #expect((result.terminationStatus == 0) == valid)
    if valid {
      #expect(
        result.output.split(whereSeparator: \.isNewline).map(String.init)
          == BordersPalette(generationID: "fixture", themeID: "fixture", accent: accent).arguments)
    } else {
      #expect(!result.output.contains("active_color="))
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "borders-managed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
