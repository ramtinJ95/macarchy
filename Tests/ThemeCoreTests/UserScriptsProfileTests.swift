import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct UserScriptsProfileTests {
  @Test func scriptsResolveBesideTheProfileAndLayersReplaceTheList() throws {
    try withTemporaryRoot(named: "scripts-profile") { root in
      let source = root.appending(path: "profile.toml")
      let machine = root.appending(path: "machine.toml")
      let loader = PortableProfileLoader()
      #expect(
        try loader.decode("schema_version = 1", source: source).environment.scripts.run.isEmpty)
      let text = "schema_version = 1\n[scripts]\nrun = [\"scripts/one\", \"scripts/two\"]\n"
      let profile = try loader.decode(text, source: source)
      #expect(
        profile.environment.scripts.run == [
          root.appending(path: "scripts/one"), root.appending(path: "scripts/two"),
        ])
      try text.write(to: source, atomically: false, encoding: .utf8)
      try "schema_version = 1\n[scripts]\nrun = [\"scripts/replacement\"]\n"
        .write(to: machine, atomically: false, encoding: .utf8)
      let merged = try loader.load(
        portableAt: source, portableRequired: true, machineAt: machine, machineRequired: true)
      #expect(
        merged.profile.environment.scripts.run == [root.appending(path: "scripts/replacement")])
    }
  }

  @Test(arguments: [
    ("[\"/tmp/script\"]", "relative path"),
    ("[\"../script\"]", "stay beside the profile"),
    ("[\"a\", \"a\"]", "duplicate"),
    ("[\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\", \"h\", \"i\"]", "at most 8"),
  ])
  func invalidListsAreRejected(list: String, reason: String) throws {
    do {
      _ = try PortableProfileLoader().decode(
        "schema_version = 1\n[scripts]\nrun = \(list)",
        source: URL(filePath: "/profiles/profile.toml"))
      Issue.record("Accepted invalid scripts list")
    } catch { #expect(String(describing: error).contains(reason)) }
  }

  @Test func linksMayNotEscapeTheProfile() throws {
    try withTemporaryRoot(named: "scripts-profile-links") { root in
      let directory = root.appending(path: "profile")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: "escape"),
        withDestinationURL: root)
      #expect(throws: (any Error).self) {
        try PortableProfileLoader().decode(
          "schema_version = 1\n[scripts]\nrun = [\"escape/script\"]",
          source: directory.appending(path: "profile.toml"))
      }
    }
  }
}
