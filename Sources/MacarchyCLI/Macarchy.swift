import ArgumentParser
import Foundation
import ThemeCore

@main
struct Macarchy: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macarchy",
    abstract: "A cohesive, theme-driven macOS environment.",
    subcommands: [
      Theme.self, Keybindings.self, Desktop.self, Reconcile.self, Doctor.self, Setup.self,
      Teardown.self, Update.self, Version.self,
    ]
  )

  @Flag(name: .customLong("version"), help: "Show version and exit.")
  var showVersion = false

  mutating func run() async throws {
    guard showVersion else { throw CleanExit.helpRequest(self) }
    print(try VersionCommandRunner.live.executeConcise())
  }

  struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show version and installation information."
    )

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      print(try VersionCommandRunner.live.execute(json: json))
    }
  }

  struct StateOptions: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Option(help: "Kitty configuration file.")
    var kittyConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/kitty/kitty.conf").path

    @Option(help: "SketchyBar entry configuration file.")
    var sketchyBarConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/sketchybar/sketchybarrc").path

    @Option(help: "Shell configuration file.")
    var shellConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".zshrc").path

    @Option(help: "eza configuration directory.")
    var ezaConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/eza", directoryHint: .isDirectory).path

    @Option(help: "bat configuration directory.")
    var batConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/bat", directoryHint: .isDirectory).path

    @Option(help: "bat cache directory.")
    var batCacheDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".cache/bat", directoryHint: .isDirectory).path

    @Option(help: "btop configuration directory.")
    var btopConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/btop", directoryHint: .isDirectory).path

    @Option(help: "Yazi configuration directory.")
    var yaziConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/yazi", directoryHint: .isDirectory).path

    @Option(help: "Atuin configuration directory.")
    var atuinConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/atuin", directoryHint: .isDirectory).path

    @Option(help: "Neovim configuration directory.")
    var neovimConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/nvim", directoryHint: .isDirectory).path

    @Option(help: "Starship configuration file.")
    var starshipConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/starship.toml").path

    @Option(help: "Starship behavior source file.")
    var starshipBehavior = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/starship/behavior.toml").path

    @Option(help: "Pi configuration directory.")
    var piConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".pi/agent", directoryHint: .isDirectory).path

    @Option(help: "Herdr configuration file.")
    var herdrConfig = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/herdr/config.toml").path

    @Option(help: "tuicr configuration directory.")
    var tuicrConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/tuicr", directoryHint: .isDirectory).path

    @Option(help: "Codex configuration directory.")
    var codexConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex", directoryHint: .isDirectory).path

    @Option(help: "Spicetify configuration directory.")
    var spicetifyConfigDir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/spicetify", directoryHint: .isDirectory).path

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    var consumerPaths: ThemeConsumerPaths {
      ThemeConsumerPaths(
        kittyConfigurationURL: URL(filePath: kittyConfig),
        sketchyBarConfigurationURL: URL(filePath: sketchyBarConfig),
        shellConfigurationURL: URL(filePath: shellConfig).resolvingSymlinksInPath(),
        ezaConfigurationDirectoryURL: URL(filePath: ezaConfigDir, directoryHint: .isDirectory),
        batConfigurationDirectoryURL: URL(filePath: batConfigDir, directoryHint: .isDirectory),
        batCacheDirectoryURL: URL(filePath: batCacheDir, directoryHint: .isDirectory),
        btopConfigurationDirectoryURL: URL(
          filePath: btopConfigDir, directoryHint: .isDirectory),
        yaziConfigurationDirectoryURL: URL(
          filePath: yaziConfigDir, directoryHint: .isDirectory),
        atuinConfigurationDirectoryURL: URL(
          filePath: atuinConfigDir, directoryHint: .isDirectory),
        neovimConfigurationDirectoryURL: URL(
          filePath: neovimConfigDir, directoryHint: .isDirectory),
        starshipConfigurationURL: URL(filePath: starshipConfig),
        starshipBehaviorURL: URL(filePath: starshipBehavior),
        piConfigurationDirectoryURL: URL(
          filePath: piConfigDir, directoryHint: .isDirectory),
        herdrConfigurationURL: URL(filePath: herdrConfig),
        tuicrConfigurationDirectoryURL: URL(
          filePath: tuicrConfigDir, directoryHint: .isDirectory),
        codexConfigurationDirectoryURL: URL(
          filePath: codexConfigDir, directoryHint: .isDirectory),
        spicetifyConfigurationDirectoryURL: URL(
          filePath: spicetifyConfigDir, directoryHint: .isDirectory)
      )
    }
  }

}
