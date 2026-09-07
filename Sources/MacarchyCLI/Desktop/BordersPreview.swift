import ArgumentParser
import Darwin
import Foundation
import Synchronization
import ThemeCore

struct Borders: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Preview theme-driven JankyBorders without installing a service.",
    subcommands: [Preview.self]
  )

  struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Temporarily run a focus ring from the canonical active palette."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy").path

    @Option(help: "Preview duration in seconds (1–300).")
    var seconds: Double = 30

    @Flag(help: "Inspect the palette, provider and exact arguments without starting borders.")
    var dryRun = false

    @Flag(help: "Emit a JSON plan, then JSON lifecycle events after preview cleanup.")
    var json = false

    func validate() throws {
      guard seconds.isFinite, (1...300).contains(seconds) else {
        throw ValidationError("--seconds must be between 1 and 300.")
      }
    }

    func run() throws {
      let runner = BordersPreviewRunner.live(root: URL(filePath: stateRoot))
      let emit: (BordersPreviewEvent) throws -> Void = { event in
        if json {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          print(String(decoding: try encoder.encode(event), as: UTF8.self))
        } else {
          print("\(event.event): \(event.message)")
          if let arguments = event.arguments {
            print("  borders " + arguments.joined(separator: " "))
          }
        }
        fflush(stdout)
      }
      let palette = try runner.preflight()
      try emit(.plan(palette, seconds: seconds))
      if dryRun { return }

      let events: [BordersPreviewEvent]
      do {
        let interrupted = Mutex(false)
        let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        let priorHandlers = handledSignals.map { Darwin.signal($0, SIG_IGN) }
        let signals = handledSignals.map { number in
          let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
          source.setEventHandler { interrupted.withLock { $0 = true } }
          source.resume()
          return source
        }
        defer {
          for source in signals { source.cancel() }
          for (number, handler) in zip(handledSignals, priorHandlers) {
            Darwin.signal(number, handler)
          }
        }
        // Never write to stdout while owning the child: a closed or stalled
        // output pipe must not bypass cleanup or extend the visible preview.
        events = try runner.run(
          initial: palette,
          seconds: seconds,
          shouldStop: { interrupted.withLock { $0 } }
        )
      }
      for event in events { try emit(event) }
    }
  }
}

struct BordersPalette: Equatable {
  let generationID: String
  let themeID: String
  let accent: String

  var arguments: [String] {
    [
      "active_color=0xff\(accent.dropFirst())", "inactive_color=0x00000000",
      "background_color=0x00000000", "width=4.0", "style=round", "hidpi=on", "ax_focus=off",
    ]
  }

  static func read(root: URL) throws -> Self {
    let manifest = try ReconciliationStatusStore(root: root).activeManifest()
    let theme = try JSONDecoder().decode(
      NormalizedTheme.self,
      from: BoundedRegularFile.read(
        at: root.appending(path: "generations/\(manifest.generationID)/theme.json")
      ).data
    )
    guard theme.generationID == manifest.generationID,
      theme.themeID == manifest.themeID,
      theme.schemaVersion == manifest.themeSchemaVersion
    else {
      throw ReconciliationStatusError.invalidActiveGeneration(
        "theme.json does not match the active manifest"
      )
    }
    return Self(
      generationID: manifest.generationID, themeID: manifest.themeID,
      accent: theme.semantic.accent.rawValue
    )
  }
}

struct BordersPreviewEvent: Encodable {
  let event: String
  let message: String
  var generationID: String?
  var processID: Int32?
  var arguments: [String]?

  enum CodingKeys: String, CodingKey {
    case event, message, arguments
    case generationID = "generation_id"
    case processID = "process_id"
  }

  static func plan(_ palette: BordersPalette, seconds: Double) -> Self {
    Self(
      event: "planned",
      message:
        "Preview JankyBorders 1.9.0 for \(seconds)s from '\(palette.themeID)'. Inspect the visible focus ring during the preview; lifecycle events follow cleanup. No service, configuration, permission or canonical-state changes. Existing borders must remain stopped. Native options cannot be read back; visual behavior requires confirmation.",
      generationID: palette.generationID,
      arguments: palette.arguments
    )
  }
}

enum BordersPreviewError: Error, CustomStringConvertible {
  case unavailable
  case unsupportedVersion(String)
  case incumbent(String)
  case inspectionFailed(String)
  case exited(Int32)
  case updateFailed(String)

  var description: String {
    switch self {
    case .unavailable:
      "JankyBorders is missing at /opt/homebrew/bin/borders; review installation of felixkratz/formulae/borders first."
    case .unsupportedVersion(let version):
      "Preview supports borders-v1.9.0; observed '\(version)'."
    case .incumbent(let detail):
      "Refusing to change an incumbent JankyBorders process or service: \(detail)"
    case .inspectionFailed(let detail):
      "Cannot establish that JankyBorders is stopped: \(detail)"
    case .exited(let status):
      "The preview's borders process exited unexpectedly (status \(status)); native stderr is preserved. No other process will be stopped."
    case .updateFailed(let detail):
      "JankyBorders rejected the palette update: \(detail)"
    }
  }
}

struct BordersPreviewProcess {
  let processID: Int32
  let isRunning: () -> Bool
  let terminationStatus: () -> Int32
  let stop: () -> Void

  static func start(executableURL: URL, arguments: [String]) throws -> Self {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    // Keep native diagnostics visible without mixing them into JSON events or
    // buffering a long-lived child's output in an undrained pipe.
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    try process.run()
    return Self(
      processID: process.processIdentifier,
      isRunning: { process.isRunning },
      terminationStatus: { process.terminationStatus },
      stop: {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
      }
    )
  }
}

struct BordersPreviewRunner {
  let preflight: () throws -> BordersPalette
  let pointer: () throws -> String
  let palette: () throws -> BordersPalette
  let start: ([String]) throws -> BordersPreviewProcess
  let update: ([String]) throws -> Void
  let now: () -> TimeInterval
  let wait: () -> Void

  static func live(
    root: URL,
    executable: URL = URL(filePath: "/opt/homebrew/bin/borders"),
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    processRunner: ProcessRunner = .live
  ) -> Self {
    func requireStopped() throws {
      let service = home.appending(path: "Library/LaunchAgents/homebrew.mxcl.borders.plist")
      var metadata = stat()
      if lstat(service.path, &metadata) == 0 {
        throw BordersPreviewError.incumbent(service.path)
      }
      guard errno == ENOENT else {
        throw BordersPreviewError.inspectionFailed(
          "Cannot inspect \(service.path) (errno \(errno))")
      }
      let result = try processRunner.run(
        ProcessRequest(
          executableURL: URL(filePath: "/usr/bin/pgrep"),
          arguments: ["-u", String(getuid()), "-x", "borders"], timeout: 2
        )
      )
      if result.terminationStatus == 0 { throw BordersPreviewError.incumbent(result.output) }
      guard result.terminationStatus == 1 else {
        throw BordersPreviewError.inspectionFailed(result.output)
      }
      let job = try processRunner.run(
        ProcessRequest(
          executableURL: URL(filePath: "/bin/launchctl"),
          arguments: ["print", "gui/\(getuid())/homebrew.mxcl.borders"], timeout: 2
        )
      )
      if job.terminationStatus == 0 {
        throw BordersPreviewError.incumbent("homebrew.mxcl.borders is loaded in the GUI domain")
      }
      guard job.terminationStatus == 113 else {
        throw BordersPreviewError.inspectionFailed(
          "launchctl status \(job.terminationStatus): \(job.output)")
      }
    }
    return Self(
      preflight: {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
          throw BordersPreviewError.unavailable
        }
        let version = try processRunner.run(
          ProcessRequest(executableURL: executable, arguments: ["--version"], timeout: 2)
        )
        guard version.terminationStatus == 0, version.output == "borders-v1.9.0" else {
          throw BordersPreviewError.unsupportedVersion(version.output)
        }
        try requireStopped()
        return try BordersPalette.read(root: root)
      },
      pointer: {
        try FileManager.default.destinationOfSymbolicLink(
          atPath: root.appending(path: "current").path)
      },
      palette: { try BordersPalette.read(root: root) },
      start: { arguments in
        try requireStopped()
        return try BordersPreviewProcess.start(executableURL: executable, arguments: arguments)
      },
      update: { arguments in
        let result = try processRunner.run(
          ProcessRequest(executableURL: executable, arguments: arguments, timeout: 2)
        )
        guard result.terminationStatus == 0 else {
          throw BordersPreviewError.updateFailed(result.output)
        }
      },
      now: { ProcessInfo.processInfo.systemUptime },
      wait: { Thread.sleep(forTimeInterval: 0.25) }
    )
  }

  func run(
    initial: BordersPalette,
    seconds: TimeInterval,
    shouldStop: () -> Bool
  ) throws -> [BordersPreviewEvent] {
    let process = try start(initial.arguments)
    defer { process.stop() }
    let deadline = now() + seconds
    var applied = initial
    // Distinguish a long-lived provider from a short-lived forwarding client
    // or an immediate native startup failure before reporting it as running.
    wait()
    guard process.isRunning() else { throw BordersPreviewError.exited(process.terminationStatus()) }
    var events = [
      BordersPreviewEvent(
        event: "running",
        message: "The owned preview process ran; visual behavior was not read back.",
        generationID: applied.generationID, processID: process.processID
      )
    ]
    while now() < deadline && !shouldStop() {
      guard process.isRunning() else {
        throw BordersPreviewError.exited(process.terminationStatus())
      }
      if try pointer() != "generations/\(applied.generationID)" {
        let selected = try palette()
        if selected.arguments != applied.arguments {
          try update(selected.arguments)
          guard process.isRunning() else {
            throw BordersPreviewError.exited(process.terminationStatus())
          }
        }
        applied = selected
        events.append(
          BordersPreviewEvent(
            event: "palette_requested",
            message: "Canonical palette selected; JankyBorders has no settings readback.",
            generationID: applied.generationID, processID: process.processID,
            arguments: applied.arguments
          )
        )
      }
      wait()
    }
    guard process.isRunning() else { throw BordersPreviewError.exited(process.terminationStatus()) }
    events.append(
      BordersPreviewEvent(
        event: "stopped", message: "Preview stopped; no service or configuration was installed.",
        processID: process.processID
      )
    )
    return events
  }
}
