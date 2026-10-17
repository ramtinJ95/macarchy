import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@Suite(.serialized)
struct BtopYaziAtuinSetupTests {
  @Test
  func ownedBatchPreservesUnrelatedConfigurationAndRoundTrips() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let btop = "# personal btop settings\n\(BtopAdapter.themeDirective)\n"
    let yazi = "[mgr]\r\nratio = [1, 2, 3]\r\n\r\n[flavor]\r\nlight = \"default\"\r\n"
    let atuin = "sync_address = \"https://api.atuin.sh\"\n"
    try FileManager.default.createDirectory(
      at: fixture.btopConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(btop.utf8).write(to: fixture.btopConfiguration)
    try fixture.tearDownLegacyOwnership(
      [
        fixture.legacyThemeLink(SetupOwnershipManager.btopThemeLinkID),
        fixture.legacyFileRecord(
          SetupOwnershipManager.yaziSelectorID,
          original: yazi,
          installed:
            "[mgr]\r\nratio = [1, 2, 3]\r\n\r\n[flavor]\r\ndark = \"macarchy-current\"\r\nlight = \"default\"\r\n"
        ),
        fixture.legacyThemeLink(SetupOwnershipManager.yaziFlavorLinkID),
        fixture.legacyThemeLink(SetupOwnershipManager.yaziSyntaxLinkID),
        fixture.legacyFileRecord(
          SetupOwnershipManager.atuinSelectorID,
          original: atuin,
          installed: atuin + "[theme]\nname = \"macarchy-current\"\n"
        ),
        fixture.legacyThemeLink(SetupOwnershipManager.atuinThemeLinkID),
      ],
      expectingRemoved: [
        "btop.theme-link", "yazi.selector", "yazi.flavor-link", "yazi.syntax-link",
        "atuin.selector", "atuin.theme-link",
      ])
    #expect(try String(contentsOf: fixture.btopConfiguration, encoding: .utf8) == btop)
    #expect(try String(contentsOf: fixture.yaziConfiguration, encoding: .utf8) == yazi)
    #expect(try String(contentsOf: fixture.atuinConfiguration, encoding: .utf8) == atuin)
    #expect(!FileManager.default.fileExists(atPath: fixture.btopThemeLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.yaziFlavorLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.yaziSyntaxLink.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.atuinThemeLink.path))
  }
}
