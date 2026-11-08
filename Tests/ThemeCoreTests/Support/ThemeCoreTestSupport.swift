import Foundation
import TestSupport

@testable import ThemeCore

let herdrReloadSuccess =
  #"{"id":"cli:server:reload-config","result":{"diagnostics":[],"#
  + #""status":"applied","type":"config_reload"}}"#

/// Thrown inside an exit test: the child reports the reason and exits unsuccessfully after
/// its cleanup has run.
struct ExitTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

/// Built-in theme packages are immutable values, so tests share one load of each.
enum BuiltInThemePackages {
  static let catppuccinMocha = Result { try load("catppuccin-mocha") }
  static let tokyoNight = Result { try load("tokyo-night") }

  private static func load(_ id: String) throws -> ThemePackage {
    try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(id)", directoryHint: .isDirectory))
  }
}
