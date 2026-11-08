import ArgumentParser
import Foundation
import ThemeCore

/// The options of commands the action menu and the bar launch without a terminal.
struct MenuLaunchOptions: ParsableArguments {
  @Option(help: "Canonical Macarchy state directory.")
  var stateRoot = StateLayout.defaultRootPath

  @Flag(help: .hidden)
  var alertOnError = false

  var stateRootURL: URL {
    URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
  }

  /// Prints the outcome of `body`, which gets the state root. Menu and bar launches have no
  /// terminal, so they also show failures in an alert.
  @MainActor
  func run(_ failureTitle: String, _ body: (URL) throws -> String?) throws {
    do {
      if let message = try body(stateRootURL) { print(message) }
    } catch {
      if alertOnError {
        showNativeAlert(title: failureTitle, message: String(describing: error))
      }
      throw error
    }
  }
}
