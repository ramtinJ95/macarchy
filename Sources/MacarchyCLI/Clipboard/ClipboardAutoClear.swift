import Darwin
import Foundation
import ThemeCore

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
