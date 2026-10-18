import AppKit
import ArgumentParser
import Foundation

struct ClipboardCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clipboard",
    abstract: "Open and clear the clipboard history Maccy keeps, and save the clipboard image.",
    discussion: """
      Maccy is an optional app: brew install --cask maccy. Enabling turns on Maccy's clearOnQuit
      and clearSystemClipboard settings and records their previous values, which disabling
      restores. Enabling also turns on the automatic clear: once 24 hours have passed since the
      last clear, Macarchy clears unpinned history and the clipboard. Clearing deletes all
      history, pinned items included, and empties the clipboard. Macarchy never reads history
      content. Of these commands, only save reads the clipboard, and only its image.
      """,
    subcommands: [
      Status.self, Enable.self, Disable.self, Clear.self, Open.self, Save.self, AutoClear.self,
      RunAutoClear.self,
    ])

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
      abstract: "Show Maccy, whether clearing is enabled, and the automatic clear's state.")

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
      abstract: "Turn on Maccy's clearOnQuit and clearSystemClipboard, then the automatic clear.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Clipboard history clearing not enabled") { try $0.enableWithAutoClear() }
    }
  }

  struct Disable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Turn off the automatic clear and restore Maccy's two settings unless changed.")

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      try options.run("Clipboard history clearing not disabled") { try $0.disableWithAutoClear() }
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

  struct AutoClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "auto-clear",
      abstract: "Turn the automatic clear on or off without changing Maccy's settings.",
      discussion: """
        Once 24 hours have passed since the last clear, a Macarchy launch agent clears unpinned
        history and the clipboard. Every clear of the history restarts the 24 hours. Pinned items
        survive automatic clears. Off removes the launch agent and its record.
        """)

    @Argument var state: ClipboardAutoClearSwitch

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      let state = state
      try options.run("Automatic clipboard clear not changed") {
        try $0.setAutoClear(state).message
      }
    }
  }

  /// The launch agent's hourly run. Nobody reads its log, so a failure shows an alert.
  struct RunAutoClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_auto-clear", shouldDisplay: false)

    /// Shows the alert for this failure instead of running; a failed run starts itself this way.
    @Option(help: .hidden) var alert: String?

    @OptionGroup var options: Options

    @MainActor
    mutating func run() async throws {
      if let alert {
        Self.show(alert)
        return
      }
      let outcome: ClipboardAutoClearRun
      do {
        outcome = try options.engine.runAutoClear()
      } catch {
        // Nothing succeeds until someone acts on this error. launchd skips the hourly runs while
        // this alert waits, so alerts never pile up.
        Self.show(String(describing: error))
        throw error
      }
      if let message = outcome.message { print(message) }
      guard case .failed(let message, let needsAlert) = outcome else { return }
      if needsAlert { showSeparately(message) }
      throw ClipboardHistoryError(message)
    }

    /// The next hourly run may succeed, and launchd skips it while this run waits on an alert,
    /// so the alert shows in a separate process. The plist's AbandonProcessGroup keeps launchd
    /// from stopping that process when this run exits.
    @MainActor
    private func showSeparately(_ failure: String) {
      let process = Process()
      process.executableURL = RuntimeEnvironment.live.executableURL
      process.arguments = [
        "clipboard", "_auto-clear", "--state-root", options.stateRoot, "--alert=\(failure)",
      ]
      do {
        try process.run()
      } catch {
        Self.show(failure)
      }
    }

    @MainActor
    private static func show(_ failure: String) {
      showNativeAlert(
        title: "Automatic clipboard clear failed",
        message: (failure.hasSuffix(".") ? failure : failure + ".")
          + " Run `macarchy clipboard clear` to clear now.")
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

  struct Save: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Save the clipboard image to a new file, or write it to standard output.",
      discussion: """
        Saves the image on the clipboard now, so pick an older item in Maccy's history first.
        Works without Maccy. For text, use pbpaste.
        The file's extension picks the format: .png, .jpg or .jpeg, .tiff or .tif, or .heic. When
        the clipboard holds that format, its bytes are saved unchanged; otherwise the image is
        converted at its own size. The file must not exist and its folder must. With -, the image
        goes to standard output, as PNG unless --format says otherwise, and never to a terminal.
        """)

    @Argument(help: "A new image file, or - for standard output.")
    var output: String

    @Option(help: "The format written to standard output. Default: png.")
    var format: ClipboardImageFormat?

    @Flag(help: "Emit machine-readable output.")
    var json = false

    var destination: ClipboardSaveDestination {
      guard output != "-" else { return .standardOutput(format ?? .png) }
      return .file(URL(filePath: output).standardizedFileURL)
    }

    mutating func validate() throws {
      if output.isEmpty { throw ValidationError("The output path is empty.") }
      if output == "-", json {
        throw ValidationError("--json applies only when saving to a file.")
      }
      if output != "-", format != nil {
        throw ValidationError("--format applies only to -; a file's extension picks its format.")
      }
    }

    @MainActor
    mutating func run() async throws {
      let destination = destination
      let saved = try ClipboardImageSaver.live.save(to: destination)
      if case .file(let url) = destination {
        print(try json ? saved.renderJSON(savedTo: url) : saved.message(savedTo: url))
      }
    }
  }
}

extension ClipboardAutoClearSwitch: ExpressibleByArgument {}
