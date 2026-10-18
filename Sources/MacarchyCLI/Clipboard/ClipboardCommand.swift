import AppKit
import ArgumentParser
import Foundation

struct ClipboardCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clipboard",
    abstract: "Open and fully clear the clipboard history Maccy keeps.",
    discussion: """
      Maccy is an optional app: brew install --cask maccy. Enabling turns on Maccy's clearOnQuit
      and clearSystemClipboard settings and records their previous values, which disabling
      restores. Clearing deletes all history, pinned items included, and empties the clipboard.
      Macarchy never reads clipboard or history content.
      """,
    subcommands: [Status.self, Enable.self, Disable.self, Clear.self, Open.self])

  static let defaultStateRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

  struct Options: ParsableArguments {
    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = ClipboardCommand.defaultStateRoot

    @Flag(help: .hidden)
    var alertOnError = false

    var engine: ClipboardHistory {
      ClipboardHistory.live(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL)
    }

    /// Prints the outcome. Menu launches have no terminal, so they also show failures in an alert.
    @MainActor
    func run(_ failureTitle: String, _ body: (ClipboardHistory) throws -> String) throws {
      do {
        print(try body(engine))
      } catch {
        if alertOnError {
          showNativeAlert(title: failureTitle, message: String(describing: error))
        }
        throw error
      }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show whether Maccy is installed and running and whether clearing is enabled.")

    @Flag(help: "Emit machine-readable output.")
    var json = false

    @OptionGroup var options: Options

    mutating func run() throws {
      let status = try options.engine.status()
      print(try json ? status.renderJSON() : status.message)
    }
  }

  struct Enable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Turn on Maccy's clearOnQuit and clearSystemClipboard, recording their values.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Clipboard history clearing not enabled") { try $0.enable().message }
    }
  }

  struct Disable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore Maccy's two settings unless changed since; history is kept.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Clipboard history clearing not disabled") { try $0.disable().message }
    }
  }

  struct Clear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete all clipboard history, including pinned items, and empty the clipboard.",
      discussion: """
        A running Maccy quits, so its own clear runs, and starts again in the background. When
        Maccy is not version 2.7.1, or its storage is not where 2.7.1 keeps it, Macarchy deletes
        no files. Pinned items may then remain, and the command exits nonzero.
        """)

    @Flag(help: .hidden)
    var confirm = false

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      let confirm = confirm
      try options.run("Clipboard history not cleared") { engine in
        if confirm {
          let unknown = try engine.checkClearable()
          let title =
            unknown == nil
            ? "Clear all clipboard history, including pinned items?"
            : "Clear unpinned clipboard history?"
          let warning = unknown.map { "Pinned items may remain because \($0.explanation). " } ?? ""
          guard
            showNativeConfirmation(
              title: title, message: warning + "This cannot be undone.", action: "Clear")
          else { return "Clipboard history not cleared." }
        }
        return try engine.clear().report()
      }
    }
  }

  struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show Maccy's clipboard history, starting Maccy when it is not running.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      let menu = options.alertOnError
      try options.run("Clipboard history not opened") { engine in
        let opening = try engine.open()
        if menu, opening == .started {
          showNativeAlert(title: "Maccy started", message: opening.message, style: .informational)
        }
        return opening.message
      }
    }
  }
}
