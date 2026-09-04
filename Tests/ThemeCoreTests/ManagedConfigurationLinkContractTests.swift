import Foundation
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func batAndYaziReadOnlyTheExactManagedEnvironmentConfigurationLinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try Self.consumerPaths(
      root: root,
      kittyConfigurationURL: root.appending(path: "unused-kitty.conf"),
      sketchyBarConfigurationURL: root.appending(path: "unused-sketchybarrc")
    )
    let runner = ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    let bat = BatAdapter(
      root: root,
      configurationDirectoryURL: paths.batConfigurationDirectoryURL,
      cacheDirectoryURL: paths.batCacheDirectoryURL,
      executableURL: URL(filePath: "/test/bat"),
      controlIsAvailable: { true },
      processRunner: runner
    )
    let yazi = YaziAdapter(
      root: root,
      configurationDirectoryURL: paths.yaziConfigurationDirectoryURL,
      executableURL: URL(filePath: "/test/yazi"),
      controlURL: URL(filePath: "/test/ya"),
      controlsAreAvailable: { true },
      processRunner: runner
    )
    let batConfiguration = "--theme=\"\(BatAdapter.themeName)\"\n"
    let yaziTheme = "[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n"

    // Ordinary files keep working exactly as before.
    #expect(bat.inspection().status == .ready)
    #expect(yazi.inspection().status == .ready)

    // Stage a generation the way environment apply does: `environment/current`
    // is a relative pointer to the generation, whose leaves are regular files.
    let generation = root.appending(
      path: "environment/generations/e-test", directoryHint: .isDirectory)
    for directory in ["bat", "yazi"] {
      try FileManager.default.createDirectory(
        at: generation.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "environment/current").path,
      withDestinationPath: "generations/e-test"
    )
    try batConfiguration.write(
      to: generation.appending(path: "bat/config"), atomically: true, encoding: .utf8)
    try yaziTheme.write(
      to: generation.appending(path: "yazi/theme.toml"), atomically: true, encoding: .utf8)

    let batLeaf = paths.batConfigurationDirectoryURL.appending(path: "config")
    let yaziLeaf = paths.yaziConfigurationDirectoryURL.appending(path: "theme.toml")
    let batManaged = root.appending(path: BatAdapter.managedConfigurationPath)
    let yaziManaged = root.appending(path: YaziAdapter.managedThemeConfigurationPath)
    try relink(batLeaf, to: batManaged)
    try relink(yaziLeaf, to: yaziManaged)
    #expect(bat.inspection().status == .ready)
    #expect(yazi.inspection().status == .ready)

    // A same-named leaf with identical, valid contents anywhere else is still
    // rejected: acceptance depends on the exact managed destination, not on
    // what the link happens to contain.
    let foreign = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    try batConfiguration.write(
      to: foreign.appending(path: "config"), atomically: true, encoding: .utf8)
    try yaziTheme.write(
      to: foreign.appending(path: "theme.toml"), atomically: true, encoding: .utf8)
    let wrongBatDestinations = [
      foreign.appending(path: "config"),
      generation.appending(path: "bat/config"),
    ]
    let wrongYaziDestinations = [
      foreign.appending(path: "theme.toml"),
      generation.appending(path: "yazi/theme.toml"),
    ]
    for destination in wrongBatDestinations {
      try relink(batLeaf, to: destination)
      let inspection = bat.inspection()
      #expect(inspection.status == .failed)
      #expect(inspection.message?.contains(destination.path) == true)
      #expect(inspection.message?.contains(batManaged.path) == true)
    }
    for destination in wrongYaziDestinations {
      try relink(yaziLeaf, to: destination)
      let inspection = yazi.inspection()
      #expect(inspection.status == .failed)
      #expect(inspection.message?.contains(destination.path) == true)
      #expect(inspection.message?.contains(yaziManaged.path) == true)
    }

    // The managed destination is still opened without following its leaf, so
    // a generation whose leaf became a link is not silently accepted.
    try relink(batLeaf, to: batManaged)
    try relink(generation.appending(path: "bat/config"), to: foreign.appending(path: "config"))
    let indirect = bat.inspection()
    #expect(indirect.status == .failed)
    #expect(indirect.message?.contains("Cannot read bat configuration") == true)
  }

  private func relink(_ link: URL, to destination: URL) throws {
    try? FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
  }
}
