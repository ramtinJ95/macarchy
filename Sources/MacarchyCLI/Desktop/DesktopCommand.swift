import ArgumentParser
import Foundation

struct Desktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Plan and manage the default desktop providers.",
    subcommands: [Plan.self]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan managed yabai desktop configuration without making changes."
    )

    @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
    var profile: String?

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL =
        profile.map { URL(filePath: $0).standardizedFileURL }
        ?? home.appending(path: ".config/macarchy/profile.toml").standardizedFileURL
      let execution = try DesktopPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profile != nil,
        homeDirectory: home,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }
}
