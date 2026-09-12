import Foundation
import Testing

@testable import ThemeCore

struct SketchyBarConfigurationTests {
  @Test(arguments: [false, true])
  func generatedCommandsPreserveNativeArguments(toggle: Bool) throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[sketchybar]\nleft = []\nright = [\"\(toggle ? "toggle" : "volume")\"]\n",
      source: root.appending(path: "profile.toml"))
    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL, profile: profile, stateRoot: root)
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
    let command = try #require(
      entry.contents.split(separator: "\n").first {
        $0.contains(toggle ? "--set macarchy.toggle updates=" : "--add slider ")
      })
    let recorder = root.appending(path: "record-arguments.sh")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(
      to: recorder, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", String(command)]
    let token = "00000000-0000-0000-0000-000000000001"
    process.environment = ["SKETCHYBAR": recorder.path, "TOGGLE_TOKEN": token]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let arguments = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    )
    .split(separator: "\n").map(String.init)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    if toggle {
      #expect(
        arguments.contains(
          "script="
            + SketchyBarConfigurationComposer.toggleScript(
              pluginPath: root.appending(path: "desktop/sketchybar/current/plugins/toggle.sh").path,
              token: token)))
      #expect(
        arguments.suffix(4) == ["--subscribe", "macarchy.toggle", "display_change", "system_woke"])
    } else {
      // Native 2.23.0 message.c consumes position before the slider width.
      #expect(
        Array(arguments.prefix(5))
          == ["--add", "slider", "macarchy.volume.slider", "popup.macarchy.volume.bracket", "250"])
    }
  }

  @Test func callbacksTreatMetacharactersInPluginPathsAsLiteralData() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appending(path: "$HOME `id` 'quoted'.sh")
    try "#!/bin/sh\nprintf '%s\\n' \"$SENDER\" \"$0\"\n".write(
      to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let command = SketchyBarConfigurationComposer.pluginClickScript(
      sender: "macarchy.slider", pluginPath: script.path)
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", command]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(text == "macarchy.slider\n\(script.path)\n")
  }

  @Test func nativeMenuToggleIsGenerationScopedAndNeverKillsAnotherProcess() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for enabled in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = []\nright = \(enabled ? "[\"toggle\"]" : "[]")\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      #expect(entry.contents.contains("\"$PLUGIN_DIR/toggle.sh\" \"$TOGGLE_TOKEN\"") == enabled)
      #expect(entry.contents.contains("label=\"$TOGGLE_TOKEN|starting\"") == enabled)
      #expect(entry.contents.contains("hidden=off y_offset=0"))
      #expect(!entry.contents.contains("pkill"))
      #expect(!entry.contents.contains("killall"))
      #expect(!entry.contents.contains("2>&1"))
      let watchdog = composition.artifacts.first { $0.path == "plugins/toggle.sh" }
      #expect((watchdog != nil) == enabled)
      if enabled {
        #expect(watchdog?.contents.contains("desktop _bar-toggle") == true)
        #expect(watchdog?.contents.contains("2>&1") == false)
        #expect(entry.contents.contains("updates=on update_freq=1"))
        #expect(entry.contents.contains("--subscribe macarchy.toggle display_change system_woke"))
        let ready = try #require(
          entry.contents.range(of: SketchyBarConfigurationComposer.managedReadyMarkerDeclaration))
        let helper = try #require(
          entry.contents.range(of: "\"$PLUGIN_DIR/toggle.sh\" \"$TOGGLE_TOKEN\""))
        #expect(ready.lowerBound < helper.lowerBound)
      }
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test func appleUsesOnlyTheSeparatePackagedHelperAndCanBeRemoved() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for enabled in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = \(enabled ? "[\"apple\"]" : "[]")\nright = []\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root,
        macarchyExecutableURL: URL(filePath: "/Applications/Macarchy Tools/macarchy"))
      let apple = composition.artifacts.first { $0.path == "plugins/apple.sh" }
      #expect((apple != nil) == enabled)
      if let apple {
        #expect(apple.contents.contains("'/Applications/Macarchy Tools/macarchy-menu'"))
        #expect(apple.contents.contains("ACTION=--open-apple-menu"))
        #expect(!apple.contents.contains("AXIsProcessTrustedWithOptions"))
        #expect(!apple.contents.contains("swiftc"))
      }
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test func mediaHasOnePollerAndSelectableControlsWithoutDeprecatedEvents() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for enabled in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = []\nright = []\ncenter = \(enabled ? "[\"media\"]" : "[]")\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      #expect(entry.contents.contains("--add item macarchy.media center") == enabled)
      #expect(entry.contents.contains("popup.macarchy.media") == enabled)
      #expect(composition.artifacts.contains { $0.path == "plugins/media.sh" } == enabled)
      #expect(!entry.contents.contains("media_change"))
      if enabled { #expect(entry.contents.contains("updates=on update_freq=2")) }
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test func calendarDefaultsAdaptButExplicitPositionsRemainAuthoritative() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for explicit in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n" + (explicit ? "[sketchybar]\nright = [\"clock\"]\n" : ""),
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      #expect(composition.automaticClock == !explicit)
      let clock = try #require(composition.artifacts.first { $0.path == "plugins/clock.sh" })
      #expect(clock.contents.contains("--position '\(explicit ? "right" : "auto")'"))
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      #expect(entry.contents.contains("macarchy.clock.preview right"))
      #expect(entry.contents.contains("mouse.clicked display_change system_woke"))
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test
  func wifiHasOnePollerAndIndividuallyRemovedPopupInventory() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for enabled in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = []\nright = []\ncenter = \(enabled ? "[\"wifi\"]" : "[]")\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root,
        macarchyExecutableURL: URL(filePath: "/Applications/Macarchy Tools/macarchy"))
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      #expect(entry.contents.contains("--add item macarchy.wifi center") == enabled)
      #expect(entry.contents.contains("popup.macarchy.wifi") == enabled)
      #expect(composition.artifacts.contains { $0.path == "plugins/wifi.sh" } == enabled)
      if enabled {
        let script = try #require(composition.artifacts.first { $0.path == "plugins/wifi.sh" })
        #expect(
          script.contents.contains("exec '/Applications/Macarchy Tools/macarchy' desktop _wifi"))
        #expect(!entry.contents.contains("wifi_change"))
        #expect(!script.contents.contains("killall"))
      }
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test(arguments: [true, false])
  func automaticClockCanBeSelectedWithoutRestoringExcludedMedia(automatic: Bool) throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [sketchybar]
      center = ["clock"]
      right = ["battery", "volume", "wifi", "cpu", "memory", "toggle"]
      automatic_clock = \(automatic)
      """, source: root.appending(path: "profile.toml"))
    let composition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaultsURL, profile: profile, stateRoot: root)
    #expect(composition.automaticClock == automatic)
    #expect(composition.layout.position(of: .media) == nil)
    let clock = try #require(composition.artifacts.first { $0.path == "plugins/clock.sh" })
    #expect(clock.contents.contains("--position '\(automatic ? "auto" : "center")'"))
    let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
    #expect(entry.contents.contains("label.align=center updates=on update_freq=30"))
    #expect(!entry.contents.contains("macarchy.media"))
  }

  @Test func automaticClockRejectsAHiddenClockAndNonBooleanIntent() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for value in ["true", "\"auto\""] {
      #expect(throws: (any Error).self) {
        let profile = try PortableProfileLoader().decode(
          "schema_version = 1\n[sketchybar]\nright = []\nautomatic_clock = \(value)\n",
          source: root.appending(path: "profile.toml"))
        _ = try SketchyBarConfigurationComposer().compose(
          defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      }
    }
  }

  @Test
  func metricsAreIndividuallyPositionedAndRemoved() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for modules in [[], ["cpu"], ["memory"], ["cpu", "memory"]] {
      let selected = modules.map { "\"\($0)\"" }.joined(separator: ",")
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = []\nright = []\ncenter = [\(selected)]\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      for module in ["cpu", "memory"] {
        #expect(
          entry.contents.contains("--add item macarchy.\(module) center")
            == modules.contains(module))
        #expect(
          composition.artifacts.contains { $0.path == "plugins/\(module).sh" }
            == modules.contains(module))
      }
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
  }

  @Test
  func composesTheCompleteDeterministicPersonalDefault() throws {
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
    #expect(first.settings.height == 30)
    #expect(first.settings.margin == 0)
    #expect(first.settings.cornerRadius == 0)
    #expect(first.settings.itemPadding == 0)
    #expect(first.spaceModule == SketchyBarSpaceModule.dynamicYabai)
    #expect(first.layout.left == [.apple, .spaces])
    #expect(first.layout.center.isEmpty)
    #expect(
      first.layout.right == [.clock, .battery, .volume, .wifi, .cpu, .memory, .media, .toggle])
    #expect(first.automaticClock)
    #expect(
      first.artifacts.map { $0.path }
        == [
          "sketchybarrc", "plugins/clock.sh", "plugins/space-indexes.sh", "plugins/toggle.sh",
          "plugins/volume.sh",
          "plugins/battery.sh", "plugins/cpu.sh", "plugins/memory.sh", "plugins/wifi.sh",
          "plugins/apple.sh", "plugins/media.sh",
        ]
    )
    let entry = try #require(first.artifacts.first { $0.path == "sketchybarrc" })
    #expect(entry.contents.contains("topmost=window padding_left=8 padding_right=8"))
    #expect(entry.contents.contains("icon.font='SF Pro:Bold:13.0'"))
    #expect(entry.contents.contains("label.font='SF Pro:Semibold:12.0'"))
    #expect(entry.contents.contains("icon.width=24"))
    #expect(entry.contents.contains("popup.blur_radius=50"))
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
  func batteryIsPositionedAndDisabledThroughTheExistingLayout() throws {
    let root = try configurationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for enabled in [false, true] {
      let profile = try PortableProfileLoader().decode(
        "schema_version = 1\n[sketchybar]\nleft = []\nright = []\ncenter = \(enabled ? "[\"battery\"]" : "[]")\n",
        source: root.appending(path: "profile.toml"))
      let composition = try SketchyBarConfigurationComposer().compose(
        defaultsURL: defaultsURL, profile: profile, stateRoot: root)
      let entry = try #require(composition.artifacts.first { $0.path == "sketchybarrc" })
      #expect(entry.contents.contains("--add item macarchy.battery center") == enabled)
      #expect(entry.contents.contains("popup.macarchy.battery") == enabled)
      #expect(composition.artifacts.contains { $0.path == "plugins/battery.sh" } == enabled)
      try requireValidShellSyntax(composition.artifacts, root: root)
    }
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
    #expect(defaultComposition.artifacts.contains { $0.path == "plugins/volume.sh" })
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
