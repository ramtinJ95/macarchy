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

/// Opens and clears the clipboard history Maccy keeps, fully on request and automatically once
/// 24 hours have passed since the last clear. Macarchy owns only the two settings it turns on,
/// its record of their previous values, the automatic clear's launch agent and its record. It
/// deletes Maccy's history files but never reads them.
struct ClipboardHistory {
  /// With the live 50 ms pause, about five seconds for Maccy to quit or start.
  static let waitPolls = 100
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
  let agent: ClipboardAutoClearAgent
  let clearPasteboard: () -> Void
  let pause: () -> Void
  let now: () -> Date

  /// `<state root>/run/clipboard-maccy-settings.json`.
  static func settingsRecord(stateRoot: URL) -> RunStateRecord<MaccySettingsRecord> {
    RunStateRecord("clipboard-maccy-settings.json", stateRoot: stateRoot) {
      Set($0.previous.keys) == Set(MaccySetting.allCases)
    }
  }

  /// `<state root>/run/clipboard-auto-clear.json`.
  static func autoClearRecord(stateRoot: URL) -> RunStateRecord<ClipboardAutoClearRecord> {
    RunStateRecord("clipboard-auto-clear.json", stateRoot: stateRoot) { _ in true }
  }

  private var record: RunStateRecord<MaccySettingsRecord> {
    Self.settingsRecord(stateRoot: stateRoot)
  }

  private var autoClearRecord: RunStateRecord<ClipboardAutoClearRecord> {
    Self.autoClearRecord(stateRoot: stateRoot)
  }

  func status() throws -> ClipboardStatus {
    try Self.lock.withLock(root: stateRoot) { () throws -> ClipboardStatus in
      ClipboardStatus(
        history: try current(),
        autoClear: ClipboardAutoClearStatus(
          agent: try agent.file(), loaded: try agent.isLoaded(), record: try readAutoClearRecord(),
          checked: now()))
    }
  }

  /// Records both settings' values, then turns both on. An existing record keeps the values
  /// from before the first enable.
  func enable() throws -> ClipboardIntegrationChange {
    try Self.lock.withLock(root: stateRoot) { try applyEnable() }
  }

  /// Restores each setting that still holds Macarchy's value; one changed in Maccy since keeps
  /// that change. History is never touched.
  func disable() throws -> ClipboardIntegrationChange {
    try Self.lock.withLock(root: stateRoot) { try applyDisable() }
  }

  /// Turns on the settings first, because the automatic clear relies on them, then the
  /// automatic clear. One lock covers both, so a concurrent disable cannot interleave and leave
  /// the automatic clear running without the settings. When the automatic clear fails, the
  /// error still reports the settings change.
  func enableWithAutoClear() throws -> String {
    try Self.lock.withLock(root: stateRoot) { () throws -> String in
      let settings = try applyEnable().message
      do {
        return try settings + "\n" + applyAutoClear(.on).message
      } catch {
        throw ClipboardHistoryError("\(settings)\n\(error)")
      }
    }
  }

  /// Turns off the automatic clear first, then restores the settings. When the automatic clear
  /// cannot be turned off, it may still run, so the settings it relies on stay on.
  func disableWithAutoClear() throws -> String {
    try Self.lock.withLock(root: stateRoot) { () throws -> String in
      let autoClear: String
      do {
        autoClear = try applyAutoClear(.off).message
      } catch {
        throw ClipboardHistoryError(
          "\(error)\nMaccy's clearOnQuit and clearSystemClipboard stay on, because the "
            + "automatic clear relies on them while it may still run. Fix the launch agent, then "
            + "run `macarchy clipboard disable` again.")
      }
      return try autoClear + "\n" + applyDisable().message
    }
  }

  private func applyEnable() throws -> ClipboardIntegrationChange {
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

  private func applyDisable() throws -> ClipboardIntegrationChange {
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
      if wasRunning, !quit(instances) {
        throw ClipboardHistoryError(
          "Maccy did not quit within five seconds, so Macarchy deleted nothing and left the "
            + "clipboard as it was. If Maccy quits later, open it again. Then clear again.")
      }
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
      if wasRunning { try reopen() }
      // A clear that emptied only the clipboard left the history, so it does not postpone the
      // automatic clear.
      if unknown == nil || wasRunning { try restartAutoClearWindow() }
      guard let unknown else { return .cleared(maccyWasRunning: wasRunning) }
      return .clearedUnpinnedOnly(maccyWasRunning: wasRunning, reason: unknown)
    }
  }

  /// Turns the automatic clear on or off without changing Maccy's settings. On needs clearing
  /// enabled, because the automatic clear relies on Maccy's own clear-on-quit.
  func setAutoClear(_ request: ClipboardAutoClearSwitch) throws -> ClipboardAutoClearChange {
    try Self.lock.withLock(root: stateRoot) { try applyAutoClear(request) }
  }

  private func applyAutoClear(_ request: ClipboardAutoClearSwitch) throws
    -> ClipboardAutoClearChange
  {
    switch request {
    case .on:
      _ = try clearableVersion(refusal: "the automatic clear was not turned on")
      let installed = try agent.install()
      // A damaged record gets a new window too.
      let started = try autoClearRecord.read() == nil
      if started { try autoClearRecord.write(.cleared(at: now())) }
      let loaded = try agent.load()
      return installed || started || loaded ? .turnedOn : .alreadyOn
    case .off:
      // A job loaded from somebody else's plist under this label is not Macarchy's to stop.
      if case .conflict = try agent.file() { throw agent.conflict }
      let unloaded = try agent.unload()
      let removed = try agent.remove()
      try autoClearRecord.remove()
      return unloaded || removed ? .turnedOff : .alreadyOff
    }
  }

  /// The launch agent's hourly run. Once 24 hours have passed since the last clear, Maccy's own
  /// clear-on-quit removes its unpinned history and Macarchy empties the clipboard. It never
  /// reaches Maccy's container or settings, where macOS would ask for permission with nobody
  /// there to answer.
  func runAutoClear() throws -> ClipboardAutoClearRun {
    try Self.lock.withLock(root: stateRoot) { () throws -> ClipboardAutoClearRun in
      let date = now()
      guard let saved = try readAutoClearRecord() else {
        try autoClearRecord.write(.cleared(at: date))
        return .windowStarted
      }
      guard saved.isDue(at: date) else { return .notDue }
      let wasRunning: Bool
      do {
        wasRunning = try clearWithoutContainer()
      } catch {
        let message = String(describing: error)
        let failed = saved.failing(message, at: date)
        try autoClearRecord.write(failed.record)
        return .failed(message: message, alert: failed.alert)
      }
      try autoClearRecord.write(.cleared(at: date))
      return .cleared(maccyWasRunning: wasRunning)
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

  /// `refusal` says what did not happen when clearing is not enabled.
  private func clearableVersion(refusal: String = "nothing was cleared") throws -> String {
    let version = try installedVersion()
    let status = try current()
    guard status.enabled else {
      if status.changed.isEmpty {
        throw ClipboardHistoryError(
          "Clipboard history clearing is not enabled, so \(refusal). Run "
            + "`macarchy clipboard enable` first.")
      }
      throw ClipboardHistoryError(
        "\(MaccySetting.list(status.changed)) changed in Maccy after Macarchy enabled clearing, "
          + "so \(refusal). Run `macarchy clipboard enable` to turn clearing back on.")
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

  private func readAutoClearRecord() throws -> ClipboardAutoClearRecord? {
    do {
      return try autoClearRecord.readStrictly()
    } catch let damaged as InvalidRunStateRecord {
      throw ClipboardHistoryError(
        "\(damaged.url.path) is damaged, so Macarchy does not know when clipboard history was "
          + "last cleared. Run `macarchy clipboard auto-clear on` to start a new 24-hour window.")
    }
  }

  /// A clear restarts the automatic clear's window while it is on. A damaged record is
  /// replaced, since the time of this clear is known.
  private func restartAutoClearWindow() throws {
    do {
      guard try autoClearRecord.readStrictly() != nil else { return }
    } catch is InvalidRunStateRecord {}
    try autoClearRecord.write(.cleared(at: now()))
  }

  /// Clears unpinned history through Maccy's own clear-on-quit and empties the clipboard. A
  /// closed Maccy starts for its clear and is closed again. Returns whether Maccy was running.
  private func clearWithoutContainer() throws -> Bool {
    _ = try installedVersion()
    let running = try maccy.instances()
    let instances = running.isEmpty ? try startInBackground() : running
    guard quit(instances) else {
      throw ClipboardHistoryError(
        "Maccy did not quit within five seconds, so its history and the clipboard were not "
          + "cleared")
    }
    clearPasteboard()
    if running.isEmpty { return false }
    try reopen()
    return true
  }

  /// Opens Maccy without bringing it forward and waits until it runs. Maccy 2.7.1's
  /// clear-on-quit deletes unpinned items from its store directly, not from the list it loads
  /// when its window first shows, so quitting right after this still clears them.
  private func startInBackground() throws -> [RunningMaccy] {
    try maccy.open(.background)
    var started: [RunningMaccy] = []
    let running = try poll {
      started = try maccy.instances()
      return !started.isEmpty
    }
    guard running else {
      throw ClipboardHistoryError(
        "Maccy did not start within five seconds, so its history and the clipboard were not "
          + "cleared")
    }
    return started
  }

  /// Asks every instance to quit normally; false when one has not exited after the wait.
  private func quit(_ instances: [RunningMaccy]) -> Bool {
    for instance in instances { maccy.quit(instance) }
    return poll { !instances.contains(where: maccy.isAlive) }
  }

  /// Pauses until `done` holds, at most `waitPolls` times; false when it never did.
  private func poll(until done: () throws -> Bool) rethrows -> Bool {
    var polls = 0
    while try !done() {
      guard polls < Self.waitPolls else { return false }
      pause()
      polls += 1
    }
    return true
  }

  private func reopen() throws {
    do {
      try maccy.open(.background)
    } catch {
      throw ClipboardHistoryError(
        "Restarting Maccy after the clear failed: \(error). Open Maccy yourself.")
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
    let home = FileManager.default.homeDirectoryForCurrentUser
    return Self(
      stateRoot: stateRoot, maccy: .live, defaults: .live, storage: .live(home: home),
      agent: ClipboardAutoClearAgent(
        home: home, stateRoot: stateRoot,
        executable: RuntimeEnvironment.live.persistentCommandURL, userID: getuid(),
        runner: .live),
      clearPasteboard: { _ = NSPasteboard.general.clearContents() },
      pause: { Self.turnRunLoop(for: 0.05) }, now: Date.init)
  }

  /// Waits on the run loop instead of sleeping. AppKit updates the running apps that
  /// `MaccyApp.instances` lists only when the main run loop turns, so waiting for Maccy to start
  /// must turn it.
  private static func turnRunLoop(for seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    // Without a timer, a run loop with nothing scheduled returns at once.
    RunLoop.current.add(
      Timer(fire: deadline, interval: 0, repeats: false) { _ in }, forMode: .default)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
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
  var json: [String: Any] {
    var values: [String: Any] = [:]
    for setting in MaccySetting.allCases {
      values[setting.rawValue] = (settings[setting] ?? nil).map { $0 as Any } ?? NSNull()
    }
    var version: Any = NSNull()
    if case .installed(let installed) = installation { version = installed }
    return [
      "installed": installation != .missing, "version": version,
      "supported": installation.isSupported, "running": running, "enabled": enabled,
      "settings": values,
    ]
  }
}
