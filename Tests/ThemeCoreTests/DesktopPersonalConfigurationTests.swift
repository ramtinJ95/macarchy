import Foundation
import Testing

@testable import ThemeCore

struct DesktopPersonalConfigurationTests {
  @Test(arguments: ["yabai", "sketchybar"])
  func nativeInputIsFrozenDistinctFromLegacyAndSyntaxChecked(provider: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "personal.sh")
    let sentinel = root.appending(path: "must-not-execute")
    let contents = "touch '\(sentinel.path)'\n"
    try contents.write(to: source, atomically: true, encoding: .utf8)
    func profile(_ key: String) throws -> PortableProfile {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[\(provider)]\n\(key) = \"personal.sh\"\n",
        source: root.appending(path: "profile.toml"))
    }
    func compose(_ key: String) throws -> (String, String) {
      let defaults = repository.appending(path: "Desktop/\(provider)/defaults.toml")
      if provider == "yabai" {
        let value = try YabaiConfigurationComposer().compose(
          defaultsURL: defaults, profile: profile(key))
        #expect((value.nativeConfigurationDigest != nil) == (key == "configuration"))
        return (value.inputDigest, value.renderedConfiguration)
      }
      let value = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaults, profile: profile(key), stateRoot: root.appending(path: "state"))
      #expect(value.nativeConfiguration == (key == "configuration"))
      #expect(
        value.artifacts.contains {
          $0.path == "plugins/user-hook.sh" && $0.contents.contains(contents)
        })
      let entry = try #require(value.artifacts.first { $0.path == "sketchybarrc" }).contents
      #expect(
        try #require(entry.range(of: "_run-sketchybar-hook")).lowerBound
          < #require(entry.range(of: SketchyBarConfigurationComposer.managedReadyMarkerDeclaration))
          .lowerBound)
      return (value.inputDigest, entry)
    }
    let native = try compose("configuration")
    let legacy = try compose("hook")
    #expect(native.0 != legacy.0)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    try "if then\n".write(to: source, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try compose("configuration") }
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    try (contents + "# personal change\n").write(to: source, atomically: true, encoding: .utf8)
    #expect(try compose("configuration").0 != native.0)
  }

  @Test(arguments: ["yabai", "sketchybar"])
  func machineNativeSourceUsesItsPhysicalLayerAndRejectsLegacyConflict(provider: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let machineRoot = root.appending(path: "machine")
    try FileManager.default.createDirectory(at: machineRoot, withIntermediateDirectories: true)
    let portable = root.appending(path: "profile.toml")
    let machine = machineRoot.appending(path: "profile.toml")
    for path in [portable, machine] {
      try "schema_version = 1\n[\(provider)]\nconfiguration = \"personal.sh\"\n"
        .write(to: path, atomically: true, encoding: .utf8)
    }
    let personal = machineRoot.appending(path: "personal.sh")
    try "# personal\n".write(to: personal, atomically: true, encoding: .utf8)
    let result = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true, machineAt: machine, machineRequired: true)
    #expect(result.fieldOrigins[provider + ".configuration"] == .machine)
    #expect(
      (provider == "yabai"
        ? result.profile.desktop.yabai.configurationURL
        : result.profile.sketchyBar.configurationURL) == personal)
    let conflict = try PortableProfileLoader().decode(
      "schema_version = 1\n[\(provider)]\nconfiguration = \"personal.sh\"\nhook = \"old.sh\"\n",
      source: machine)
    let defaults = repository.appending(path: "Desktop/\(provider)/defaults.toml")
    if provider == "yabai" {
      #expect(throws: YabaiConfigurationError.self) {
        try YabaiConfigurationComposer().compose(defaultsURL: defaults, profile: conflict)
      }
    } else {
      #expect(result.profile.sketchyBar.configurationRootURL?.path == machineRoot.path)
      #expect(throws: SketchyBarConfigurationError.self) {
        try SketchyBarConfigurationComposer().compose(
          defaultsURL: defaults, profile: conflict, stateRoot: root)
      }
    }
  }

  @Test(arguments: [false, true])
  func yabaiCompletionSignalRequiresSuccessfulPersonalCode(fails: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let personal = root.appending(path: "personal.sh")
    try (fails ? "false\nprintf 'must not run'\n" : "\"$YABAI\" -m config window_gap 123\n")
      .write(to: personal, atomically: true, encoding: .utf8)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[yabai]\nconfiguration = \"personal.sh\"\n",
      source: root.appending(path: "profile.toml"))
    let composition = try YabaiConfigurationComposer().compose(
      defaultsURL: repository.appending(path: "Desktop/yabai/defaults.toml"), profile: profile)
    let stub = root.appending(path: "yabai")
    let log = root.appending(path: "commands")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(
      to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let entry = root.appending(path: "yabairc")
    try composition.renderedConfiguration.replacingOccurrences(
      of: "YABAI=/opt/homebrew/bin/yabai", with: "YABAI='\(stub.path)'"
    )
    .write(to: entry, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [entry.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let commands = try String(contentsOf: log, encoding: .utf8)
    #expect((process.terminationStatus != 0) == fails)
    #expect(commands.contains(try #require(composition.nativeReadyLabel)) == !fails)
    #expect(commands.contains("label=macarchy-wallpaper") == !fails)
    if !fails {
      #expect(
        try #require(commands.range(of: "window_gap 5")).lowerBound
          < #require(commands.range(of: "window_gap 123")).lowerBound)
    }
  }

  private var repository: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "native-desktop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
