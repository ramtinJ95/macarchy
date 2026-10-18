import AppKit
import Darwin
import Foundation
import ThemeCore

/// The two Maccy settings Macarchy turns on, so quitting Maccy clears its history and the
/// clipboard.
enum MaccySetting: String, CaseIterable, Codable, CodingKeyRepresentable {
  case clearOnQuit
  case clearSystemClipboard
}

/// What Macarchy can observe about Maccy without reading its history.
enum MaccyInstallation: Equatable {
  case missing
  case installed(version: String)

  var isSupported: Bool { self == .installed(version: MaccyApp.supportedVersion) }
}

/// A running Maccy process, identified by its start time so a reused PID is never mistaken
/// for it.
struct RunningMaccy: Equatable {
  let pid: Int32
  let started: UInt64
}

enum MaccyLaunch: Equatable {
  /// Starts Maccy without bringing it forward.
  case background
  /// Reopens Maccy, which shows its history popup when it is already running.
  case history
}

/// The installed Maccy app as Macarchy observes and drives it.
struct MaccyApp {
  static let bundleIdentifier = "org.p0deje.Maccy"
  /// The only version whose storage layout Macarchy knows.
  static let supportedVersion = "2.7.1"

  let installation: () -> MaccyInstallation
  let instances: () throws -> [RunningMaccy]
  /// Asks Maccy to quit normally, which runs its own clear-on-quit.
  let quit: (RunningMaccy) -> Void
  let isAlive: (RunningMaccy) -> Bool
  let open: (MaccyLaunch) throws -> Void
}

/// Maccy's preferences, read and written through `/usr/bin/defaults`, which reaches the
/// sandbox container Maccy reads. In-process CFPreferences would write a different file.
struct MaccyDefaults {
  /// nil when the setting is not set. A value that is not a Boolean throws.
  let read: (MaccySetting) throws -> Bool?
  /// nil deletes the setting.
  let write: (MaccySetting, Bool?) throws -> Void
}

/// Maccy 2.7.1's history store and Shortcuts image export inside its sandbox container.
struct MaccyStorage {
  static let storeDirectory = "Library/Application Support/Maccy"
  /// Every file a full clear deletes, by directory relative to the container.
  static let historyFiles: [(directory: String, names: [String])] = [
    // The log files go first, so a failure partway never leaves a log beside a new database.
    (storeDirectory, ["Storage.sqlite-wal", "Storage.sqlite-shm", "Storage.sqlite"]),
    ("Documents", ["image.png"]),
  ]

  /// The container's `Data` directory.
  let root: URL
  /// The `S_IFMT` bits of `name` in `parent`, never following a symlink; nil when nothing is
  /// there.
  let fileType: (_ parent: Int32, _ name: String, _ url: URL) throws -> mode_t?
  /// A descriptor for the directory, or nil when it does not exist.
  var openDirectory: (URL) throws -> Int32? = {
    try PinnedFilesystem.openDirectoryIfPresent(at: $0)
  }

  /// Maccy creates its container on first launch; settings written before then may not reach it.
  func containerExists() throws -> Bool {
    try isDirectory(root)
  }

  /// Fails when macOS refuses access to the preferences `defaults` reads inside the container.
  func checkPreferencesAccess() throws {
    _ = try isDirectory(root.appending(path: "Library/Preferences", directoryHint: .isDirectory))
  }

  /// False when the container exists without the store directory, a layout Macarchy does not
  /// know. A missing container holds no history.
  func recognizesLayout() throws -> Bool {
    guard try containerExists() else { return true }
    return try isDirectory(root.appending(path: Self.storeDirectory, directoryHint: .isDirectory))
  }

  /// Deletes every history file that exists, or none when any of them is not a regular file.
  func removeHistory() throws {
    var directories: [Int32] = []
    defer {
      for descriptor in directories { Darwin.close(descriptor) }
    }
    var files: [(parent: Int32, name: String, url: URL)] = []
    for (directory, names) in Self.historyFiles {
      let directoryURL = root.appending(path: directory, directoryHint: .isDirectory)
      guard let parent = try openDirectory(directoryURL) else {
        continue
      }
      directories.append(parent)
      for name in names {
        let url = directoryURL.appending(path: name)
        guard let type = try fileType(parent, name, url) else { continue }
        guard type == S_IFREG else {
          throw ClipboardHistoryError(
            "\(url.path) is \(Self.describe(type)), not a regular file, so Macarchy deleted none "
              + "of Maccy's history files")
        }
        files.append((parent, name, url))
      }
    }
    for file in files {
      guard file.name.withCString({ Darwin.unlinkat(file.parent, $0, 0) }) == 0 || errno == ENOENT
      else {
        throw PinnedFilesystemError(operation: "delete", url: file.url, code: errno)
      }
    }
  }

  private func isDirectory(_ url: URL) throws -> Bool {
    guard let descriptor = try openDirectory(url) else { return false }
    Darwin.close(descriptor)
    return true
  }

  private static func describe(_ type: mode_t) -> String {
    switch type {
    case S_IFLNK: "a symbolic link"
    case S_IFDIR: "a directory"
    default: "a special file"
    }
  }
}

extension MaccyApp {
  static var live: Self {
    Self(
      installation: {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return .missing }
        let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return .installed(version: version ?? "unknown")
      },
      instances: {
        try NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
          .compactMap { app -> RunningMaccy? in
            let pid = app.processIdentifier
            if let started = processStartTime(pid) {
              return RunningMaccy(pid: pid, started: started)
            }
            // A live Maccy that cannot be identified must not have its store deleted beneath it.
            guard kill(pid, 0) != 0, errno == ESRCH else {
              throw ClipboardHistoryError("cannot identify the running Maccy (pid \(pid))")
            }
            return nil
          }
      },
      quit: { _ = NSRunningApplication(processIdentifier: $0.pid)?.terminate() },
      // The kernel, not NSRunningApplication, which updates only while a run loop runs.
      isAlive: { processStartTime($0.pid) == $0.started },
      open: { launch in
        // LaunchServices starts Maccy with stderr at /dev/null, where Maccy logs item titles.
        let arguments =
          switch launch {
          case .background: ["-g", "-b", bundleIdentifier]
          case .history: ["-b", bundleIdentifier]
          }
        let result = try ProcessRunner.live.run(
          .init(executableURL: URL(filePath: "/usr/bin/open"), arguments: arguments, timeout: 10))
        guard result.terminationStatus == 0 else {
          throw ClipboardHistoryError("cannot open Maccy: \(result.output)")
        }
      })
  }
}

extension MaccyDefaults {
  static var live: Self {
    func run(_ verb: String, _ setting: MaccySetting, _ value: [String] = []) throws
      -> ProcessResult
    {
      do {
        // Long enough to answer the macOS permission dialog the first access can raise.
        return try ProcessRunner.live.run(
          .init(
            executableURL: URL(filePath: "/usr/bin/defaults"),
            arguments: [verb, MaccyApp.bundleIdentifier, setting.rawValue] + value, timeout: 120))
      } catch is ProcessRunnerError {
        throw ClipboardHistoryError.appDataPermission(
          "Maccy's \(setting.rawValue) setting did not answer within two minutes")
      }
    }
    return Self(
      read: { setting in
        let type = try run("read-type", setting)
        let value = try type.terminationStatus == 0 ? run("read", setting) : nil
        return try parse(setting, type: type, value: value)
      },
      write: { setting, value in
        let flag = value.map { ["-bool", $0 ? "true" : "false"] }
        let result = try run(flag == nil ? "delete" : "write", setting, flag ?? [])
        guard result.terminationStatus == 0 || (value == nil && isAbsent(result)) else {
          throw ClipboardHistoryError(
            "cannot change Maccy's \(setting.rawValue) setting: \(result.output)")
        }
      })
  }

  /// One setting from `defaults read-type` and, when that succeeds, `defaults read`.
  static func parse(_ setting: MaccySetting, type: ProcessResult, value: ProcessResult?) throws
    -> Bool?
  {
    if type.terminationStatus != 0, isAbsent(type) { return nil }
    guard type.terminationStatus == 0, let value, value.terminationStatus == 0 else {
      throw ClipboardHistoryError(
        "cannot read Maccy's \(setting.rawValue) setting: \(value?.output ?? type.output)")
    }
    guard type.output == "Type is boolean", ["0", "1"].contains(value.output) else {
      throw ClipboardHistoryError(
        "Maccy's \(setting.rawValue) setting is not a Boolean (\(type.output)), so Macarchy will "
          + "not change it. Reset it in Maccy's settings first.")
    }
    return value.output == "1"
  }

  private static func isAbsent(_ result: ProcessResult) -> Bool {
    result.output.contains("does not exist")
  }
}

extension MaccyStorage {
  static func live(home: URL) -> Self {
    Self(
      root: home.appending(
        path: "Library/Containers/\(MaccyApp.bundleIdentifier)/Data", directoryHint: .isDirectory),
      fileType: liveFileType)
  }

  static func liveFileType(parent: Int32, name: String, url: URL) throws -> mode_t? {
    do {
      return try PinnedFilesystem.metadata(parentDescriptor: parent, name: name, url: url).st_mode
        & S_IFMT
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return nil
    }
  }
}
