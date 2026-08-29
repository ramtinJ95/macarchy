import Foundation
import Testing

@testable import MacarchyCLI

struct KeybindingProviderInspectionTests {
  private let inspector = KeybindingProviderInspector()

  @Test
  func directorySymlinkWithOnlySkhdrcIsEligibleForAdoption() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "alt - j : default\n".write(
      to: fixture.dotfiles.appending(path: "skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspector.inspect(homeDirectory: fixture.home)

    #expect(inspection.status == .adoptionRequired)
    #expect(inspection.ownership == "directory_symlink")
    #expect(inspection.source == fixture.dotfiles.appending(path: "skhdrc").path)
  }

  @Test
  func directorySymlinkWithUnknownSiblingBlocksAdoption() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for file in ["skhdrc", "partial.skhdrc"] {
      try "# fixture\n".write(
        to: fixture.dotfiles.appending(path: file),
        atomically: true,
        encoding: .utf8
      )
    }
    try FileManager.default.createSymbolicLink(
      at: fixture.skhdDirectory,
      withDestinationURL: fixture.dotfiles
    )

    let inspection = inspector.inspect(homeDirectory: fixture.home)

    #expect(inspection.status == .blocked)
    #expect(inspection.message.contains("partial.skhdrc"))
  }

  @Test
  func exactManagedEntryLinkIsAConvergedProviderSeam() throws {
    let fixture = try fixtureHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.skhdDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: fixture.skhdDirectory.appending(path: "skhdrc").path,
      withDestinationPath: KeybindingProviderInspector.managedTarget
    )

    let inspection = inspector.inspect(homeDirectory: fixture.home)

    #expect(inspection.status == .managed)
    #expect(inspection.ownership == "managed_symlink")
  }

  private func fixtureHome() throws -> (
    root: URL,
    home: URL,
    dotfiles: URL,
    skhdDirectory: URL
  ) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-provider-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let configuration = home.appending(path: ".config", directoryHint: .isDirectory)
    let dotfiles = root.appending(path: "dotfiles/skhd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    return (
      root,
      home,
      dotfiles,
      configuration.appending(path: "skhd", directoryHint: .isDirectory)
    )
  }
}
