import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarConfigurationTests {
  @Test
  func composesDeterministicSpaceAwareCoreWithoutOptionalDependencies() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )
    let composer = SketchyBarConfigurationComposer()

    let first = try composer.compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )
    let second = try composer.compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )

    #expect(first == second)
    #expect(first.spaceModule == SketchyBarSpaceModule.dynamicYabai)
    #expect(
      first.artifacts.map { $0.path }
        == ["sketchybarrc", "plugins/clock.sh", "plugins/space-indexes.sh"]
    )
    let entry = try #require(first.artifacts.first { $0.path == "sketchybarrc" })
    #expect(entry.contents.contains("SPACE_INDICES="))
    #expect(entry.contents.contains("--add space \"$item\" left"))
    #expect(entry.contents.contains("macarchy.theme.ready"))
    #expect(!entry.contents.contains("Spaces unavailable"))
    #expect(
      entry.contents.contains(
        "PLUGIN_DIR='\(root.path)/desktop/sketchybar/current/plugins'"
      )
    )
    try requireValidShellSyntax(first.artifacts, root: root)
    try requireDateAccepts(first.settings.clockFormat)
  }

  @Test
  func disabledDesktopKeepsTheBarAndMakesSpacesVisiblyUnavailable() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [desktop]
      provider = "disabled"
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )

    #expect(composition.spaceModule == SketchyBarSpaceModule.disabledWithoutDesktop)
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
    #expect(entry.contents.contains("macarchy.spaces.unavailable"))
    #expect(entry.contents.contains("label=\"Spaces unavailable\""))
    #expect(!entry.contents.contains("SPACE_INDICES="))
    #expect(entry.contents.contains("macarchy.clock"))
  }

  @Test
  func profileControlsModuleVisibilityPositionOrderAndOptionalVolume() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [sketchybar]
      left = ["clock", "spaces"]
      right = ["volume"]
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )
    let defaultComposition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: .defaults,
      stateRoot: root
    )
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })

    #expect(composition.layout.left == [.clock, .spaces])
    #expect(composition.layout.center.isEmpty)
    #expect(composition.layout.right == [.volume])
    let clock = try #require(entry.contents.range(of: "--add item macarchy.clock left"))
    let spaces = try #require(entry.contents.range(of: "--add space \"$item\" left"))
    #expect(clock.lowerBound < spaces.lowerBound)
    #expect(entry.contents.contains("--add item macarchy.volume right"))
    #expect(
      entry.contents.contains(
        "--subscribe macarchy.volume volume_change system_woke"
      )
    )
    let volume = try #require(
      composition.artifacts.first { $0.path == "plugins/volume.sh" }
    )
    #expect(volume.contents.contains("/usr/bin/osascript"))
    #expect(defaultComposition.artifacts.allSatisfy { $0.path != "plugins/volume.sh" })
    #expect(composition.inputDigest != defaultComposition.inputDigest)
    #expect(composition.renderedDigest != defaultComposition.renderedDigest)
    try requireValidShellSyntax(composition.artifacts, root: root)
  }

  @Test
  func hidingSpacesRemovesTheYabaiDependencyFromTheRenderedEntry() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [sketchybar]
      left = []
      """,
      source: root.appending(path: "profile.toml")
    )

    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })

    #expect(composition.spaceModule == .hidden)
    #expect(!entry.contents.contains("SPACE_INDICES="))
    #expect(!entry.contents.contains("Spaces unavailable"))
    #expect(entry.contents.contains("--add item macarchy.clock right"))
  }

  @Test
  func copiesTheTrustedHookWithoutExecutingItAndIncludesItInGenerationIdentity() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appending(path: "executed")
    let hook = root.appending(path: "sketchybar.sh")
    let hookContents =
      "printf touched > \(marker.path)\n"
      + "\"$SKETCHYBAR\" --add item personal.demo center\n"
    try hookContents.write(to: hook, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [sketchybar]
      hook = "sketchybar.sh"
      """,
      source: root.appending(path: "profile.toml")
    )
    let executable = root.appending(path: "development macarchy")

    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root,
      macarchyExecutableURL: executable
    )
    let withoutHook = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: .defaults,
      stateRoot: root,
      macarchyExecutableURL: executable
    )
    let installedExecutable = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: profile,
      stateRoot: root
    )
    let copied = try #require(
      composition.artifacts.first { $0.path == "plugins/user-hook.sh" }
    )
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
    let invocation = try #require(
      entry.contents.range(
        of: "'\(executable.path)' desktop _run-sketchybar-hook \"$PLUGIN_DIR/user-hook.sh\""
      )
    )
    let ready = try #require(entry.contents.range(of: "macarchy.theme.ready"))

    #expect(composition.hookURL == hook)
    #expect(composition.hookDigest == copied.digest)
    #expect(copied.contents == hookContents)
    #expect(invocation.lowerBound < ready.lowerBound)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(composition.inputDigest != withoutHook.inputDigest)
    #expect(composition.renderedDigest != withoutHook.renderedDigest)
    #expect(composition.inputDigest != installedExecutable.inputDigest)
    #expect(composition.renderedDigest != installedExecutable.renderedDigest)
    try requireValidShellSyntax(composition.artifacts, root: root)
  }

  @Test
  func rejectsInvalidTrustedHooksBeforeRendering() throws {
    let root = try configurationRoot()
    let outside = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-outside-hook-\(UUID().uuidString).sh"
    )
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let hook = root.appending(path: "hook.sh")
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[sketchybar]\nhook = \"hook.sh\"\n",
      source: root.appending(path: "profile.toml")
    )

    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
    }

    try "if then\n".write(to: hook, atomically: true, encoding: .utf8)
    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
    }

    try Data([0xef, 0xbb, 0xbf] + Array("# valid\n".utf8)).write(to: hook, options: .atomic)
    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
    }

    try FileManager.default.removeItem(at: hook)
    let hooks = root.appending(path: "hooks", directoryHint: .isDirectory)
    let shared = root.appending(path: "shared.sh")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
    try "# shared\n".write(to: shared, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: hooks.appending(path: "hook.sh").path,
      withDestinationPath: "../shared.sh"
    )
    let nestedProfile = try PortableProfileLoader().decode(
      "schema_version = 1\n[sketchybar]\nhook = \"hooks/hook.sh\"\n",
      source: root.appending(path: "profile.toml")
    )
    _ = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL,
      profile: nestedProfile,
      stateRoot: root
    )

    try "# outside\n".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: outside)
    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
    }
  }

  @Test
  func rejectsAnOverrideThatDuplicatesAPackagedModulePosition() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [sketchybar]
      right = ["clock", "spaces"]
      """,
      source: root.appending(path: "profile.toml")
    )

    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL,
        profile: profile,
        stateRoot: root
      )
    }
  }

  @Test
  func rejectsUnknownPackagedDefaultsBeforeRendering() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = root.appending(path: "defaults.toml")
    let original = try String(contentsOf: defaultsURL, encoding: .utf8)
    try (original + "plugin = \"unreviewed\"\n").write(
      to: invalid,
      atomically: true,
      encoding: .utf8
    )
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "profile.toml")
    )

    #expect(throws: SketchyBarConfigurationError.self) {
      _ = try SketchyBarConfigurationComposer().compose(
        defaultsURL: invalid,
        profile: profile,
        stateRoot: root
      )
    }
  }

  private var defaultsURL: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Desktop/sketchybar/defaults.toml")
  }

  private func configurationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-configuration-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func requireValidShellSyntax(
    _ artifacts: [SketchyBarConfigurationArtifact],
    root: URL
  ) throws {
    for artifact in artifacts {
      let file = root.appending(path: "syntax/\(artifact.path)")
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try artifact.contents.write(to: file, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-n", file.path]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0, Comment(rawValue: artifact.path))
    }
  }

  private func requireDateAccepts(_ format: String) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/date")
    process.arguments = [format]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
