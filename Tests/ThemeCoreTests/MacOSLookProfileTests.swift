import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct MacOSLookProfileTests {
  @Test func optInDefaultsOffAndMachineLayerCanDisableIt() throws {
    try withTemporaryRoot(named: "accent-profile") { root in
      let loader = PortableProfileLoader()
      let source = root.appending(path: "profile.toml")
      #expect(try !loader.decode("schema_version = 1", source: source).environment.macOSLook.accent)
      let text = "schema_version = 1\n[macos_look]\naccent = true\n"
      #expect(try loader.decode(text, source: source).environment.macOSLook.accent)
      try text.write(to: source, atomically: false, encoding: .utf8)
      let machine = root.appending(path: "machine.toml")
      try "schema_version = 1\n[macos_look]\naccent = false\n".write(
        to: machine, atomically: false, encoding: .utf8)
      let layered = try loader.load(
        portableAt: source, portableRequired: true, machineAt: machine, machineRequired: true)
      #expect(!layered.profile.environment.macOSLook.accent)
      #expect(layered.fieldOrigins["macos_look.accent"] == .machine)
    }
  }

  @Test func iconStyleDefaultsOffAndMachineLayerCanDisableIt() throws {
    try withTemporaryRoot(named: "accent-profile") { root in
      let loader = PortableProfileLoader()
      let source = root.appending(path: "profile.toml")
      #expect(
        try !loader.decode("schema_version = 1", source: source).environment.macOSLook.iconStyle)
      let text = "schema_version = 1\n[macos_look]\nicon_style = true\n"
      #expect(try loader.decode(text, source: source).environment.macOSLook.iconStyle)
      try text.write(to: source, atomically: false, encoding: .utf8)
      let machine = root.appending(path: "machine.toml")
      try "schema_version = 1\n[macos_look]\nicon_style = false\n".write(
        to: machine, atomically: false, encoding: .utf8)
      let layered = try loader.load(
        portableAt: source, portableRequired: true, machineAt: machine, machineRequired: true)
      #expect(!layered.profile.environment.macOSLook.iconStyle)
      #expect(layered.fieldOrigins["macos_look.icon_style"] == .machine)
    }
  }

  @Test(arguments: ["accent = 1", "accent = \"true\"", "accents = true", "icon_style = 1"])
  func rejectsInvalidOptions(option: String) {
    #expect(throws: (any Error).self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[macos_look]\n\(option)", source: URL(filePath: "/profile.toml"))
    }
  }

  @Test(arguments: [ConsumerID.macOSAccent, .macOSIconStyle])
  func catalogIsOptionalAndOnlyProfileEnabled(id: ConsumerID) {
    let entry = ConsumerCatalog.shared.runtimeEntries.first { $0.id == id }
    #expect(entry?.mode.requirement == .optional)
    #expect(entry?.mode.isEnabledByDefault == false)
    #expect(entry?.setupManaged == false)
  }
}
