import Foundation
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func nativeStarshipRepaintsOnlyReservedColorsAndReadsPersonalEdits() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let url = root.appending(path: "starship-native.toml")
    let personal = #"""
      # My prompt; preserve comments and multiline strings.
      palette = "macarchy_current"
      format = """
      $directory
      $character
      """
      [directory]
      style = 'bold blue' # personal style
      [palettes.personal]
      blue = '#123456'

      """#
    let palette = try StarshipAdapter.render(package: catppuccinPackage())
    let initial = personal + palette.replacingOccurrences(of: "#89b4fa", with: "#010203")
    try initial.write(to: url, atomically: true, encoding: .utf8)
    let entry = root.appending(path: "starship.toml")
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: url)
    let adapter = StarshipAdapter(
      root: root, configurationURL: entry,
      behaviorURL: root.appending(path: "missing-legacy-behavior.toml"),
      executableURL: StarshipAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        #expect(request.environmentOverrides["STARSHIP_CONFIG"] == url.path)
        return ProcessResult(terminationStatus: 0, output: "palette = \"macarchy_current\"")
      })
    #expect(adapter.inspection().status == .drifted)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(adapter.inspection().status == .ready)
    let painted = try String(contentsOf: url, encoding: .utf8)
    #expect(painted.hasPrefix(personal))
    #expect(painted.contains("blue = \"#89b4fa\""))
    let edited = painted.replacingOccurrences(of: "bold blue", with: "italic green")
    try edited.write(to: url, atomically: true, encoding: .utf8)
    #expect(adapter.inspection().status == .ready)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(try String(contentsOf: url, encoding: .utf8) == edited)
    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: StarshipAdapter.bridgePath).path)
    )
  }

  @Test(arguments: ["selector", "quoted-table", "extra-color", "missing-color"])
  func nativeStarshipRejectsAmbiguousOwnershipWithoutWriting(_ change: String) throws {
    let url = URL(filePath: "/tmp/starship-native.toml")
    let native = StarshipNativeConfiguration(url: url)
    let palette = try StarshipAdapter.render(package: catppuccinPackage())
    var source = "palette = \"macarchy_current\"\n" + palette
    switch change {
    case "selector":
      source = source.replacingOccurrences(
        of: "palette = \"macarchy_current\"", with: "palette = \"personal\"")
    case "quoted-table":
      source = source.replacingOccurrences(
        of: "[palettes.macarchy_current]", with: "[palettes.\"macarchy_current\"]")
    case "extra-color": source += "extra = \"#ffffff\"\n"
    default: source = source.replacingOccurrences(of: "blue = \"#89b4fa\"\n", with: "")
    }
    #expect(throws: (any Error).self) {
      try native.replacingPalette(in: Data(source.utf8), with: palette)
    }
  }

  @Test
  func nativeStarshipPublicationPreservesMetadataAndRefusesStaleInputOrResidue() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "starship-native.toml")
    let native = StarshipNativeConfiguration(url: url)
    try Data("personal".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
    #expect(throws: (any Error).self) {
      try native.publish(Data("new".utf8), replacing: Data("stale".utf8))
    }
    #expect(try native.read() == Data("personal".utf8))
    try native.publish(Data("new".utf8), replacing: Data("personal".utf8))
    #expect(try native.read() == Data("new".utf8))
    #expect(
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640
    )
    let residue = root.appending(path: ".starship-native.toml.macarchy-palette")
    try Data("retained edit".utf8).write(to: residue)
    #expect(throws: (any Error).self) {
      try native.publish(Data("later".utf8), replacing: Data("new".utf8))
    }
    #expect(try native.read() == Data("new".utf8))
    #expect(try String(contentsOf: residue, encoding: .utf8) == "retained edit")
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_STARSHIP_CONFIG"] == "1"),
    arguments: [false, true])
  func installedStarshipReadsWritableNativeConfiguration(external: Bool) async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let state = root.appending(path: "state-root")
    _ = try testActivator(root: state).activate(package: catppuccinPackage())
    let url = root.appending(path: external ? "personal-prompt.toml" : "starship-native.toml")
    try
      ("palette = \"macarchy_current\"\nformat = '$directory$character'\n"
      + StarshipAdapter.render(package: catppuccinPackage()))
      .write(to: url, atomically: true, encoding: .utf8)
    let entry = root.appending(path: "starship.toml")
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: url)
    let adapter = StarshipAdapter(
      root: state, configurationURL: entry,
      behaviorURL: external ? url : root.appending(path: "unused"),
      executableURL: StarshipAdapter.liveExecutableURL, controlIsAvailable: { true },
      processRunner: .live)
    #expect(try await adapter.reconciliation().run().status == .applied)
  }
}
