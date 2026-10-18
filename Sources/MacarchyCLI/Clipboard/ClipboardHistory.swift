import AppKit
import Foundation
import ThemeCore

/// Macarchy's record of the Maccy settings it changed, so disable can restore them.
struct MaccySettingsRecord: Codable, Equatable {
  /// Each setting's value before the first enable; nil when it was not set.
  let previous: [MaccySetting: Bool?]
}

/// Derived from Maccy, its settings and Macarchy's record on every read; never stored. It
/// holds no clipboard or history content.
struct ClipboardHistoryStatus: Equatable {
  let installation: MaccyInstallation
  let running: Bool
  /// Macarchy's settings record exists.
  let recorded: Bool
  let settings: [MaccySetting: Bool?]

  /// Recorded settings that no longer hold the value Macarchy set.
  var changed: [MaccySetting] {
    recorded ? MaccySetting.allCases.filter { (settings[$0] ?? nil) != true } : []
  }

  var enabled: Bool { recorded && changed.isEmpty }
}

enum ClipboardIntegrationChange: Equatable {
  case enabled
  case alreadyEnabled
  /// `kept` lists the settings changed in Maccy after enable; they keep that value.
  case disabled(kept: [MaccySetting])
  case alreadyDisabled
}

/// Why Macarchy cannot find Maccy's history store, so a clear deletes no file.
enum MaccyStoreUnknown: Equatable {
  case unsupportedVersion(String)
  case missingStoreDirectory
}

enum ClipboardHistoryClear: Equatable {
  /// Every history file is gone and the clipboard is empty.
  case cleared(maccyWasRunning: Bool)
  /// No file was deleted. Only Maccy's own clear-on-quit, when it was running, and the
  /// clipboard were cleared, so pinned items may remain.
  case clearedUnpinnedOnly(maccyWasRunning: Bool, reason: MaccyStoreUnknown)
}

enum MaccyOpening: Equatable {
  case history
  /// Maccy was not running; starting it does not show the history.
  case started
}

struct ClipboardHistoryError: Error, CustomStringConvertible {
  static let maccyMissing = Self(
    "Maccy is not installed. Install it with: brew install --cask maccy")

  /// macOS asks before a process started from one app reads another app's sandbox container.
  static func appDataPermission(_ detail: String) -> Self {
    Self(
      "\(detail). macOS lets Macarchy reach Maccy's settings and history only after you allow "
        + "\"access data from other apps\" for the app you run it from, such as Kitty. Allow it in "
        + "the dialog macOS shows, or give that app Full Disk Access in System Settings › Privacy "
        + "& Security, then try again.")
  }

  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Opens and fully clears the clipboard history Maccy keeps. Macarchy owns only the two
/// settings it turns on and its record of their previous values. It deletes Maccy's history
/// files but never reads them.
struct ClipboardHistory {
  /// With the live 50 ms pause, about five seconds for Maccy to quit.
  static let exitPolls = 100
  private static let lock = ProcessScopedFileLock<ClipboardHistoryError>(
    filename: "clipboard.lock",
    cannotCreateRunDirectory: { url, error in
      ClipboardHistoryError("cannot create \(url.path): \(error)")
    },
    operationError: { operation, code in
      ClipboardHistoryError("cannot \(operation) the clipboard lock (errno \(code))")
    })

  let stateRoot: URL
  let maccy: MaccyApp
  let defaults: MaccyDefaults
  let storage: MaccyStorage
  let clearPasteboard: () -> Void
  let pause: () -> Void

  /// `<state root>/run/clipboard-maccy-settings.json`.
  static func settingsRecord(stateRoot: URL) -> RunStateRecord<MaccySettingsRecord> {
    RunStateRecord("clipboard-maccy-settings.json", stateRoot: stateRoot) {
      Set($0.previous.keys) == Set(MaccySetting.allCases)
    }
  }

  private var record: RunStateRecord<MaccySettingsRecord> {
    Self.settingsRecord(stateRoot: stateRoot)
  }

  func status() throws -> ClipboardHistoryStatus {
    try Self.lock.withLock(root: stateRoot) { try current() }
  }

  /// Records both settings' values, then turns both on. An existing record keeps the values
  /// from before the first enable.
  func enable() throws -> ClipboardIntegrationChange {
    try Self.lock.withLock(root: stateRoot) { () throws -> ClipboardIntegrationChange in
      _ = try installedVersion()
      guard try Self.reachingContainer({ try storage.containerExists() }) else {
        throw ClipboardHistoryError(
          "Maccy has not run yet, so the settings Macarchy changes would not reach it. Open "
            + "Maccy once, then run `macarchy clipboard enable` again.")
      }
      let recorded = try readRecord() != nil
      let settings = try readSettings()
      if !recorded { try record.write(MaccySettingsRecord(previous: settings)) }
      let off = MaccySetting.allCases.filter { (settings[$0] ?? nil) != true }
      for setting in off { try defaults.write(setting, true) }
      return recorded && off.isEmpty ? .alreadyEnabled : .enabled
    }
  }

  /// Restores each setting that still holds Macarchy's value; one changed in Maccy since keeps
  /// that change. History is never touched.
  func disable() throws -> ClipboardIntegrationChange {
    try Self.lock.withLock(root: stateRoot) { () throws -> ClipboardIntegrationChange in
      _ = try installedVersion()
      guard let saved = try readRecord() else { return .alreadyDisabled }
      // A denied read would see both settings unset and drop the only record of their values.
      try Self.reachingContainer { try storage.checkPreferencesAccess() }
      var kept: [MaccySetting] = []
      for setting in MaccySetting.allCases {
        let current = try defaults.read(setting)
        let previous: Bool? = saved.previous[setting] ?? nil
        // Already back, for example after a disable that failed partway.
        if current == previous { continue }
        guard current == true else {
          kept.append(setting)
          continue
        }
        try defaults.write(setting, previous)
      }
      try record.remove()
      return .disabled(kept: kept)
    }
  }

  /// Throws the reason a clear cannot run, so the menu can report it before asking to confirm.
  /// Returns why pinned items would remain, if they would.
  func checkClearable() throws -> MaccyStoreUnknown? {
    try Self.lock.withLock(root: stateRoot) { try unknownStore(version: try clearableVersion()) }
  }

  /// Deletes all of Maccy's history, pinned items included, and empties the clipboard. A
  /// running Maccy quits first, which runs its own clear-on-quit and closes its store, and
  /// starts again afterwards in the background. Without a known storage layout no file is
  /// deleted.
  func clear() throws -> ClipboardHistoryClear {
    try Self.lock.withLock(root: stateRoot) { () throws -> ClipboardHistoryClear in
      let unknown = try unknownStore(version: try clearableVersion())
      let instances = try maccy.instances()
      let wasRunning = !instances.isEmpty
      if wasRunning { try quit(instances) }
      if unknown == nil {
        // Maccy can start again meanwhile, from the Dock or a login item; never delete under it.
        guard try maccy.instances().isEmpty else {
          throw ClipboardHistoryError(
            "Maccy started again during the clear, so Macarchy deleted nothing. Quit Maccy's "
              + "other copy or wait a moment, then clear again.")
        }
        do {
          try Self.reachingContainer { try storage.removeHistory() }
        } catch {
          throw restarting(wasRunning, after: error)
        }
      }
      clearPasteboard()
      if wasRunning {
        do {
          try maccy.open(.background)
        } catch {
          throw ClipboardHistoryError(
            "Restarting Maccy after the clear failed: \(error). Open Maccy yourself.")
        }
      }
      guard let unknown else { return .cleared(maccyWasRunning: wasRunning) }
      return .clearedUnpinnedOnly(maccyWasRunning: wasRunning, reason: unknown)
    }
  }

  /// Shows Maccy's history popup, or starts Maccy when it is not running.
  func open() throws -> MaccyOpening {
    // Waits for a clear in progress, so opening cannot start Maccy beneath its deletion.
    try Self.lock.withLock(root: stateRoot) { () throws -> MaccyOpening in
      _ = try installedVersion()
      let running = try !maccy.instances().isEmpty
      try maccy.open(.history)
      return running ? .history : .started
    }
  }

  private func current() throws -> ClipboardHistoryStatus {
    ClipboardHistoryStatus(
      installation: maccy.installation(), running: try !maccy.instances().isEmpty,
      recorded: try readRecord() != nil, settings: try readSettings())
  }

  private func installedVersion() throws -> String {
    guard case .installed(let version) = maccy.installation() else {
      throw ClipboardHistoryError.maccyMissing
    }
    return version
  }

  private func clearableVersion() throws -> String {
    let version = try installedVersion()
    let status = try current()
    guard status.enabled else {
      if status.changed.isEmpty {
        throw ClipboardHistoryError(
          "Clipboard history clearing is not enabled, so nothing was cleared. Run "
            + "`macarchy clipboard enable` first.")
      }
      throw ClipboardHistoryError(
        "\(MaccySetting.list(status.changed)) changed in Maccy after Macarchy enabled clearing, "
          + "so nothing was cleared. Run `macarchy clipboard enable` to turn clearing back on.")
    }
    return version
  }

  private func unknownStore(version: String) throws -> MaccyStoreUnknown? {
    guard version == MaccyApp.supportedVersion else { return .unsupportedVersion(version) }
    return try Self.reachingContainer { try storage.recognizesLayout() }
      ? nil : .missingStoreDirectory
  }

  private func readSettings() throws -> [MaccySetting: Bool?] {
    // Without access, `defaults` would read and write a preferences file Maccy never reads.
    try Self.reachingContainer { try storage.checkPreferencesAccess() }
    return try Dictionary(
      uniqueKeysWithValues: MaccySetting.allCases.map { ($0, try defaults.read($0)) })
  }

  private func readRecord() throws -> MaccySettingsRecord? {
    do {
      return try record.readStrictly()
    } catch let damaged as InvalidRunStateRecord {
      throw ClipboardHistoryError(
        "\(damaged.url.path) is damaged, so Macarchy no longer knows the values clearOnQuit and "
          + "clearSystemClipboard had before it enabled clearing. Set both in Maccy as you want "
          + "them and delete that file, then run `macarchy clipboard enable` to clear again.")
    }
  }

  /// Asks every instance to quit normally and waits until each process has exited.
  private func quit(_ instances: [RunningMaccy]) throws {
    for instance in instances { maccy.quit(instance) }
    var polls = 0
    while instances.contains(where: maccy.isAlive) {
      guard polls < Self.exitPolls else {
        throw ClipboardHistoryError(
          "Maccy did not quit within five seconds, so Macarchy deleted nothing and left the "
            + "clipboard as it was. If Maccy quits later, open it again. Then clear again.")
      }
      pause()
      polls += 1
    }
  }

  private static func reachingContainer<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PinnedFilesystemError where [EPERM, EACCES].contains(error.code) {
      throw ClipboardHistoryError.appDataPermission(String(describing: error))
    }
  }

  /// A failed clear must not leave a Maccy the user had running closed.
  private func restarting(_ wasRunning: Bool, after error: any Error) -> any Error {
    guard wasRunning else { return error }
    do {
      try maccy.open(.background)
      return error
    } catch let restart {
      return ClipboardHistoryError("\(error); restarting Maccy also failed: \(restart)")
    }
  }
}

extension ClipboardHistory {
  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot, maccy: .live, defaults: .live,
      storage: .live(home: FileManager.default.homeDirectoryForCurrentUser),
      clearPasteboard: { _ = NSPasteboard.general.clearContents() },
      pause: { Thread.sleep(forTimeInterval: 0.05) })
  }
}

extension MaccySetting {
  static func list(_ settings: [Self]) -> String {
    settings.map(\.rawValue).joined(separator: " and ")
  }
}

extension MaccyStoreUnknown {
  var explanation: String {
    switch self {
    case .unsupportedVersion(let version):
      "Maccy \(version) is not the supported \(MaccyApp.supportedVersion), so its storage layout "
        + "is unknown"
    case .missingStoreDirectory:
      "Maccy's storage folder is not where Maccy \(MaccyApp.supportedVersion) keeps it, so its "
        + "storage layout is unknown"
    }
  }
}

extension ClipboardHistoryClear {
  var message: String {
    switch self {
    case .cleared(let wasRunning):
      "Cleared clipboard history, including pinned items." + (wasRunning ? " Maccy restarted." : "")
    case .clearedUnpinnedOnly(true, let reason):
      "Cleared Maccy's unpinned history and the clipboard, but pinned items may remain: "
        + "\(reason.explanation). Maccy restarted."
    case .clearedUnpinnedOnly(false, let reason):
      "Cleared the clipboard only. Maccy was not running, so its own clear did not run, and "
        + "Macarchy deleted nothing because \(reason.explanation)."
    }
  }

  /// The message of a complete clear. An incomplete one throws its message, so the command
  /// exits nonzero and a menu launch shows it in an alert.
  func report() throws -> String {
    guard case .cleared = self else { throw ClipboardHistoryError(message) }
    return message
  }
}

extension ClipboardIntegrationChange {
  var message: String {
    switch self {
    case .enabled:
      "Clipboard history clearing enabled. Maccy now clears its unpinned history and the "
        + "clipboard when it quits, and `macarchy clipboard clear` removes everything, including "
        + "pinned items."
    case .alreadyEnabled:
      "Clipboard history clearing was already enabled."
    case .disabled(let kept) where kept.isEmpty:
      "Clipboard history clearing disabled. Maccy's clearOnQuit and clearSystemClipboard "
        + "settings have their previous values again. Its history was not touched."
    case .disabled(let kept) where kept.count == MaccySetting.allCases.count:
      "Clipboard history clearing disabled. Macarchy left \(MaccySetting.list(kept)) as you set "
        + "them in Maccy. Maccy's history was not touched."
    case .disabled(let kept):
      "Clipboard history clearing disabled. Macarchy left \(MaccySetting.list(kept)) as you set "
        + "it in Maccy and restored the other setting. Maccy's history was not touched."
    case .alreadyDisabled:
      "Clipboard history clearing was not enabled. Nothing changed."
    }
  }
}

extension MaccyOpening {
  var message: String {
    switch self {
    case .history:
      "Opened Maccy's clipboard history."
    case .started:
      "Maccy was not running, so Macarchy started it. Press Maccy's shortcut, Shift-Command-C "
        + "by default, to show the history."
    }
  }
}

extension ClipboardHistoryStatus {
  var message: String {
    guard case .installed(let version) = installation else {
      return ClipboardHistoryError.maccyMissing.description
    }
    var lines = ["Maccy \(version) is installed and \(running ? "running" : "not running")."]
    if !installation.isSupported {
      lines.append(
        "Macarchy knows the storage of Maccy \(MaccyApp.supportedVersion) only, so a clear "
          + "cannot remove pinned items.")
    }
    if enabled {
      lines.append("Clipboard history clearing is enabled.")
    } else if changed.isEmpty {
      lines.append("Clipboard history clearing is not enabled. Run `macarchy clipboard enable`.")
    } else {
      lines.append(
        "Clipboard history clearing is off because \(MaccySetting.list(changed)) changed in "
          + "Maccy. Run `macarchy clipboard enable` to turn it back on.")
    }
    for setting in MaccySetting.allCases {
      let value = (settings[setting] ?? nil).map { $0 ? "true" : "false" } ?? "not set"
      lines.append("\(setting.rawValue): \(value)")
    }
    return lines.joined(separator: "\n")
  }

  /// Installation, settings and integration state only; never clipboard or history content.
  func renderJSON() throws -> String {
    var values: [String: Any] = [:]
    for setting in MaccySetting.allCases {
      values[setting.rawValue] = (settings[setting] ?? nil).map { $0 as Any } ?? NSNull()
    }
    var version: Any = NSNull()
    if case .installed(let installed) = installation { version = installed }
    let document: [String: Any] = [
      "installed": installation != .missing, "version": version,
      "supported": installation.isSupported, "running": running, "enabled": enabled,
      "settings": values,
    ]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
