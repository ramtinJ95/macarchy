import Foundation

/// The fixed locations of the external tools Macarchy probes, runs or configures.
/// Rendered scripts and plists spell some of these paths inline as emitted bytes.
package enum ExternalTool {
  private static let homebrewPrefixPath = "/opt/homebrew"

  package static let homebrewPrefix = URL(filePath: homebrewPrefixPath)

  /// An executable linked into Homebrew's `bin`.
  package static func homebrewExecutable(_ name: String) -> URL {
    URL(filePath: "\(homebrewPrefixPath)/bin/\(name)")
  }

  package static let brew = homebrewExecutable("brew")
  /// The Homebrew-linked Macarchy entry point, not a versioned Cellar binary.
  package static let macarchy = homebrewExecutable("macarchy")

  package static let borders = homebrewExecutable("borders")
  package static let sketchybar = homebrewExecutable("sketchybar")
  package static let nowplayingCLI = homebrewExecutable("nowplaying-cli")
  package static let skhd = homebrewExecutable("skhd")
  package static let yabai = homebrewExecutable("yabai")

  package static let bat = homebrewExecutable("bat")
  package static let btop = homebrewExecutable("btop")
  package static let codex = homebrewExecutable("codex")
  package static let eza = homebrewExecutable("eza")
  package static let fzf = homebrewExecutable("fzf")
  package static let neovim = homebrewExecutable("nvim")
  package static let pi = homebrewExecutable("pi")
  package static let spicetify = homebrewExecutable("spicetify")
  package static let starship = homebrewExecutable("starship")
  package static let tuicr = homebrewExecutable("tuicr")
  package static let yazi = homebrewExecutable("yazi")
  package static let ya = homebrewExecutable("ya")
  package static let zoxide = homebrewExecutable("zoxide")

  package static let kittyApplication = URL(filePath: "/Applications/kitty.app")
  package static let slackApplication = URL(filePath: "/Applications/Slack.app")
  package static let spotifyApplication = URL(filePath: "/Applications/Spotify.app")
}
