import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

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
    stateRoot.appending(path: "current/\(BatAdapter.outputPath)")
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
    stateRoot.appending(path: "current/\(YaziAdapter.syntaxOutputPath)")
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
    let data = Data(value.utf8)
    let result = data.withUnsafeBytes { bytes in
      kittyConfiguration.path.withCString { path in
        name.withCString { attribute in
          Darwin.setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  func extendedAttribute(name: String) throws -> String {
    let size = kittyConfiguration.path.withCString { path in
      name.withCString { attribute in
        Darwin.getxattr(path, attribute, nil, 0, 0, 0)
      }
    }
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { bytes in
      kittyConfiguration.path.withCString { path in
        name.withCString { attribute in
          Darwin.getxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return String(decoding: data, as: UTF8.self)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
