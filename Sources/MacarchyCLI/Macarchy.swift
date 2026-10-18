import ArgumentParser
import Foundation
import ThemeCore

@main
struct Macarchy: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macarchy",
    abstract: "A cohesive, theme-driven macOS environment.",
    subcommands: [
      Theme.self, Keybindings.self, Desktop.self, EnvironmentCommand.self, PreferencesCommand.self,
      Reconcile.self, ActionMenu.self, CaptureCommand.self, ImageCommand.self,
      ClipboardCommand.self, KeepAwakeCommand.self, MicrophoneCommand.self, MenuMaintenance.self,
      MenuProfileEditor.self,
      MenuProfileSave.self, MenuNeovimEditor.self, MenuConfigurationEditor.self,
      MenuConfigurationValidate.self,
      Doctor.self, Setup.self, Teardown.self, Update.self, Version.self,
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
    var stateRoot = homePath(".config/macarchy", directory: true)

    @Option(help: "Kitty configuration file.")
    var kittyConfig = homePath(".config/kitty/kitty.conf")

    @Option(help: "SketchyBar entry configuration file.")
    var sketchyBarConfig = homePath(".config/sketchybar/sketchybarrc")

    @Option(help: "Shell configuration file.")
    var shellConfig = homePath(".zshrc")

    @Option(help: "eza configuration directory.")
    var ezaConfigDir = homePath(".config/eza", directory: true)

    @Option(help: "bat configuration directory.")
    var batConfigDir = homePath(".config/bat", directory: true)

    @Option(help: "bat cache directory.")
    var batCacheDir = homePath(".cache/bat", directory: true)

    @Option(help: "btop configuration directory.")
    var btopConfigDir = homePath(".config/btop", directory: true)

    @Option(help: "Yazi configuration directory.")
    var yaziConfigDir = homePath(".config/yazi", directory: true)

    @Option(help: "Atuin configuration directory.")
    var atuinConfigDir = homePath(".config/atuin", directory: true)

    @Option(help: "Neovim configuration directory.")
    var neovimConfigDir = homePath(".config/nvim", directory: true)

    @Option(help: "Starship configuration file.")
    var starshipConfig = homePath(".config/starship.toml")

    @Option(help: "Starship behavior source file.")
    var starshipBehavior = homePath(".config/starship/behavior.toml")

    @Option(help: "Pi configuration directory.")
    var piConfigDir = homePath(".pi/agent", directory: true)

    @Option(help: "Herdr configuration file.")
    var herdrConfig = homePath(".config/herdr/config.toml")

    @Option(help: "tuicr configuration directory.")
    var tuicrConfigDir = homePath(".config/tuicr", directory: true)

    @Option(help: "Codex configuration directory.")
    var codexConfigDir = homePath(".codex", directory: true)

    @Option(help: "Spicetify configuration directory.")
    var spicetifyConfigDir = homePath(".config/spicetify", directory: true)

    var stateRootURL: URL {
      URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
    }

    var consumerPaths: ThemeConsumerPaths {
      ThemeConsumerPaths(
        kittyConfigurationURL: URL(filePath: kittyConfig),
        sketchyBarConfigurationURL: URL(filePath: sketchyBarConfig),
        shellConfigurationURL: URL(filePath: shellConfig),
        ezaConfigurationDirectoryURL: directoryURL(ezaConfigDir),
        batConfigurationDirectoryURL: directoryURL(batConfigDir),
        batCacheDirectoryURL: directoryURL(batCacheDir),
        btopConfigurationDirectoryURL: directoryURL(btopConfigDir),
        yaziConfigurationDirectoryURL: directoryURL(yaziConfigDir),
        atuinConfigurationDirectoryURL: directoryURL(atuinConfigDir),
        neovimConfigurationDirectoryURL: directoryURL(neovimConfigDir),
        starshipConfigurationURL: URL(filePath: starshipConfig),
        starshipBehaviorURL: URL(filePath: starshipBehavior),
        piConfigurationDirectoryURL: directoryURL(piConfigDir),
        herdrConfigurationURL: URL(filePath: herdrConfig),
        tuicrConfigurationDirectoryURL: directoryURL(tuicrConfigDir),
        codexConfigurationDirectoryURL: directoryURL(codexConfigDir),
        spicetifyConfigurationDirectoryURL: directoryURL(spicetifyConfigDir)
      )
    }
  }

}

/// A path under the current user's home directory, as a command-line option default.
private func homePath(_ relative: String, directory: Bool = false) -> String {
  FileManager.default.homeDirectoryForCurrentUser
    .appending(path: relative, directoryHint: directory ? .isDirectory : .inferFromPath).path
}

private func directoryURL(_ path: String) -> URL {
  URL(filePath: path, directoryHint: .isDirectory)
}
