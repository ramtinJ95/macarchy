import Foundation
import Testing

@testable import ThemeCore

struct PackageProfileTests {
  @Test(arguments: [false, true])
  func layersKeepTheirOwnPathsAndDecisions(machineSelectsStandard: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let portable = root.appending(path: "dotfiles/profile.toml")
    let exposed = root.appending(path: "profile.toml")
    let machine = root.appending(path: "local/machine.toml")
    try write(
      """
      schema_version = 1
      [packages]
      baseline = "personal"
      brewfile = "Brewfile"
      exclude_casks = ["spotify"]
      """, at: portable)
    try FileManager.default.createSymbolicLink(at: exposed, withDestinationURL: portable)
    try write(
      """
      schema_version = 1
      [packages]
      brewfile = "machine.Brewfile"
      exclude_casks = []
      """ + (machineSelectsStandard ? "\nbaseline = \"standard\"\n" : "\n"), at: machine)
    let layered = try PortableProfileLoader().load(
      portableAt: exposed, portableRequired: true, machineAt: machine, machineRequired: true)
    let packages = layered.profile.packages
    #expect(packages.baseline == (machineSelectsStandard ? .standard : .personal))
    #expect(packages.layers.map(\.kind) == [.portable, .machine])
    #expect(
      packages.layers.map(\.brewfileURL) == [
        root.appending(path: "dotfiles/Brewfile"), root.appending(path: "local/machine.Brewfile"),
      ])
    #expect(packages.layers.map(\.excludedCasks) == [["spotify"], []])
    #expect(layered.fieldOrigins["packages.brewfile"] == nil)
    #expect(layered.fieldOrigins["packages.exclude_casks"] == nil)
    #expect(
      layered.fieldOrigins["packages.baseline"] == (machineSelectsStandard ? .machine : .portable))
    #expect(layered.layers.allSatisfy { $0.declaredFields.contains("packages.brewfile") })
  }

  @Test(arguments: ["", "../Brewfile", "/tmp/Brewfile"])
  func fragmentUsesExistingPortablePathRules(path: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: KeybindingProfileError.self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[packages]\nbrewfile = \"\(path)\"\n",
        source: root.appending(path: "profile.toml"))
    }
  }

  @Test
  func escapingFragmentSymlinkIsRejected() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appending(path: "profile/profile.toml")
    try write("brew \"hello\"\n", at: root.appending(path: "outside.Brewfile"))
    try write("schema_version = 1\n[packages]\nbrewfile = \"Brewfile\"\n", at: profile)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "profile/Brewfile"),
      withDestinationURL: root.appending(path: "outside.Brewfile"))
    #expect(throws: KeybindingProfileError.self) {
      try PortableProfileLoader().load(at: profile, required: true)
    }
  }

  @Test(arguments: ["baseline = \"everything\"", "exclude_formulae = \"jq\"", "unknown = true"])
  func unsupportedPackageFieldsFailStrictly(field: String) throws {
    #expect(throws: KeybindingProfileError.self) {
      try PortableProfileLoader().decode(
        "schema_version = 1\n[packages]\n\(field)\n", source: URL(filePath: "/tmp/profile.toml"))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-package-profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}
