import Darwin
import Foundation
import ThemeCore

struct OwnedLaunchAgentError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// What has a launch agent's name in `~/Library/LaunchAgents`.
enum OwnedLaunchAgentFile: Equatable {
  case absent
  /// Byte-identical to the plist Macarchy writes.
  case owned
  /// Anything else, which Macarchy never replaces, loads, unloads or deletes.
  case conflict(URL)
}

/// A launchd user agent in the login session that runs a hidden macarchy command. Macarchy owns
/// the plist only while it is byte-identical to what Macarchy writes for this state root and
/// executable, so no ownership record can drift from the file.
struct OwnedLaunchAgent {
  let label: String
  /// Names the agent in errors, such as "the automatic clear".
  let purpose: String
  let home: URL
  let stateRoot: URL
  let userID: uid_t
  let runner: ProcessRunner
  let programArguments: [String]
  /// The base name of its logs in `<state root>/run/`.
  let logName: String
  /// The plist keys beyond those every Macarchy agent has.
  let keys: [String: Any]

  var plistURL: URL {
    home.appending(path: "Library/LaunchAgents/\(label).plist")
  }

  private var domain: String { "gui/\(userID)" }
  private var job: String { "\(domain)/\(label)" }

  var conflict: OwnedLaunchAgentError {
    OwnedLaunchAgentError(
      "\(plistURL.path) is not the launch agent this Macarchy writes, so Macarchy did not change, "
        + "load or remove it. Another Macarchy build or state folder may have written it. If you "
        + "do not need it, run `launchctl bootout \(job)`, delete the file, and try again.")
  }

  func propertyList() throws -> Data {
    let run = stateRoot.appending(path: "run", directoryHint: .isDirectory)
    let shared: [String: Any] = [
      "Label": label,
      "ProgramArguments": programArguments,
      "RunAtLoad": true,
      "LimitLoadToSessionType": "Aqua",
      "StandardOutPath": run.appending(path: "\(logName).stdout.log").path,
      "StandardErrorPath": run.appending(path: "\(logName).stderr.log").path,
    ]
    // The XML encoder sorts keys, so the bytes depend only on the keys and their values.
    return try PropertyListSerialization.data(
      fromPropertyList: shared.merging(keys) { _, specific in specific }, format: .xml,
      options: 0)
  }

  func file() throws -> OwnedLaunchAgentFile {
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
      throw OwnedLaunchAgentError("cannot inspect \(purpose)'s launch agent: \(result.output)")
    }
    return result.terminationStatus == 0
  }

  /// Bootstraps the job unless it is loaded. Returns whether it did.
  func load() throws -> Bool {
    guard try !isLoaded() else { return false }
    let result = try launchctl(["bootstrap", domain, plistURL.path])
    guard result.terminationStatus == 0 else {
      throw OwnedLaunchAgentError("cannot load \(purpose)'s launch agent: \(result.output)")
    }
    return true
  }

  /// Runs the loaded job unless it is running; without -k, launchctl leaves a running job alone.
  func kickstart() throws {
    // launchd holds a kickstart for up to its 30-second throttle after a recent exit.
    let result = try launchctl(["kickstart", job], timeout: 35)
    guard result.terminationStatus == 0 else {
      throw OwnedLaunchAgentError("cannot start \(purpose)'s launch agent: \(result.output)")
    }
  }

  /// Boots the job out if it is loaded. Returns whether it did.
  func unload() throws -> Bool {
    guard try isLoaded() else { return false }
    let result = try launchctl(["bootout", job])
    guard result.terminationStatus == 0 else {
      throw OwnedLaunchAgentError("cannot unload \(purpose)'s launch agent: \(result.output)")
    }
    return true
  }

  private func file(in parent: Int32) throws -> OwnedLaunchAgentFile {
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

  private func launchctl(_ arguments: [String], timeout: TimeInterval = 10) throws
    -> ProcessResult
  {
    try runner.run(
      ProcessRequest(
        executableURL: URL(filePath: "/bin/launchctl"), arguments: arguments, timeout: timeout))
  }
}
