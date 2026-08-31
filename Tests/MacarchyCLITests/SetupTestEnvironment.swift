import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

let allIntegrationIDs = [
  "kitty.include",
  "bat.selector",
  "bat.theme-link",
  "eza.environment",
  "eza.theme-link",
  "btop.selector",
  "btop.theme-link",
  "yazi.selector",
  "yazi.flavor-link",
  "yazi.syntax-link",
  "atuin.selector",
  "atuin.theme-link",
  "neovim.watcher",
  "neovim.theme-link",
  "starship.behavior",
  "starship.configuration-link",
  "pi.selector",
  "pi.theme-link",
  "herdr.selector",
  "tuicr.selector",
  "tuicr.theme-link",
  "tuicr.syntax-link",
  "codex.selector",
  "codex.theme-link",
  "spicetify.selectors",
  "spicetify.color-link",
]

let externalFixtureStatuses: [String: SetupIntegrationResult.Status] = [
  "kitty.include": .external,
  "bat.selector": .external,
  "bat.theme-link": .external,
  "eza.environment": .external,
  "eza.theme-link": .external,
  "btop.selector": .external,
  "btop.theme-link": .external,
  "yazi.selector": .external,
  "yazi.flavor-link": .external,
  "yazi.syntax-link": .external,
  "atuin.selector": .external,
  "atuin.theme-link": .external,
  "neovim.watcher": .external,
  "neovim.theme-link": .external,
  "starship.behavior": .external,
  "starship.configuration-link": .external,
  "pi.selector": .external,
  "pi.theme-link": .external,
  "herdr.selector": .external,
  "tuicr.selector": .external,
  "tuicr.theme-link": .external,
  "tuicr.syntax-link": .external,
  "codex.selector": .external,
  "codex.theme-link": .external,
  "spicetify.selectors": .disabled,
  "spicetify.color-link": .disabled,
]

protocol IntegrationStatusResult {
  associatedtype IntegrationStatus: Equatable

  var id: String { get }
  var status: IntegrationStatus { get }
}

extension SetupIntegrationResult: IntegrationStatusResult {
  typealias IntegrationStatus = Status
}

func expectStatuses<Result: IntegrationStatusResult>(
  _ results: [Result],
  _ expectedByID: [String: Result.IntegrationStatus]
) {
  let actualIDs = results.map(\.id)
  let actualIDSet = Set(actualIDs)
  let expectedIDSet = Set(expectedByID.keys)
  let duplicateIDs = Dictionary(grouping: actualIDs, by: { $0 })
    .filter { $0.value.count > 1 }.keys.sorted()
  let missingIDs = expectedIDSet.subtracting(actualIDSet).sorted()
  let unexpectedIDs = actualIDSet.subtracting(expectedIDSet).sorted()

  #expect(duplicateIDs.isEmpty, "Duplicate integration IDs: \(duplicateIDs)")
  #expect(missingIDs.isEmpty, "Missing integration IDs: \(missingIDs)")
  #expect(unexpectedIDs.isEmpty, "Unexpected integration IDs: \(unexpectedIDs)")

  for id in expectedByID.keys.sorted() {
    guard
      let result = results.first(where: { $0.id == id }),
      let expectedStatus = expectedByID[id]
    else { continue }
    #expect(result.status == expectedStatus, "Unexpected status for \(id)")
  }
}

enum FixtureError: Error {
  case interrupted
}

final class Fixture {
  let root: URL
  let home: URL

  init(
    configuration: String? = nil,
    externalBatEza: Bool = true,
    externalBtopYaziAtuin: Bool = true,
    externalNeovimStarship: Bool = true,
    externalAgentTUIs: Bool = true
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-ownership-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    if let configuration {
      try FileManager.default.createDirectory(
        at: kittyConfiguration.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(configuration.utf8).write(to: kittyConfiguration)
    }
    if externalBatEza {
      try createExternalBatEzaSeams()
    }
    if externalBtopYaziAtuin {
      try createExternalBtopYaziAtuinSeams()
    }
    if externalNeovimStarship {
      try createExternalNeovimStarshipSeams()
    }
    if externalAgentTUIs {
      try createExternalAgentTUISeams()
    }
  }

  var stateRoot: URL {
    home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
  }

  var kittyConfiguration: URL {
    home.appending(path: ".config/kitty/kitty.conf")
  }

  var includeDirective: String {
    ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
  }

  var manifest: URL {
    stateRoot.appending(path: "state/setup/ownership.json")
  }

  var backup: URL {
    stateRoot.appending(path: "state/setup/backups/kitty.conf")
  }

  var batSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/bat-config")
  }

  var ezaEnvironmentBackup: URL {
    stateRoot.appending(path: "state/setup/backups/zshrc")
  }

  var replacement: URL {
    kittyConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-kitty-transaction")
  }

  var batConfiguration: URL {
    home.appending(path: ".config/bat/config")
  }

  var batThemeLink: URL {
    home.appending(path: ".config/bat/themes/\(BatAdapter.themeFileName)")
  }

  var batThemeDestination: URL {
    stateRoot.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
  }

  var batThemeRemoval: URL {
    batThemeLink.deletingLastPathComponent()
      .appending(path: ".macarchy-bat-theme-link-removal")
  }

  var shellConfiguration: URL {
    home.appending(path: ".zshrc")
  }

  var ezaThemeLink: URL {
    home.appending(path: ".config/eza/theme.yml")
  }

  var ezaThemeDestination: URL {
    stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
  }

  var batDirective: String {
    BatAdapter.themeDirective
  }

  var ezaDirective: String {
    EzaAdapter.environmentDirective(
      configurationDirectoryURL: ezaThemeLink.deletingLastPathComponent()
    )
  }

  var btopConfiguration: URL {
    home.appending(path: ".config/btop/btop.conf")
  }

  var btopThemeLink: URL {
    home.appending(path: ".config/btop/themes/\(BtopAdapter.themeFileName)")
  }

  var btopThemeDestination: URL {
    stateRoot.appending(path: "current/\(BtopAdapter.outputPath)")
  }

  var yaziConfiguration: URL {
    home.appending(path: ".config/yazi/theme.toml")
  }

  var yaziFlavorLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/flavor.toml")
  }

  var yaziFlavorDestination: URL {
    stateRoot.appending(path: "current/\(YaziAdapter.flavorOutputPath)")
  }

  var yaziSyntaxLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/tmtheme.xml")
  }

  var yaziSyntaxDestination: URL {
    stateRoot.appending(path: "current/\(TextMateThemeArtifact.yaziOutputPath)")
  }

  var atuinConfiguration: URL {
    home.appending(path: ".config/atuin/config.toml")
  }

  var atuinThemeLink: URL {
    home.appending(path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml")
  }

  var atuinThemeDestination: URL {
    stateRoot.appending(path: "current/\(AtuinAdapter.outputPath)")
  }

  var yaziSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/yazi-theme.toml")
  }

  var atuinSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/atuin-config.toml")
  }

  func writeKittyConfiguration(_ configuration: String) throws {
    try FileManager.default.createDirectory(
      at: kittyConfiguration.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(configuration.utf8).write(to: kittyConfiguration, options: .atomic)
  }

  func createLocalBatEzaConfigurations(bat: String, shell: String) throws {
    try FileManager.default.createDirectory(
      at: batThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(bat.utf8).write(to: batConfiguration)
    try Data(shell.utf8).write(to: shellConfiguration)
    try FileManager.default.createDirectory(
      at: ezaThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  func createLocalBtopYaziAtuinConfigurations(
    btop: String,
    yazi: String,
    atuin: String
  ) throws {
    try FileManager.default.createDirectory(
      at: btopThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(btop.utf8).write(to: btopConfiguration)
    try FileManager.default.createDirectory(
      at: yaziFlavorLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(yazi.utf8).write(to: yaziConfiguration)
    try FileManager.default.createDirectory(
      at: atuinThemeLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(atuin.utf8).write(to: atuinConfiguration)
  }

  func createBtopYaziAtuinThemeLinks() throws {
    try FileManager.default.createSymbolicLink(
      at: btopThemeLink,
      withDestinationURL: btopThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorLink,
      withDestinationURL: yaziFlavorDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziSyntaxLink,
      withDestinationURL: yaziSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: atuinThemeLink,
      withDestinationURL: atuinThemeDestination
    )
  }

  func batConfigurationText() throws -> String {
    try String(contentsOf: batConfiguration, encoding: .utf8)
  }

  func shellConfigurationText() throws -> String {
    try String(contentsOf: shellConfiguration, encoding: .utf8)
  }

  func linkDestination(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  private func createExternalBatEzaSeams() throws {
    let batDirectory = home.appending(path: ".config/bat")
    let batThemes = batDirectory.appending(path: "themes")
    try FileManager.default.createDirectory(at: batThemes, withIntermediateDirectories: true)
    try Data("\(batDirective)\n".utf8).write(
      to: batDirectory.appending(path: "config")
    )
    try FileManager.default.createSymbolicLink(
      at: batThemes.appending(path: BatAdapter.themeFileName),
      withDestinationURL: batThemeDestination
    )

    try Data("\(ezaDirective)\n".utf8).write(
      to: home.appending(path: ".zshrc")
    )
    let ezaDirectory = home.appending(path: ".config/eza")
    try FileManager.default.createDirectory(at: ezaDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: ezaDirectory.appending(path: "theme.yml"),
      withDestinationURL: ezaThemeDestination
    )
  }

  private func createExternalBtopYaziAtuinSeams() throws {
    let dotfiles = root.appending(path: "dotfiles")
    let configurationRoot = home.appending(path: ".config")
    try FileManager.default.createDirectory(
      at: configurationRoot,
      withIntermediateDirectories: true
    )

    let btop = dotfiles.appending(path: "btop")
    let btopThemes = btop.appending(path: "themes")
    try FileManager.default.createDirectory(at: btopThemes, withIntermediateDirectories: true)
    try Data("\(BtopAdapter.themeDirective)\n".utf8).write(
      to: btop.appending(path: "btop.conf")
    )
    try FileManager.default.createSymbolicLink(
      at: btopThemes.appending(path: BtopAdapter.themeFileName),
      withDestinationURL: btopThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: configurationRoot.appending(path: "btop"),
      withDestinationURL: btop
    )

    let yazi = dotfiles.appending(path: "yazi")
    let yaziFlavorDirectory = yazi.appending(
      path: "flavors/\(YaziAdapter.flavorName).yazi")
    try FileManager.default.createDirectory(
      at: yaziFlavorDirectory,
      withIntermediateDirectories: true
    )
    try Data("[flavor]\ndark = \"\(YaziAdapter.flavorName)\"\n".utf8).write(
      to: yazi.appending(path: "theme.toml")
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorDirectory.appending(path: "flavor.toml"),
      withDestinationURL: yaziFlavorDestination
    )
    try FileManager.default.createSymbolicLink(
      at: yaziFlavorDirectory.appending(path: "tmtheme.xml"),
      withDestinationURL: yaziSyntaxDestination
    )
    try FileManager.default.createSymbolicLink(
      at: configurationRoot.appending(path: "yazi"),
      withDestinationURL: yazi
    )

    let atuin = configurationRoot.appending(path: "atuin")
    try FileManager.default.createDirectory(at: atuin, withIntermediateDirectories: true)
    let externalAtuin = dotfiles.appending(path: "atuin")
    let externalAtuinThemes = externalAtuin.appending(path: "themes")
    try FileManager.default.createDirectory(
      at: externalAtuinThemes,
      withIntermediateDirectories: true
    )
    let externalAtuinConfiguration = externalAtuin.appending(path: "config.toml")
    try Data("[theme]\nname = \"\(AtuinAdapter.themeName)\"\n".utf8).write(
      to: externalAtuinConfiguration
    )
    try FileManager.default.createSymbolicLink(
      at: externalAtuinThemes.appending(path: "\(AtuinAdapter.themeName).toml"),
      withDestinationURL: atuinThemeDestination
    )
    try FileManager.default.createSymbolicLink(
      at: atuin.appending(path: "config.toml"),
      withDestinationURL: externalAtuinConfiguration
    )
    try FileManager.default.createSymbolicLink(
      at: atuin.appending(path: "themes"),
      withDestinationURL: externalAtuinThemes
    )
  }

  func configuration() throws -> String {
    try String(contentsOf: kittyConfiguration, encoding: .utf8)
  }

  func permissions() throws -> Int {
    try permissions(at: kittyConfiguration)
  }

  func permissions(at url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        as? Int
    )
  }

  func setExtendedAttribute(name: String, value: String) throws {
    try MacarchyCLITests.setExtendedAttribute(name, value: value, at: kittyConfiguration)
  }

  func extendedAttribute(name: String) throws -> String {
    try MacarchyCLITests.extendedAttribute(name, at: kittyConfiguration)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

func decode<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(type, from: Data(output.utf8))
}

struct TeardownReport: Decodable {
  let integrations: [IntegrationReport]
}

struct IntegrationReport: Decodable {
  let id: String
  let status: String
  let target: String
  let message: String
  let mutationAttempted: Bool
}

extension IntegrationReport: IntegrationStatusResult {
  typealias IntegrationStatus = String
}

struct OwnershipManifest: Decodable {
  let schemaVersion: Int
  let records: [OwnershipRecord]
}

struct OwnershipRecord: Decodable {
  let id: String
  let phase: String
}
