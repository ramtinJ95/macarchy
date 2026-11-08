import ArgumentParser
import Foundation
import ThemeCore

struct PortableProfileOptions: ParsableArguments {
  @Option(help: "Portable Macarchy profile. Defaults to ~/.config/macarchy/profile.toml.")
  var profile: String?

  var isRequired: Bool { profile != nil }

  func url(homeDirectory: URL) -> URL {
    profile.map { URL(filePath: $0).standardizedFileURL }
      ?? StateLayout.defaultProfile(in: homeDirectory).standardizedFileURL
  }
}
