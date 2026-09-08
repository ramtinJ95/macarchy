import Foundation
import Testing

@testable import ThemeCore

struct MacOSPreferencesProfileTests {
  private let source = URL(filePath: "/tmp/preferences-profile.toml")

  @Test
  func preferencesAreOptInAndOnlyDeclaredValuesAreSelected() throws {
    let loader = PortableProfileLoader()
    let empty = try loader.decode("schema_version = 1", source: source)
    #expect(empty.macOSPreferences.selected.isEmpty)
    let dormant = try loader.decode(
      """
      schema_version = 1
      [macos_preferences]
      dock_autohide = true
      """, source: source)
    #expect(!dormant.macOSPreferences.enabled)
    #expect(dormant.macOSPreferences.selected.isEmpty)
    let selected = try loader.decode(
      """
      schema_version = 1
      [macos_preferences]
      enabled = true
      finder_show_extensions = false
      """, source: source)
    #expect(selected.macOSPreferences.selected == [.finderShowExtensions: false])
  }

  @Test(arguments: [
    "enabled = 'true'", "dock_autohide = 1", "finder_show_extensions = 'false'",
    "arbitrary_defaults_key = true", "dock_autohide = true\ndock_autohide = false",
  ])
  func rejectsUnknownAndUntypedSettings(field: String) {
    #expect(throws: (any Error).self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[macos_preferences]\n\(field)", source: source)
    }
  }

  @Test
  func machineFieldsOverrideIndependentlyAndCanDisableInheritedValues() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "profile.toml")
    let machine = root.appending(path: "machine.toml")
    try """
    schema_version = 1
    [macos_preferences]
    enabled = true
    dock_autohide = true
    finder_show_extensions = true
    """.write(to: portable, atomically: true, encoding: .utf8)
    try """
    schema_version = 1
    [macos_preferences]
    dock_autohide = false
    """.write(to: machine, atomically: true, encoding: .utf8)
    let layered = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true, machineAt: machine, machineRequired: true)
    #expect(
      layered.profile.macOSPreferences.selected == [
        .dockAutohide: false, .finderShowExtensions: true,
      ])
    #expect(layered.fieldOrigins["macos_preferences.dock_autohide"] == .machine)
    #expect(layered.fieldOrigins["macos_preferences.finder_show_extensions"] == .portable)
    try "schema_version = 1\n[macos_preferences]\nenabled = false".write(
      to: machine, atomically: true, encoding: .utf8)
    let disabled = try PortableProfileLoader().load(
      portableAt: portable, portableRequired: true, machineAt: machine, machineRequired: true)
    #expect(disabled.profile.macOSPreferences.selected.isEmpty)
    #expect(disabled.profile.macOSPreferences.dockAutohide == true)
  }
}
