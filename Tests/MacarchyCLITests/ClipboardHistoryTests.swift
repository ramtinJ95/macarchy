import ArgumentParser
import Darwin
import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

/// Every Maccy, `defaults`, pasteboard and `open` effect goes through the injected machine, and
/// a temporary directory stands in for Maccy's container. No test creates a special file or a
/// symbolic link; a symlink is only reported by the file-type seam.
struct ClipboardHistoryTests {
  private static let instance = RunningMaccy(pid: 4_242, started: 1_000)
  private static let otherInstance = RunningMaccy(pid: 4_343, started: 2_000)
  private static let storeFiles = [
    "Library/Application Support/Maccy/Storage.sqlite",
    "Library/Application Support/Maccy/Storage.sqlite-shm",
    "Library/Application Support/Maccy/Storage.sqlite-wal",
    "Documents/image.png",
  ]
  private static let missing = "Maccy is not installed. Install it with: brew install --cask maccy"

  @Test(arguments: [(nil, nil), (true, false), (false, true), (nil, false)] as [(Bool?, Bool?)])
  func enableRecordsEachPriorValueAndDisableRestoresIt(
    clearOnQuit: Bool?, clearSystemClipboard: Bool?
  ) throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings[.clearOnQuit] = clearOnQuit
      machine.settings[.clearSystemClipboard] = clearSystemClipboard
      let prior = machine.settings
      let previous: [MaccySetting: Bool?] = [
        .clearOnQuit: clearOnQuit, .clearSystemClipboard: clearSystemClipboard,
      ]

      #expect(try engine.enable() == .enabled)
      #expect(machine.settings == [.clearOnQuit: true, .clearSystemClipboard: true])
      #expect(try fixture.record.read() == MaccySettingsRecord(previous: previous))
      #expect(try engine.status().enabled)

      let writes = machine.writes
      #expect(try engine.enable() == .alreadyEnabled)
      #expect(machine.writes == writes)
      #expect(try fixture.record.read() == MaccySettingsRecord(previous: previous))

      #expect(try engine.disable() == .disabled(kept: []))
      #expect(machine.settings == prior)
      #expect(try fixture.record.read() == nil)
      #expect(try engine.status().enabled == false)
      #expect(machine.quitRequests == 0)
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func theRecordIsAnObjectKeyedBySettingName() throws {
    try withEngine { engine, _, fixture throws in
      #expect(try engine.enable() == .enabled)
      let document =
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.record.url))
        as? [String: [String: Any]]
      let keys: Set<String> = Set(document?["previous"]?.keys.map { $0 } ?? [])
      #expect(keys == ["clearOnQuit", "clearSystemClipboard"])
    }
  }

  @Test func enablingAgainAfterAChangeInMaccyKeepsTheOriginalValues() throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearOnQuit: false]
      #expect(try engine.enable() == .enabled)
      machine.settings[.clearOnQuit] = false

      let status = try engine.status()
      #expect(status.enabled == false)
      #expect(status.changed == [.clearOnQuit])
      #expect(status.message.contains("off because clearOnQuit changed in Maccy"))
      let refused = #expect(throws: ClipboardHistoryError.self) { try engine.clear() }
      #expect(refused?.description.contains("`macarchy clipboard enable`") == true)

      #expect(try engine.enable() == .enabled)
      #expect(machine.settings == [.clearOnQuit: true, .clearSystemClipboard: true])
      let previous: [MaccySetting: Bool?] = [.clearOnQuit: false, .clearSystemClipboard: nil]
      #expect(try fixture.record.read() == MaccySettingsRecord(previous: previous))
    }
  }

  @Test func disableLeavesSettingsChangedInMaccyAndReportsThem() throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearSystemClipboard: false]
      #expect(try engine.enable() == .enabled)
      machine.settings[.clearSystemClipboard] = nil

      let change = try engine.disable()
      #expect(change == .disabled(kept: [.clearSystemClipboard]))
      // clearOnQuit returns to unset; clearSystemClipboard keeps the user's unset value rather
      // than going back to false.
      #expect(machine.settings.isEmpty)
      #expect(change.message.contains("left clearSystemClipboard as you set it in Maccy"))
      #expect(try fixture.record.read() == nil)
    }
  }

  @Test func disableFinishesAfterAFailureWithoutReportingRestoredSettingsAsKept() throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearSystemClipboard: false]
      #expect(try engine.enable() == .enabled)
      machine.failingWrites = [.clearSystemClipboard]

      #expect(throws: ClipboardHistoryError.self) { try engine.disable() }
      #expect(machine.settings == [.clearSystemClipboard: true])
      #expect(try fixture.record.read() != nil)

      machine.failingWrites = []
      #expect(try engine.disable() == .disabled(kept: []))
      #expect(machine.settings == [.clearSystemClipboard: false])
      #expect(try fixture.record.read() == nil)
    }
  }

  @Test func disableWithoutContainerAccessKeepsTheRecordAndSettings() throws {
    try withEngine { engine, machine, fixture throws in
      try FileManager.default.createDirectory(
        at: fixture.url("Library/Preferences"), withIntermediateDirectories: true)
      #expect(try engine.enable() == .enabled)
      machine.refusedDirectories = ["Library/Preferences"]

      let error = #expect(throws: ClipboardHistoryError.self) { try engine.disable() }
      #expect(error?.description.contains("access data from other apps") == true)
      #expect(try fixture.record.read() != nil)
      #expect(machine.settings == [.clearOnQuit: true, .clearSystemClipboard: true])
    }
  }

  @Test func maccyStartingAgainDuringAClearDeletesNothing() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      machine.running = true
      machine.startsAgainAfterExit = true

      let error = #expect(throws: ClipboardHistoryError.self) { try engine.clear() }
      #expect(error?.description.contains("Maccy started again during the clear") == true)
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
      #expect(machine.opened.isEmpty)
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func disableWithoutARecordChangesNothing() throws {
    try withEngine { engine, machine, _ throws in
      machine.settings = [.clearOnQuit: true]
      #expect(try engine.disable() == .alreadyDisabled)
      #expect(machine.settings == [.clearOnQuit: true])
      #expect(machine.writes == 0)
    }
  }

  /// The record is the only memory of the user's earlier values, so a damaged one is never
  /// silently replaced.
  @Test(arguments: [#"{"previous":"#, #"{"previous":{"clearOnQuit":true}}"#])
  func aDamagedRecordStopsEveryCommandAndIsKept(content: String) throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearOnQuit: true, .clearSystemClipboard: true]
      machine.running = true
      try fixture.writeStore()
      try FileManager.default.createDirectory(
        at: fixture.record.directory, withIntermediateDirectories: true)
      try Data(content.utf8).write(to: fixture.record.url)

      let operations: [() throws -> Void] = [
        { _ = try engine.status() }, { _ = try engine.enable() }, { _ = try engine.disable() },
        { _ = try engine.clear() },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description.contains("is damaged") == true)
      }
      #expect(try String(contentsOf: fixture.record.url, encoding: .utf8) == content)
      #expect(machine.writes == 0)
      #expect(machine.log.isEmpty)
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
    }
  }

  @Test func enableWaitsUntilMaccyHasRunOnce() throws {
    try withEngine { engine, machine, fixture throws in
      try FileManager.default.removeItem(at: fixture.container)
      let error = #expect(throws: ClipboardHistoryError.self) { try engine.enable() }
      #expect(error?.description.contains("Open Maccy once") == true)
      #expect(machine.settings.isEmpty)
      #expect(try engine.status().enabled == false)
    }
  }

  @Test func clearQuitsARunningMaccyDeletesEveryStoreFileAndStartsItAgain() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      machine.running = true
      machine.exitAfterPauses = 3

      #expect(try engine.checkClearable() == nil)
      let outcome = try engine.clear()
      #expect(outcome == .cleared(maccyWasRunning: true))
      #expect(
        try outcome.report()
          == "Cleared clipboard history, including pinned items. Maccy restarted.")
      #expect(machine.log == ["quit", "exited", "files", "clear pasteboard", "open background"])
      #expect(machine.pauses == 3)
      #expect(Self.storeFiles.allSatisfy { !fixture.exists($0) })
      #expect(fixture.exists("Library/Application Support/Maccy"))
      #expect(fixture.exists("Documents"))
      #expect(machine.running)
    }
  }

  @Test func clearWithMaccyClosedDeletesTheFilesAndLeavesItClosed() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()

      let outcome = try engine.clear()
      #expect(outcome == .cleared(maccyWasRunning: false))
      #expect(try outcome.report() == "Cleared clipboard history, including pinned items.")
      #expect(machine.log == ["files", "clear pasteboard"])
      #expect(Self.storeFiles.allSatisfy { !fixture.exists($0) })
      #expect(machine.running == false)
    }
  }

  @Test func aMaccyThatDoesNotQuitStopsTheClearBeforeAnythingIsDeleted() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      machine.running = true
      machine.exitAfterPauses = nil

      let error = #expect(throws: ClipboardHistoryError.self) { try engine.clear() }
      #expect(error?.description.contains("did not quit within five seconds") == true)
      #expect(machine.pauses == ClipboardHistory.exitPolls)
      #expect(machine.log == ["quit"])
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
    }
  }

  @Test(arguments: ["a symbolic link", "a directory"])
  func anythingButARegularFileAtAStoreNameDeletesNothing(kind: String) throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      let wal = "Library/Application Support/Maccy/Storage.sqlite-wal"
      if kind == "a directory" {
        try FileManager.default.removeItem(at: fixture.url(wal))
        try FileManager.default.createDirectory(
          at: fixture.url(wal), withIntermediateDirectories: false)
      } else {
        machine.fileTypes["Storage.sqlite-wal"] = S_IFLNK
      }
      machine.running = true

      let error = #expect(throws: ClipboardHistoryError.self) { try engine.clear() }
      #expect(
        error?.description.contains("Storage.sqlite-wal is \(kind), not a regular file") == true)
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
      #expect(machine.log == ["quit", "exited", "files", "open background"])
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func refusedContainerAccessNamesThePermissionAndDeletesNothing() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      machine.refusedNames = ["Storage.sqlite-wal"]
      machine.running = true

      let error = #expect(throws: ClipboardHistoryError.self) { try engine.clear() }
      #expect(error?.description.contains("access data from other apps") == true)
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
      #expect(machine.log == ["quit", "exited", "files", "open background"])
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test(arguments: ["no container", "empty store"])
  func missingStoreFilesAreAlreadyClear(layout: String) throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      if layout == "no container" {
        try FileManager.default.removeItem(at: fixture.container)
      } else {
        try FileManager.default.createDirectory(
          at: fixture.url("Library/Application Support/Maccy"), withIntermediateDirectories: true)
      }
      #expect(try engine.clear() == .cleared(maccyWasRunning: false))
      #expect(machine.pasteboardClears == 1)
    }
  }

  @Test(arguments: [true, false])
  func anUnsupportedVersionDeletesNoFileAndFailsLoudly(running: Bool) throws {
    try withEngine { engine, machine, fixture throws in
      machine.installation = .installed(version: "2.8.0")
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      machine.running = running

      #expect(try engine.checkClearable() == MaccyStoreUnknown.unsupportedVersion("2.8.0"))
      let outcome = try engine.clear()
      #expect(
        outcome
          == .clearedUnpinnedOnly(maccyWasRunning: running, reason: .unsupportedVersion("2.8.0")))
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
      let expected: [String] =
        running ? ["quit", "exited", "clear pasteboard", "open background"] : ["clear pasteboard"]
      #expect(machine.log == expected)
      let error = #expect(throws: ClipboardHistoryError.self) { try outcome.report() }
      #expect(error?.description == outcome.message)
      if running {
        let message: String =
          "Cleared Maccy's unpinned history and the clipboard, but pinned items may remain: "
          + "Maccy 2.8.0 is not the supported 2.7.1, so its storage layout is unknown. "
          + "Maccy restarted."
        #expect(outcome.message == message)
      } else {
        #expect(outcome.message.hasPrefix("Cleared the clipboard only."))
      }
    }
  }

  @Test func aContainerWithoutTheStoreFolderIsAnUnknownLayout() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      try FileManager.default.removeItem(at: fixture.url("Library/Application Support/Maccy"))

      #expect(
        try engine.clear()
          == .clearedUnpinnedOnly(maccyWasRunning: false, reason: .missingStoreDirectory))
      #expect(fixture.exists("Documents/image.png"))
      #expect(machine.pasteboardClears == 1)
    }
  }

  @Test func clearRefusesUntilClearingIsEnabled() throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearOnQuit: true, .clearSystemClipboard: true]
      try fixture.writeStore()
      machine.running = true

      let operations: [() throws -> Void] = [
        { _ = try engine.checkClearable() }, { _ = try engine.clear() },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description.contains("Run `macarchy clipboard enable` first") == true)
      }
      #expect(machine.log.isEmpty)
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
    }
  }

  @Test func everyCommandButStatusNeedsMaccy() throws {
    try withEngine { engine, machine, _ throws in
      machine.installation = .missing
      let operations: [() throws -> Void] = [
        { _ = try engine.enable() }, { _ = try engine.disable() }, { _ = try engine.clear() },
        { _ = try engine.open() }, { _ = try engine.checkClearable() },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description == Self.missing)
      }
      let status = try engine.status()
      #expect(status.message == Self.missing)
      let json: String =
        #"{"enabled":false,"installed":false,"running":false,"#
        + #""settings":{"clearOnQuit":null,"clearSystemClipboard":null},"#
        + #""supported":false,"version":null}"#
      #expect(try status.renderJSON() == json)
      #expect(machine.writes == 0)
      #expect(machine.log.isEmpty)
    }
  }

  @Test func statusReportsStateButNoContent() throws {
    try withEngine { engine, machine, _ throws in
      #expect(try engine.enable() == .enabled)
      machine.running = true

      let status = try engine.status()
      #expect(
        status
          == ClipboardHistoryStatus(
            installation: .installed(version: "2.7.1"), running: true, recorded: true,
            settings: [.clearOnQuit: true, .clearSystemClipboard: true]))
      let json: String =
        #"{"enabled":true,"installed":true,"running":true,"#
        + #""settings":{"clearOnQuit":true,"clearSystemClipboard":true},"#
        + #""supported":true,"version":"2.7.1"}"#
      #expect(try status.renderJSON() == json)
      let message: String =
        "Maccy 2.7.1 is installed and running.\nClipboard history clearing is enabled.\n"
        + "clearOnQuit: true\nclearSystemClipboard: true"
      #expect(status.message == message)
    }
  }

  @Test func statusNamesAnUnsupportedVersion() throws {
    try withEngine { engine, machine, _ throws in
      machine.installation = .installed(version: "2.8.0")
      machine.settings = [.clearOnQuit: false]

      let status = try engine.status()
      #expect(status.installation.isSupported == false)
      let message: String =
        "Maccy 2.8.0 is installed and not running.\n"
        + "Macarchy knows the storage of Maccy 2.7.1 only, so a clear cannot remove pinned "
        + "items.\nClipboard history clearing is not enabled. Run `macarchy clipboard enable`.\n"
        + "clearOnQuit: false\nclearSystemClipboard: not set"
      #expect(status.message == message)
      let json: String =
        #"{"enabled":false,"installed":true,"running":false,"#
        + #""settings":{"clearOnQuit":false,"clearSystemClipboard":null},"#
        + #""supported":false,"version":"2.8.0"}"#
      #expect(try status.renderJSON() == json)
    }
  }

  @Test(arguments: [true, false])
  func openShowsTheHistoryOrStartsMaccy(running: Bool) throws {
    try withEngine { engine, machine, _ throws in
      machine.running = running
      let opening = try engine.open()
      let expected: MaccyOpening = running ? .history : .started
      #expect(opening == expected)
      #expect(machine.opened == [.history])
      #expect(opening.message.contains("Shift-Command-C") == !running)
    }
  }

  @Test func defaultsOutputParsesOnlyBooleans() throws {
    let boolean = ProcessResult(terminationStatus: 0, output: "Type is boolean")
    let on = ProcessResult(terminationStatus: 0, output: "1")
    let off = ProcessResult(terminationStatus: 0, output: "0")
    let absent = ProcessResult(
      terminationStatus: 1,
      output: "The domain/default pair of (org.p0deje.Maccy, clearOnQuit) does not exist")
    #expect(try MaccyDefaults.parse(.clearOnQuit, type: boolean, value: on) == true)
    #expect(try MaccyDefaults.parse(.clearOnQuit, type: boolean, value: off) == false)
    #expect(try MaccyDefaults.parse(.clearOnQuit, type: absent, value: nil) == nil)

    let string = ProcessResult(terminationStatus: 0, output: "Type is string")
    let notBoolean = #expect(throws: ClipboardHistoryError.self) {
      try MaccyDefaults.parse(.clearOnQuit, type: string, value: on)
    }
    #expect(notBoolean?.description.contains("not a Boolean") == true)
    let failed = ProcessResult(terminationStatus: 1, output: "cfprefsd is unavailable")
    #expect(throws: ClipboardHistoryError.self) {
      try MaccyDefaults.parse(.clearOnQuit, type: failed, value: nil)
    }
  }

  @Test func menuLaunchesParse() throws {
    let clear = try ClipboardCommand.Clear.parse(["--confirm", "--alert-on-error"])
    #expect(clear.confirm)
    #expect(clear.options.alertOnError)
    #expect(try ClipboardCommand.Clear.parse([]).confirm == false)
    #expect(try ClipboardCommand.Open.parse(["--alert-on-error"]).options.alertOnError)
    #expect(try ClipboardCommand.Status.parse(["--json"]).json)
  }

  /// Maccy, its settings, the pasteboard and `open`, as the engine observes or changes them.
  private final class Machine {
    var installation = MaccyInstallation.installed(version: "2.7.1")
    var running = false
    /// nil never exits after a quit request.
    var exitAfterPauses: Int? = 0
    var settings: [MaccySetting: Bool] = [:]
    var failingWrites: Set<MaccySetting> = []
    var writes = 0
    var fileTypes: [String: mode_t] = [:]
    var refusedNames: Set<String> = []
    /// Container-relative directories whose opening macOS refuses.
    var refusedDirectories: Set<String> = []
    /// Another Maccy appears once the quit one exits, as if started from the Dock.
    var startsAgainAfterExit = false
    var startedElsewhere = false
    var opened: [MaccyLaunch] = []
    var quitRequests = 0
    var pauses = 0
    var pasteboardClears = 0
    var log: [String] = []

    func exit() {
      running = false
      log.append("exited")
      if startsAgainAfterExit { startedElsewhere = true }
    }
  }

  private struct Fixture {
    let root: URL

    var state: URL { root.appending(path: "state", directoryHint: .isDirectory) }
    var container: URL { root.appending(path: "container", directoryHint: .isDirectory) }
    var record: RunStateRecord<MaccySettingsRecord> {
      ClipboardHistory.settingsRecord(stateRoot: state)
    }

    func url(_ relative: String) -> URL { container.appending(path: relative) }

    func exists(_ relative: String) -> Bool {
      FileManager.default.fileExists(atPath: url(relative).path)
    }

    func writeStore() throws {
      for file in ClipboardHistoryTests.storeFiles {
        try FileManager.default.createDirectory(
          at: url(file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: url(file))
      }
    }

    /// The state `enable` leaves, set directly so clear tests do not depend on enable.
    func enableClearing(_ machine: Machine) throws {
      try FileManager.default.createDirectory(
        at: record.directory, withIntermediateDirectories: true)
      try record.write(
        MaccySettingsRecord(previous: [.clearOnQuit: nil, .clearSystemClipboard: nil]))
      machine.settings = [.clearOnQuit: true, .clearSystemClipboard: true]
    }
  }

  private func withEngine(_ body: (ClipboardHistory, Machine, Fixture) throws -> Void) throws {
    let fixture = Fixture(
      root: FileManager.default.temporaryDirectory.appending(
        path: "macarchy-clipboard-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.container, withIntermediateDirectories: true)
    let machine = Machine()
    let engine = ClipboardHistory(
      stateRoot: fixture.state,
      maccy: MaccyApp(
        installation: { machine.installation },
        instances: {
          machine.running
            ? [Self.instance] : machine.startedElsewhere ? [Self.otherInstance] : []
        },
        quit: { _ in
          machine.quitRequests += 1
          machine.log.append("quit")
          if machine.exitAfterPauses == 0 { machine.exit() }
        },
        isAlive: { $0 == Self.instance && machine.running },
        open: { launch in
          machine.opened.append(launch)
          machine.log.append("open \(launch)")
          machine.running = true
        }),
      defaults: MaccyDefaults(
        read: { machine.settings[$0] },
        write: { setting, value in
          guard !machine.failingWrites.contains(setting) else {
            throw ClipboardHistoryError("cfprefsd refused the write")
          }
          machine.writes += 1
          machine.settings[setting] = value
        }),
      storage: MaccyStorage(
        root: fixture.container,
        fileType: { parent, name, url in
          if machine.log.last != "files" { machine.log.append("files") }
          if machine.refusedNames.contains(name) {
            throw PinnedFilesystemError(operation: "inspect", url: url, code: EPERM)
          }
          return try machine.fileTypes[name]
            ?? MaccyStorage.liveFileType(parent: parent, name: name, url: url)
        },
        openDirectory: { url in
          let relative = url.path.dropFirst(fixture.container.path.count + 1)
          if machine.refusedDirectories.contains(String(relative)) {
            throw PinnedFilesystemError(operation: "open", url: url, code: EPERM)
          }
          return try PinnedFilesystem.openDirectoryIfPresent(at: url)
        }),
      clearPasteboard: {
        machine.pasteboardClears += 1
        machine.log.append("clear pasteboard")
      },
      pause: {
        machine.pauses += 1
        if machine.running, let limit = machine.exitAfterPauses, machine.pauses >= limit {
          machine.exit()
        }
      })
    try body(engine, machine, fixture)
  }
}
