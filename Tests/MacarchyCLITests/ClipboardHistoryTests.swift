import ArgumentParser
import Darwin
import Foundation
import Testing
import ThemeCore

@testable import MacarchyCLI

/// Every Maccy, `defaults`, pasteboard, `open` and launchctl effect goes through the injected
/// machine, and temporary directories stand in for Maccy's container and the home folder. No
/// test creates a special file or a symbolic link; a symlink is only reported by the file-type
/// seam.
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
  private static let autoClearOff =
    "Automatic clear is off. Run `macarchy clipboard auto-clear on` to turn it on."
  private static let autoClearOffJSON =
    #""autoClear":{"lastClear":null,"lastFailure":null,"loaded":false,"nextDue":null,"#
    + #""overdue":false,"state":"off"},"#
  private static let day: TimeInterval = 86_400
  private static let autoClearOnDetail =
    "Once 24 hours have passed since the last clear, Macarchy clears unpinned history and the "
    + "clipboard. Pinned items survive it."
  private static let autoClearStatusDetail =
    "Once 24 hours have passed since the last clear, it clears unpinned history and the "
    + "clipboard. It relies on clearOnQuit and clearSystemClipboard, which it cannot check. "
    + "Pinned items survive automatic clears."

  private static func cleared(_ date: Date) -> ClipboardAutoClearRecord {
    ClipboardAutoClearRecord(lastClear: date, lastFailure: nil)
  }

  /// Local date and 24-hour time, as status shows them.
  private static func local(_ date: Date) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents(
      [.year, .month, .day, .hour, .minute], from: date)
    return String(
      format: "%04d-%02d-%02d %02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!,
      parts.minute!)
  }

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
      #expect(try engine.status().history.enabled)

      let writes = machine.writes
      #expect(try engine.enable() == .alreadyEnabled)
      #expect(machine.writes == writes)
      #expect(try fixture.record.read() == MaccySettingsRecord(previous: previous))

      #expect(try engine.disable() == .disabled(kept: []))
      #expect(machine.settings == prior)
      #expect(try fixture.record.read() == nil)
      #expect(try engine.status().history.enabled == false)
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
      #expect(status.history.enabled == false)
      #expect(status.history.changed == [.clearOnQuit])
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
      #expect(try engine.status().history.enabled == false)
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
      #expect(machine.pauses == ClipboardHistory.waitPolls)
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
      let window = Self.cleared(machine.now.addingTimeInterval(-3_600))
      try fixture.writeAutoClear(window)

      #expect(try engine.checkClearable() == MaccyStoreUnknown.unsupportedVersion("2.8.0"))
      let outcome = try engine.clear()
      #expect(
        outcome
          == .clearedUnpinnedOnly(maccyWasRunning: running, reason: .unsupportedVersion("2.8.0")))
      #expect(Self.storeFiles.allSatisfy(fixture.exists))
      // Clearing only the clipboard leaves the history, so the 24-hour window keeps running.
      #expect(try fixture.autoClear.read() == (running ? Self.cleared(machine.now) : window))
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
        { _ = try engine.setAutoClear(.on) },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description == Self.missing)
      }
      let status = try engine.status()
      #expect(status.message == Self.missing + "\n" + Self.autoClearOff)
      let json: String =
        "{" + Self.autoClearOffJSON + #""enabled":false,"installed":false,"running":false,"#
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
        status.history
          == ClipboardHistoryStatus(
            installation: .installed(version: "2.7.1"), running: true, recorded: true,
            settings: [.clearOnQuit: true, .clearSystemClipboard: true]))
      let json: String =
        "{" + Self.autoClearOffJSON + #""enabled":true,"installed":true,"running":true,"#
        + #""settings":{"clearOnQuit":true,"clearSystemClipboard":true},"#
        + #""supported":true,"version":"2.7.1"}"#
      #expect(try status.renderJSON() == json)
      let message: String =
        "Maccy 2.7.1 is installed and running.\nClipboard history clearing is enabled.\n"
        + "clearOnQuit: true\nclearSystemClipboard: true\n" + Self.autoClearOff
      #expect(status.message == message)
    }
  }

  @Test func statusNamesAnUnsupportedVersion() throws {
    try withEngine { engine, machine, _ throws in
      machine.installation = .installed(version: "2.8.0")
      machine.settings = [.clearOnQuit: false]

      let status = try engine.status()
      #expect(status.history.installation.isSupported == false)
      let message: String =
        "Maccy 2.8.0 is installed and not running.\n"
        + "Macarchy knows the storage of Maccy 2.7.1 only, so a clear cannot remove pinned "
        + "items.\nClipboard history clearing is not enabled. Run `macarchy clipboard enable`.\n"
        + "clearOnQuit: false\nclearSystemClipboard: not set\n" + Self.autoClearOff
      #expect(status.message == message)
      let json: String =
        "{" + Self.autoClearOffJSON + #""enabled":false,"installed":true,"running":false,"#
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

  @Test func autoClearCommandsParse() throws {
    #expect(try ClipboardCommand.AutoClear.parse(["on"]).state == .on)
    #expect(try ClipboardCommand.AutoClear.parse(["off"]).state == .off)
    #expect(throws: (any Error).self) { try ClipboardCommand.AutoClear.parse(["toggle"]) }
    let run = try ClipboardCommand.RunAutoClear.parse(["--state-root", "/Users/test/state"])
    #expect(run.options.stateRoot == "/Users/test/state")
    let alert = try ClipboardCommand.RunAutoClear.parse([
      "--state-root", "/Users/test/state", "--alert=-Maccy did not quit",
    ])
    #expect(alert.alert == "-Maccy did not quit")
  }

  @Test func enableTurnsOnTheAutomaticClearAndDisableTurnsItOff() throws {
    try withEngine { engine, machine, fixture throws in
      let enabled = try engine.enableWithAutoClear()
      #expect(enabled.hasSuffix("\nAutomatic clear on. " + Self.autoClearOnDetail))
      #expect(try engine.agent.file() == .owned)
      #expect(machine.launchd.loaded)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))

      machine.now = machine.now.addingTimeInterval(3_600)
      let again = try engine.enableWithAutoClear()
      #expect(
        again == "Clipboard history clearing was already enabled.\nAutomatic clear was already on.")
      #expect(try fixture.autoClear.read()?.lastClear == machine.now.addingTimeInterval(-3_600))
      #expect(machine.launchd.calls.filter { $0.first == "bootstrap" }.count == 1)

      let disabled = try engine.disableWithAutoClear()
      #expect(disabled.hasPrefix("Automatic clear off.\nClipboard history clearing disabled."))
      #expect(try engine.agent.file() == .absent)
      #expect(machine.launchd.loaded == false)
      #expect(try fixture.autoClear.read() == nil)
      #expect(machine.settings.isEmpty)
      #expect(machine.log.isEmpty)
    }
  }

  @Test func autoClearOffKeepsMaccysSettingsAndOnStartsANewWindow() throws {
    try withEngine { engine, machine, fixture throws in
      _ = try engine.enableWithAutoClear()
      let writes = machine.writes

      #expect(try engine.setAutoClear(.off) == .turnedOff)
      #expect(try engine.agent.file() == .absent)
      #expect(machine.launchd.loaded == false)
      #expect(try fixture.autoClear.read() == nil)
      #expect(try engine.setAutoClear(.off) == .alreadyOff)
      #expect(machine.writes == writes)
      #expect(try engine.status().history.enabled)

      machine.now = machine.now.addingTimeInterval(Self.day * 3)
      #expect(try engine.setAutoClear(.on) == .turnedOn)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
      #expect(try engine.setAutoClear(.on) == .alreadyOn)
      #expect(machine.writes == writes)
      #expect(machine.log.isEmpty)
    }
  }

  @Test func autoClearOnLoadsAnUnloadedAgentAndAdoptsItsOwnPlist() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      let record = ClipboardAutoClearRecord(
        lastClear: machine.now.addingTimeInterval(-3_600), lastFailure: nil)
      try fixture.writeAutoClear(record)
      _ = try engine.agent.install()

      #expect(try engine.setAutoClear(.on) == .turnedOn)
      #expect(machine.launchd.loaded)
      #expect(try fixture.autoClear.read() == record)
    }
  }

  @Test func autoClearOnNeedsClearingEnabled() throws {
    try withEngine { engine, machine, fixture throws in
      machine.settings = [.clearOnQuit: true, .clearSystemClipboard: true]
      let error = #expect(throws: ClipboardHistoryError.self) { try engine.setAutoClear(.on) }
      #expect(error?.description.contains("Run `macarchy clipboard enable` first") == true)
      #expect(try engine.agent.file() == .absent)
      #expect(try fixture.autoClear.read() == nil)
      #expect(machine.launchd.calls.isEmpty)
    }
  }

  @Test func aLaunchAgentMacarchyDidNotWriteStopsOnAndOffAndIsLeftAlone() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      let plist = engine.agent.plistURL
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("custom".utf8).write(to: plist)
      machine.launchd.state.withLock { $0.loaded = true }

      let conflict = "is not the launch agent this Macarchy writes"
      for request in ClipboardAutoClearSwitch.allCases {
        let error = #expect(throws: ClipboardHistoryError.self) {
          try engine.setAutoClear(request)
        }
        #expect(error?.description.contains(conflict) == true)
      }
      // Enable still changes Maccy's settings and reports both outcomes. Disable keeps them,
      // because the job loaded under this label may still clear on their strength.
      let enable = #expect(throws: ClipboardHistoryError.self) {
        try engine.enableWithAutoClear()
      }
      #expect(
        enable?.description
          == ClipboardIntegrationChange.alreadyEnabled.message + "\n"
          + engine.agent.conflict.description)
      let disable = #expect(throws: ClipboardHistoryError.self) {
        try engine.disableWithAutoClear()
      }
      #expect(disable?.description.hasPrefix(engine.agent.conflict.description + "\n") == true)
      #expect(disable?.description.contains("clearSystemClipboard stay on") == true)
      #expect(try fixture.record.read() != nil)
      #expect(machine.settings == [.clearOnQuit: true, .clearSystemClipboard: true])
      #expect(try String(contentsOf: plist, encoding: .utf8) == "custom")
      #expect(machine.launchd.loaded)
      #expect(machine.launchd.calls.allSatisfy { $0.first == "print" })
      #expect(try fixture.autoClear.read() == nil)
      let status = try engine.status()
      #expect(status.autoClear.agent == .conflict(plist))
      #expect(status.message.contains("Automatic clear is off because \(plist.path)"))
    }
  }

  @Test func disableKeepsTheSettingsWhileTheAgentCannotBeUnloaded() throws {
    try withEngine { engine, machine, fixture throws in
      _ = try engine.enableWithAutoClear()
      machine.launchd.state.withLock { $0.bootoutStatus = 5 }

      let error = #expect(throws: ClipboardHistoryError.self) {
        try engine.disableWithAutoClear()
      }
      #expect(error?.description.contains("Boot-out failed: 5") == true)
      #expect(error?.description.contains("clearSystemClipboard stay on") == true)
      #expect(machine.launchd.loaded)
      #expect(machine.settings == [.clearOnQuit: true, .clearSystemClipboard: true])
      #expect(try fixture.record.read() != nil)

      machine.launchd.state.withLock { $0.bootoutStatus = 0 }
      #expect(try engine.disableWithAutoClear().hasPrefix("Automatic clear off.\n"))
      #expect(machine.settings.isEmpty)
      #expect(try fixture.record.read() == nil)
    }
  }

  @Test func theFirstAutomaticRunStartsTheWindowWithoutClearing() throws {
    try withEngine { engine, machine, fixture throws in
      machine.running = true
      #expect(try engine.runAutoClear() == .windowStarted)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
      #expect(machine.log.isEmpty)
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func anAutomaticRunBeforeTheWindowEndsChangesNothing() throws {
    try withEngine { engine, machine, fixture throws in
      let record = ClipboardAutoClearRecord(
        lastClear: machine.now.addingTimeInterval(1 - Self.day), lastFailure: nil)
      try fixture.writeAutoClear(record)
      machine.running = true

      #expect(try engine.runAutoClear() == .notDue)
      #expect(try fixture.autoClear.read() == record)
      #expect(machine.log.isEmpty)
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func aDueRunQuitsARunningMaccyEmptiesTheClipboardAndStartsItAgain() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.writeAutoClear(
        Self.cleared(machine.now.addingTimeInterval(-Self.day)))
      try fixture.sealContainer()
      machine.running = true
      machine.exitAfterPauses = 2

      let run = try engine.runAutoClear()
      #expect(run == .cleared(maccyWasRunning: true))
      #expect(
        run.message
          == "Automatic clear: cleared unpinned history and the clipboard. Maccy restarted.")
      #expect(machine.log == ["quit", "exited", "clear pasteboard", "open background"])
      #expect(machine.running)
      #expect(machine.reads == 0)
      #expect(machine.writes == 0)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
    }
  }

  @Test func aDueRunStartsAClosedMaccyForItsOwnClearAndClosesItAgain() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.writeAutoClear(
        Self.cleared(machine.now.addingTimeInterval(-Self.day * 2)))
      try fixture.sealContainer()

      #expect(try engine.runAutoClear() == .cleared(maccyWasRunning: false))
      #expect(machine.log == ["open background", "quit", "exited", "clear pasteboard"])
      #expect(machine.running == false)
      #expect(machine.reads == 0)
      #expect(machine.writes == 0)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
    }
  }

  @Test func aMaccyThatDoesNotQuitFailsTheRunAndAlertsOncePerWindow() throws {
    try withEngine { engine, machine, fixture throws in
      let lastClear = machine.now.addingTimeInterval(-Self.day)
      try fixture.writeAutoClear(Self.cleared(lastClear))
      machine.running = true
      machine.exitAfterPauses = nil

      let first = try #require(try engine.runAutoClear().failure)
      #expect(first.message.contains("Maccy did not quit within five seconds"))
      #expect(first.alert)
      #expect(machine.log == ["quit"])
      #expect(machine.pasteboardClears == 0)
      let failed = try #require(try fixture.autoClear.read())
      #expect(failed.lastClear == lastClear)
      #expect(failed.lastFailure?.date == machine.now)
      #expect(failed.lastFailure?.message == first.message)

      let alerted = machine.now
      machine.now = alerted.addingTimeInterval(3_600)
      #expect(try engine.runAutoClear().failure?.alert == false)
      #expect(try fixture.autoClear.read()?.lastFailure?.date == machine.now)
      machine.now = alerted.addingTimeInterval(Self.day)
      #expect(try engine.runAutoClear().failure?.alert == true)
      #expect(try fixture.autoClear.read()?.lastClear == lastClear)

      machine.exitAfterPauses = 0
      machine.now = machine.now.addingTimeInterval(3_600)
      #expect(try engine.runAutoClear() == .cleared(maccyWasRunning: true))
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
    }
  }

  @Test func aMaccyThatDoesNotStartFailsTheRun() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.writeAutoClear(
        Self.cleared(machine.now.addingTimeInterval(-Self.day)))
      machine.startsWhenOpened = false

      let failure = try #require(try engine.runAutoClear().failure)
      #expect(failure.message.contains("Maccy did not start within five seconds"))
      #expect(machine.log == ["open background"])
      #expect(machine.pasteboardClears == 0)
    }
  }

  @Test func aMissingMaccyFailsEveryRunButAlertsAtMostOnceADay() throws {
    try withEngine { engine, machine, fixture throws in
      machine.installation = .missing
      try fixture.writeAutoClear(
        Self.cleared(machine.now.addingTimeInterval(-Self.day)))
      let start = machine.now

      let first = try #require(try engine.runAutoClear().failure)
      #expect(first.message == Self.missing)
      #expect(first.alert)
      var alerts = 0
      for hour in 1..<24 {
        machine.now = start.addingTimeInterval(TimeInterval(hour) * 3_600)
        if try engine.runAutoClear().failure?.alert != false { alerts += 1 }
      }
      #expect(alerts == 0)
      machine.now = start.addingTimeInterval(Self.day)
      #expect(try engine.runAutoClear().failure?.alert == true)
      #expect(machine.log.isEmpty)
    }
  }

  @Test func aDamagedWindowRecordFailsLoudlyUntilAutoClearOnReplacesIt() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try Data("{".utf8).write(to: fixture.autoClear.url)
      machine.running = true

      let operations: [() throws -> Void] = [
        { _ = try engine.runAutoClear() }, { _ = try engine.status() },
      ]
      for operation in operations {
        let error = #expect(throws: ClipboardHistoryError.self) { try operation() }
        #expect(error?.description.contains("Run `macarchy clipboard auto-clear on`") == true)
      }
      #expect(try String(contentsOf: fixture.autoClear.url, encoding: .utf8) == "{")
      #expect(machine.log.isEmpty)

      #expect(try engine.setAutoClear(.on) == .turnedOn)
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
    }
  }

  @Test func aWindowStartedOverADayAheadIsDueSoAWrongClockCannotPostponeClears() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Self.cleared(now.addingTimeInterval(Self.day + 60)).isDue(at: now))
    // A clock corrected back by a few minutes causes no extra clear.
    #expect(Self.cleared(now.addingTimeInterval(60)).isDue(at: now) == false)
    #expect(Self.cleared(now.addingTimeInterval(-60)).isDue(at: now) == false)
  }

  @Test func aLongFailureMessageIsShortenedSoTheRecordStaysReadable() throws {
    try withEngine { _, machine, fixture throws in
      let long = String(repeating: "Maccy did not quit. ", count: 300)
      let failed = Self.cleared(machine.now).failing(long, at: machine.now).record
      #expect(failed.lastFailure?.message == String(long.prefix(500)))
      try fixture.writeAutoClear(failed)
      #expect(try fixture.autoClear.read() == failed)
    }
  }

  @Test func aManualClearRestartsTheWindowOnlyWhileTheAutomaticClearIsOn() throws {
    try withEngine { engine, machine, fixture throws in
      try fixture.enableClearing(machine)
      try fixture.writeStore()
      _ = try engine.clear()
      #expect(try fixture.autoClear.read() == nil)

      let failure = ClipboardAutoClearRecord.Failure(
        date: machine.now, message: "Maccy did not quit within five seconds", alerted: machine.now)
      try fixture.writeAutoClear(
        ClipboardAutoClearRecord(
          lastClear: machine.now.addingTimeInterval(-Self.day), lastFailure: failure))
      machine.now = machine.now.addingTimeInterval(60)
      #expect(try engine.clear() == .cleared(maccyWasRunning: false))
      #expect(try fixture.autoClear.read() == Self.cleared(machine.now))
    }
  }

  @Test func statusReportsTheAutomaticClearWithoutContent() throws {
    try withEngine { engine, machine, fixture throws in
      _ = try engine.enableWithAutoClear()
      let lastClear = machine.now.addingTimeInterval(-90_000)
      let failure = ClipboardAutoClearRecord.Failure(
        date: machine.now.addingTimeInterval(-3_600),
        message: "Maccy did not quit within five seconds",
        alerted: machine.now.addingTimeInterval(-3_600))
      try fixture.writeAutoClear(
        ClipboardAutoClearRecord(lastClear: lastClear, lastFailure: failure))

      let status = try engine.status()
      let json: String =
        #"{"autoClear":{"lastClear":"2027-01-14T07:00:00Z","#
        + #""lastFailure":{"date":"2027-01-15T07:00:00Z","#
        + #""message":"Maccy did not quit within five seconds"},"loaded":true,"#
        + #""nextDue":"2027-01-15T07:00:00Z","overdue":true,"state":"on"},"#
        + #""enabled":true,"installed":true,"running":false,"#
        + #""settings":{"clearOnQuit":true,"clearSystemClipboard":true},"#
        + #""supported":true,"version":"2.7.1"}"#
      #expect(try status.renderJSON() == json)
      let lines: [String] = [
        "Automatic clear is on.",
        Self.autoClearStatusDetail,
        "Last clear: \(Self.local(lastClear))",
        "Next automatic clear: within the hour",
        "Last automatic clear failed at \(Self.local(failure.date)): "
          + "Maccy did not quit within five seconds",
      ]
      #expect(status.autoClear.message == lines.joined(separator: "\n"))

      try fixture.writeAutoClear(
        Self.cleared(machine.now.addingTimeInterval(-3_600)))
      let next = try engine.status().autoClear.message
      let due = Self.local(machine.now.addingTimeInterval(Self.day - 3_600))
      #expect(next.hasSuffix("Next automatic clear: \(due)"))
      #expect(next.contains("failed") == false)

      machine.launchd.state.withLock { $0.loaded = false }
      let unloaded = try engine.status()
      #expect(
        unloaded.autoClear.message.hasPrefix(
          "Automatic clear is on, but its launch agent is not loaded"))
      #expect(unloaded.autoClear.message.contains("Next automatic clear") == false)
      #expect(try unloaded.renderJSON().contains(#""loaded":false"#))
    }
  }

  /// Maccy, its settings, the pasteboard, `open`, launchd and the clock, as the engine observes
  /// or changes them.
  private final class Machine {
    var installation = MaccyInstallation.installed(version: "2.7.1")
    var running = false
    /// nil never exits after a quit request.
    var exitAfterPauses: Int? = 0
    /// False leaves Maccy closed when it is opened.
    var startsWhenOpened = true
    var settings: [MaccySetting: Bool] = [:]
    var failingWrites: Set<MaccySetting> = []
    var reads = 0
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
    /// 2027-01-15T08:00:00Z.
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let launchd = ClipboardLaunchdFake()

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
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var record: RunStateRecord<MaccySettingsRecord> {
      ClipboardHistory.settingsRecord(stateRoot: state)
    }
    var autoClear: RunStateRecord<ClipboardAutoClearRecord> {
      ClipboardHistory.autoClearRecord(stateRoot: state)
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

    func writeAutoClear(_ value: ClipboardAutoClearRecord) throws {
      try FileManager.default.createDirectory(
        at: autoClear.directory, withIntermediateDirectories: true)
      try autoClear.write(value)
    }

    /// Replaces the container with an ordinary file, so any access to it throws.
    func sealContainer() throws {
      try FileManager.default.removeItem(at: container)
      try Data().write(to: URL(filePath: container.path, directoryHint: .notDirectory))
    }
  }

  private func withEngine(_ body: (ClipboardHistory, Machine, Fixture) throws -> Void) throws {
    let fixture = Fixture(
      root: FileManager.default.temporaryDirectory.appending(
        path: "macarchy-clipboard-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.container, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fixture.home.appending(path: "Library"), withIntermediateDirectories: true)
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
          if machine.startsWhenOpened { machine.running = true }
        }),
      defaults: MaccyDefaults(
        read: {
          machine.reads += 1
          return machine.settings[$0]
        },
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
      agent: ClipboardAutoClearAgent(
        home: fixture.home, stateRoot: fixture.state,
        executable: URL(filePath: "/opt/homebrew/bin/macarchy"), userID: 501,
        runner: machine.launchd.runner),
      clearPasteboard: {
        machine.pasteboardClears += 1
        machine.log.append("clear pasteboard")
      },
      pause: {
        machine.pauses += 1
        if machine.running, let limit = machine.exitAfterPauses, machine.pauses >= limit {
          machine.exit()
        }
      },
      now: { machine.now })
    try body(engine, machine, fixture)
  }
}

extension ClipboardAutoClearRun {
  fileprivate var failure: (message: String, alert: Bool)? {
    guard case .failed(let message, let alert) = self else { return nil }
    return (message, alert)
  }
}
