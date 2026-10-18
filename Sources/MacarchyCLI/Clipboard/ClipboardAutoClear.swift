import Darwin
import Foundation
import ThemeCore

/// `<state root>/run/clipboard-auto-clear.json`, which exists while the automatic clear is on.
/// `lastClear` starts the rolling 24-hour window. Turning the automatic clear on and every clear
/// set it.
struct ClipboardAutoClearRecord: Codable, Equatable {
  struct Failure: Codable, Equatable {
    let date: Date
    let message: String
    /// When an alert last reported these failures.
    let alerted: Date
  }

  static let window: TimeInterval = 24 * 60 * 60
  /// Keeps a long error from pushing the record past RunStateRecord's 4 KiB limit.
  static let messageLimit = 500

  let lastClear: Date
  let lastFailure: Failure?

  static func cleared(at date: Date) -> Self {
    Self(lastClear: date, lastFailure: nil)
  }

  var nextDue: Date { lastClear.addingTimeInterval(Self.window) }

  func isDue(at now: Date) -> Bool { Self.windowHasPassed(since: lastClear, at: now) }

  /// Keeps `lastClear`, so the next hourly run tries again, and alerts at most once a window.
  func failing(_ message: String, at now: Date) -> (record: Self, alert: Bool) {
    let previous = lastFailure?.alerted
    let alert = previous.map { Self.windowHasPassed(since: $0, at: now) } ?? true
    let failure = Failure(
      date: now, message: String(message.prefix(Self.messageLimit)),
      alerted: alert ? now : previous ?? now)
    return (Self(lastClear: lastClear, lastFailure: failure), alert)
  }

  /// A clock set back more than a window before `start` also counts, so a wrong clock cannot
  /// postpone clears for long, while a small correction causes no extra clear.
  private static func windowHasPassed(since start: Date, at now: Date) -> Bool {
    now < start.addingTimeInterval(-window) || now >= start.addingTimeInterval(window)
  }
}

enum ClipboardAutoClearSwitch: String, CaseIterable {
  case on
  case off
}

enum ClipboardAutoClearChange: Equatable {
  case turnedOn
  case alreadyOn
  case turnedOff
  case alreadyOff
}

enum ClipboardAutoClearRun: Equatable {
  /// Without a record the first window starts now, and nothing is cleared.
  case windowStarted
  case notDue
  case cleared(maccyWasRunning: Bool)
  /// `lastClear` is kept. `alert` is false while an earlier alert is less than a window old.
  case failed(message: String, alert: Bool)
}

/// What has the automatic clear's launch agent name in `~/Library/LaunchAgents`.
enum ClipboardAutoClearAgentFile: Equatable {
  case absent
  /// Byte-identical to the plist Macarchy writes.
  case owned
  /// Anything else, which Macarchy never replaces, loads, unloads or deletes.
  case conflict(URL)
}

/// The launchd user agent that runs `macarchy clipboard _auto-clear` every hour. Macarchy owns
/// the plist only while it is byte-identical to what Macarchy writes for this state root and
/// executable, so no ownership record can drift from the file.
struct ClipboardAutoClearAgent {
  static let label = "io.github.ramtinj95.macarchy.clipboard-auto-clear"
  /// launchd skips the checks that fall while the Mac sleeps, so a due clear runs within about
  /// an hour of the Mac being awake.
  static let interval = 3_600

  let home: URL
  let stateRoot: URL
  /// The persistent `macarchy` entry point, which survives Homebrew upgrades.
  let executable: URL
  let userID: uid_t
  let runner: ProcessRunner

  var plistURL: URL {
    home.appending(path: "Library/LaunchAgents/\(Self.label).plist")
  }

  private var domain: String { "gui/\(userID)" }
  private var job: String { "\(domain)/\(Self.label)" }

  var conflict: ClipboardHistoryError {
    ClipboardHistoryError(
      "\(plistURL.path) is not the launch agent this Macarchy writes, so Macarchy did not change, "
        + "load or remove it. Another Macarchy build or state folder may have written it. If you "
        + "do not need it, run `launchctl bootout \(job)`, delete the file, and try again.")
  }

  func propertyList() throws -> Data {
    let run = stateRoot.appending(path: "run", directoryHint: .isDirectory)
    return try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": Self.label,
        "ProgramArguments": [
          executable.path, "clipboard", "_auto-clear", "--state-root", stateRoot.path,
        ],
        "StartInterval": Self.interval,
        "RunAtLoad": true,
        // A failed run shows its alert from a process that outlives the run. launchd would
        // otherwise end that process when the run exits.
        "AbandonProcessGroup": true,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Background",
        "StandardOutPath": run.appending(path: "clipboard-auto-clear.stdout.log").path,
        "StandardErrorPath": run.appending(path: "clipboard-auto-clear.stderr.log").path,
      ], format: .xml, options: 0)
  }

  func file() throws -> ClipboardAutoClearAgentFile {
    guard
      let parent = try PinnedFilesystem.openDirectoryIfPresent(
        at: plistURL.deletingLastPathComponent())
    else { return .absent }
    defer { Darwin.close(parent) }
    return try file(in: parent)
  }

  /// Publishes the plist when nothing has its name. Returns false when the owned plist was
  /// already there.
  func install() throws -> Bool {
    let library = try PinnedFilesystem.openDirectory(at: home.appending(path: "Library"))
    defer { Darwin.close(library) }
    let directory = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: library, name: "LaunchAgents", url: plistURL.deletingLastPathComponent(),
      mode: 0o700)
    defer { Darwin.close(directory) }
    switch try file(in: directory) {
    case .owned: return false
    case .conflict: throw conflict
    case .absent: break
    }
    let name = plistURL.lastPathComponent
    do {
      // The temporary name does not end in .plist, so launchd never loads a partial file.
      try PinnedFilesystem.publishNewRegularFile(
        try propertyList(), as: name, through: ".\(name).\(UUID().uuidString.lowercased())",
        parentDescriptor: directory, url: plistURL, mode: 0o600)
    } catch let failure as PinnedFilesystem.PublicationError {
      if failure.step == .publish, failure.code == EEXIST { throw conflict }
      throw PinnedFilesystemError(operation: "publish", url: plistURL, code: failure.code)
    }
    return true
  }

  /// Deletes the plist only while it is still the one Macarchy writes. Returns false when
  /// nothing had its name.
  func remove() throws -> Bool {
    guard
      let parent = try PinnedFilesystem.openDirectoryIfPresent(
        at: plistURL.deletingLastPathComponent())
    else { return false }
    defer { Darwin.close(parent) }
    switch try file(in: parent) {
    case .absent: return false
    case .conflict: throw conflict
    case .owned: break
    }
    guard
      let failure = PinnedStateFile.remove(
        plistURL.lastPathComponent, parentDescriptor: parent, syncWhenAbsent: false)
    else { return true }
    throw PinnedFilesystemError(
      operation: failure.step == .unlink ? "remove" : "sync the removal of", url: plistURL,
      code: failure.code)
  }

  func isLoaded() throws -> Bool {
    let result = try launchctl(["print", job])
    guard [0, 113].contains(result.terminationStatus) else {
      throw ClipboardHistoryError(
        "cannot inspect the automatic clear's launch agent: \(result.output)")
    }
    return result.terminationStatus == 0
  }

  /// Bootstraps the job unless it is loaded. Returns whether it did.
  func load() throws -> Bool {
    guard try !isLoaded() else { return false }
    let result = try launchctl(["bootstrap", domain, plistURL.path])
    guard result.terminationStatus == 0 else {
      throw ClipboardHistoryError(
        "cannot load the automatic clear's launch agent: \(result.output)")
    }
    return true
  }

  /// Boots the job out if it is loaded. Returns whether it did.
  func unload() throws -> Bool {
    guard try isLoaded() else { return false }
    let result = try launchctl(["bootout", job])
    guard result.terminationStatus == 0 else {
      throw ClipboardHistoryError(
        "cannot unload the automatic clear's launch agent: \(result.output)")
    }
    return true
  }

  private func file(in parent: Int32) throws -> ClipboardAutoClearAgentFile {
    let data: Data
    do {
      data =
        try PinnedFilesystem.readRegularFile(
          parentDescriptor: parent, name: plistURL.lastPathComponent, url: plistURL,
          maximumSize: 65_536
        ).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return .absent
    } catch {
      // A link, a folder or an unreadable file is not one Macarchy wrote.
      return .conflict(plistURL)
    }
    return data == (try propertyList()) ? .owned : .conflict(plistURL)
  }

  private func launchctl(_ arguments: [String]) throws -> ProcessResult {
    try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/launchctl"), arguments: arguments, timeout: 10))
  }
}

/// Derived from the launch agent, launchd and the record on every read; never stored.
struct ClipboardAutoClearStatus: Equatable {
  let agent: ClipboardAutoClearAgentFile
  let loaded: Bool
  let record: ClipboardAutoClearRecord?
  /// When status was read, to tell whether a clear is overdue.
  let checked: Date
}

/// What `macarchy clipboard status` reports. It holds no clipboard or history content.
struct ClipboardStatus: Equatable {
  let history: ClipboardHistoryStatus
  let autoClear: ClipboardAutoClearStatus

  var message: String { history.message + "\n" + autoClear.message }

  func renderJSON() throws -> String {
    var document = history.json
    document["autoClear"] = autoClear.json
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}

extension ClipboardAutoClearStatus {
  var message: String {
    switch agent {
    case .absent:
      return "Automatic clear is off. Run `macarchy clipboard auto-clear on` to turn it on."
    case .conflict(let url):
      return "Automatic clear is off because \(url.path) is not the launch agent this Macarchy "
        + "writes. Macarchy does not change or remove it."
    case .owned:
      var lines: [String] = [
        loaded
          ? "Automatic clear is on."
          : "Automatic clear is on, but its launch agent is not loaded, so it does not run. Run "
            + "`macarchy clipboard auto-clear on` to load it.",
        "Once 24 hours have passed since the last clear, it clears unpinned history and the "
          + "clipboard. It relies on clearOnQuit and clearSystemClipboard, which it cannot check. "
          + "Pinned items survive automatic clears.",
      ]
      guard let record else { return lines.joined(separator: "\n") }
      lines.append("Last clear: \(Self.local(record.lastClear))")
      if loaded {
        let next = record.isDue(at: checked) ? "within the hour" : Self.local(record.nextDue)
        lines.append("Next automatic clear: \(next)")
      }
      if let failure = record.lastFailure {
        lines.append(
          "Last automatic clear failed at \(Self.local(failure.date)): \(failure.message)")
      }
      return lines.joined(separator: "\n")
    }
  }

  var json: [String: Any] {
    let state =
      switch agent {
      case .absent: "off"
      case .owned: "on"
      case .conflict: "conflict"
      }
    var lastClear: Any = NSNull()
    var nextDue: Any = NSNull()
    var lastFailure: Any = NSNull()
    if let record {
      lastClear = record.lastClear.formatted(.iso8601)
      nextDue = record.nextDue.formatted(.iso8601)
      if let failure = record.lastFailure {
        lastFailure =
          ["date": failure.date.formatted(.iso8601), "message": failure.message] as [String: String]
      }
    }
    return [
      "state": state, "loaded": loaded, "lastClear": lastClear, "nextDue": nextDue,
      "overdue": record?.isDue(at: checked) ?? false, "lastFailure": lastFailure,
    ]
  }

  /// Local date and 24-hour time, since a window crosses midnight.
  private static func local(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}

extension ClipboardAutoClearChange {
  var message: String {
    switch self {
    case .turnedOn:
      "Automatic clear on. Once 24 hours have passed since the last clear, Macarchy clears unpinned "
        + "history and the clipboard. Pinned items survive it."
    case .alreadyOn: "Automatic clear was already on."
    case .turnedOff: "Automatic clear off."
    case .alreadyOff: "Automatic clear was already off."
    }
  }
}

extension ClipboardAutoClearRun {
  /// The launch agent's log line; nil when nothing happened or the run failed.
  var message: String? {
    switch self {
    case .windowStarted:
      "Automatic clear: the first 24-hour window starts now."
    case .notDue, .failed:
      nil
    case .cleared(true):
      "Automatic clear: cleared unpinned history and the clipboard. Maccy restarted."
    case .cleared(false):
      "Automatic clear: cleared unpinned history and the clipboard. Maccy was not running, so "
        + "Macarchy started it for its clear and quit it again."
    }
  }
}
