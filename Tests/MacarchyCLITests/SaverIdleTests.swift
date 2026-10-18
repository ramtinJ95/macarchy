import ArgumentParser
import Foundation
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

/// A temporary folder stands in for the home and state folders, a scripted runner for launchctl,
/// defaults and pmset, and a counter for the bar hint. No test reaches launchd, the real
/// ~/Library, macOS settings, SketchyBar, a symbolic link or a special file.
struct SaverIdleTests {
  @Test func onInstallsTheAgentRecordsTheDefaultTimeoutAndLoadsItOnce() throws {
    try withIdle { idle, machine throws in
      let change = try idle.turnOn(after: nil)
      #expect(change == .turnedOn(SaverIdleRecord(timeout: 300, paused: false)))
      #expect(
        change.message == "Idle screensaver on: it starts after 5 minutes idle. It is decorative, "
          + "not a lock.")
      #expect(try idle.agent.file() == .owned)
      #expect(machine.launchd.loaded)
      #expect(try machine.record.read() == SaverIdleRecord(timeout: 300, paused: false))
      let attributes = try FileManager.default.attributesOfItem(atPath: machine.record.url.path)
      #expect(attributes[.posixPermissions] as? Int == 0o600)
      #expect(machine.hints == 1)

      let again = try idle.turnOn(after: nil)
      #expect(again == .alreadyOn(SaverIdleRecord(timeout: 300, paused: false)))
      #expect(machine.launchd.calls.filter { $0.first == "bootstrap" }.count == 1)
      #expect(machine.hints == 1)
      #expect(try idle.activation().enabled == SaverIdleRecord(timeout: 300, paused: false))
    }
  }

  @Test func afterReplacesTheTimeoutWhileOnAndAPauseSurvivesOn() throws {
    try withIdle { idle, machine throws in
      _ = try idle.turnOn(after: .seconds(600))
      #expect(try machine.record.read()?.timeout == 600)
      #expect(try idle.apply(.pause) == .paused)

      let changed = try idle.turnOn(after: .seconds(1_800))
      #expect(changed == .turnedOn(SaverIdleRecord(timeout: 1_800, paused: true)))
      #expect(changed.message.hasSuffix("It is paused; run `macarchy saver resume` to resume it."))
      let kept = try idle.turnOn(after: nil)
      #expect(kept == .alreadyOn(SaverIdleRecord(timeout: 1_800, paused: true)))
      #expect(machine.launchd.calls.filter { $0.first == "bootstrap" }.count == 1)
    }
  }

  /// With KeepAlive only for unsuccessful exits, launchd leaves an observer that exited because
  /// its record vanished loaded but stopped.
  @Test func onRunsAgainAnObserverThatExitedWhileItsJobStayedLoaded() throws {
    try withIdle { idle, machine throws in
      _ = try idle.turnOn(after: nil)
      try machine.record.remove()
      machine.launchd.state.withLock { $0.running = false }
      #expect(
        try idle.status().message.hasPrefix(
          "Idle activation: incomplete, because its record is missing."))

      let change = try idle.turnOn(after: nil)
      #expect(change == .turnedOn(SaverIdleRecord(timeout: 300, paused: false)))
      #expect(machine.launchd.running)
      #expect(machine.launchd.calls.filter { $0.first == "bootstrap" }.count == 1)
      let kickstart = ["kickstart", "gui/501/io.github.ramtinj95.macarchy.saver-idle"]
      let kickstarts = machine.launchd.calls.filter { $0.first == "kickstart" }
      #expect(kickstarts.count == 2)
      #expect(kickstarts.allSatisfy { $0 == kickstart })
      #expect(try idle.status().message.hasPrefix("Idle activation: on;"))
    }
  }

  @Test func offBootsOutAndRemovesThePlistAndTheRecordIdempotently() throws {
    try withIdle { idle, machine throws in
      #expect(try idle.turnOff() == .alreadyOff)
      #expect(machine.hints == 0)
      _ = try idle.turnOn(after: nil)

      #expect(try idle.turnOff() == .turnedOff)
      #expect(try idle.agent.file() == .absent)
      #expect(machine.launchd.loaded == false)
      #expect(FileManager.default.fileExists(atPath: machine.record.url.path) == false)
      #expect(machine.launchd.calls.filter { $0.first == "bootout" }.count == 1)
      #expect(machine.hints == 2)

      #expect(try idle.turnOff() == .alreadyOff)
      #expect(machine.hints == 2)
      #expect(
        try idle.activation() == SaverIdleActivation(agent: .absent, loaded: false, record: nil))
    }
  }

  @Test func offRemovesARecordThatIsNotValid() throws {
    try withIdle { idle, machine throws in
      try FileManager.default.createDirectory(
        at: machine.record.directory, withIntermediateDirectories: true)
      try Data(#"{"timeout":5,"paused":false}"#.utf8).write(to: machine.record.url)
      #expect(try machine.record.read() == nil)

      #expect(try idle.turnOff() == .turnedOff)
      #expect(FileManager.default.fileExists(atPath: machine.record.url.path) == false)
    }
  }

  @Test func aFailedLoadLeavesOnRetryable() throws {
    try withIdle { idle, machine throws in
      machine.launchd.state.withLock { $0.bootstrapStatus = 5 }
      let error = #expect(throws: OwnedLaunchAgentError.self) { try idle.turnOn(after: nil) }
      #expect(error?.description.contains("Bootstrap failed: 5") == true)
      #expect(try idle.agent.file() == .owned)
      #expect(try machine.record.read() != nil)
      #expect(
        try idle.status().message.hasPrefix(
          "Idle activation: incomplete, because its launch agent is not loaded."))
      #expect(throws: SaverError.self) { try idle.apply(.pause) }

      machine.launchd.state.withLock { $0.bootstrapStatus = 0 }
      #expect(
        try idle.turnOn(after: nil) == .turnedOn(SaverIdleRecord(timeout: 300, paused: false)))
      #expect(machine.launchd.loaded)
    }
  }

  @Test func aLaunchAgentMacarchyDidNotWriteBlocksEveryChangeAndIsLeftAlone() throws {
    try withIdle { idle, machine throws in
      let plist = idle.agent.plistURL
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("custom".utf8).write(to: plist)
      machine.launchd.state.withLock { $0.loaded = true }

      let changes: [() throws -> Void] = [
        { _ = try idle.turnOn(after: nil) }, { _ = try idle.turnOff() },
        { _ = try idle.apply(.pause) }, { _ = try idle.apply(.toggle) },
      ]
      for change in changes {
        let error = #expect(throws: OwnedLaunchAgentError.self) { try change() }
        #expect(error?.description.contains("is not the launch agent this Macarchy writes") == true)
      }
      #expect(try String(contentsOf: plist, encoding: .utf8) == "custom")
      #expect(machine.launchd.loaded)
      #expect(machine.launchd.calls.allSatisfy { $0.first == "print" })
      #expect(try machine.record.read() == nil)
      #expect(machine.hints == 0)
      let status = try idle.status()
      #expect(status.activation.agent == .conflict(plist))
      #expect(status.message.hasPrefix("Idle activation: off, because \(plist.path) is not"))
    }
  }

  @Test(arguments: [SaverPauseRequest.pause, .resume, .toggle])
  func pauseAndResumeNeedIdleActivationOn(request: SaverPauseRequest) throws {
    try withIdle { idle, machine throws in
      let off = #expect(throws: SaverError.self) { try idle.apply(request) }
      #expect(off?.description.contains("`macarchy saver idle on`") == true)

      _ = try idle.turnOn(after: nil)
      machine.launchd.state.withLock { $0.loaded = false }
      let unloaded = #expect(throws: SaverError.self) { try idle.apply(request) }
      #expect(unloaded?.description.contains("`macarchy saver idle on`") == true)
      #expect(try machine.record.read()?.paused == false)
      #expect(machine.hints == 1)
    }
  }

  @Test func pauseResumeAndToggleChangeOnlyThePauseAndHintTheBarOnChange() throws {
    try withIdle { idle, machine throws in
      _ = try idle.turnOn(after: .seconds(900))
      #expect(machine.hints == 1)

      #expect(try idle.apply(.pause) == .paused)
      #expect(try machine.record.read() == SaverIdleRecord(timeout: 900, paused: true))
      #expect(try idle.activation().enabled?.paused == true)
      #expect(machine.hints == 2)
      #expect(try idle.apply(.pause) == .alreadyPaused)
      #expect(machine.hints == 2)

      #expect(try idle.apply(.toggle) == .resumed)
      #expect(try machine.record.read() == SaverIdleRecord(timeout: 900, paused: false))
      #expect(try idle.apply(.resume) == .alreadyResumed)
      #expect(try idle.apply(.toggle) == .paused)
      #expect(try idle.apply(.resume) == .resumed)
      #expect(machine.hints == 5)
      #expect(machine.launchd.calls.filter { $0.first == "bootstrap" }.count == 1)
    }
  }

  @Test func statusReportsActivationTheNativeTimersAndTheirWarnings() throws {
    try withIdle { idle, machine throws in
      machine.timers = SaverNativeTimers(
        screensaver: .after(1_200), displaySleep: .unreadable("pmset exited with status 1"))
      let off = try idle.status()
      #expect(
        off.message
          == """
          Idle activation: off. Run `macarchy saver idle on` to start the screensaver after 5 \
          minutes idle.
          macOS screensaver: after 20 minutes idle
          Display sleep: unknown, because pmset exited with status 1
          """)

      _ = try idle.turnOn(after: .seconds(1_800))
      _ = try idle.apply(.pause)
      let paused = try idle.status()
      let lines = paused.message.split(separator: "\n").map(String.init)
      #expect(
        lines.first
          == "Idle activation: on; the screensaver starts after 30 minutes idle. Paused: run "
          + "`macarchy saver resume` or click the pause icon left of the clock.")
      #expect(lines.count == 4)
      #expect(
        lines.last?.hasPrefix("Warning: the macOS screensaver starts after 20 minutes") == true)

      let document = try jsonObject(
        try SaverReport(saver: Self.saverStatus, idle: paused).renderJSON())
      let json = try #require(document["idle"] as? [String: Any])
      #expect(json["state"] as? String == "on")
      #expect(json["loaded"] as? Bool == true)
      #expect(json["timeout"] as? Int == 1_800)
      #expect(json["paused"] as? Bool == true)
      let screensaver = try #require(json["nativeScreensaver"] as? [String: Any])
      #expect(screensaver["state"] as? String == "after")
      #expect(screensaver["seconds"] as? Int == 1_200)
      #expect(screensaver["error"] is NSNull)
      let display = try #require(json["displaySleep"] as? [String: Any])
      #expect(display["state"] as? String == "unreadable")
      #expect(display["seconds"] is NSNull)
      #expect(display["error"] as? String == "pmset exited with status 1")
      let warnings = try #require(json["warnings"] as? [String])
      #expect(warnings == paused.warnings)
      #expect(warnings.count == 1)
    }
  }

  @Test(arguments: ["record-only", "record-missing", "not-loaded"])
  func statusNamesWhatAnIncompleteActivationLacks(state: String) {
    let record = SaverIdleRecord(timeout: 300, paused: false)
    let activation =
      switch state {
      case "record-only": SaverIdleActivation(agent: .absent, loaded: false, record: record)
      case "record-missing": SaverIdleActivation(agent: .owned, loaded: true, record: nil)
      default: SaverIdleActivation(agent: .owned, loaded: false, record: record)
      }
    let missing =
      switch state {
      case "record-only": "its launch agent is missing"
      case "record-missing": "its record is missing"
      default: "its launch agent is not loaded"
      }
    let status = SaverIdleStatus(
      activation: activation, timers: SaverNativeTimers(screensaver: .never, displaySleep: .never))
    #expect(activation.enabled == nil)
    #expect(
      status.message.hasPrefix(
        "Idle activation: incomplete, because \(missing). Run `macarchy saver idle on` to finish "
          + "turning it on, or `macarchy saver idle off` to remove it."))
  }

  @Test func aNativeTimerNoLaterThanTheTimeoutWarns() {
    let screensaver = SaverNativeTimers(screensaver: .after(300), displaySleep: .never)
    let display = SaverNativeTimers(screensaver: .never, displaySleep: .after(300))
    let cases: [(timeout: Int, warnings: Int)] = [(240, 0), (299, 0), (300, 1), (360, 1)]
    for (timeout, expected) in cases {
      #expect(screensaver.warnings(timeout: timeout).count == expected)
      #expect(display.warnings(timeout: timeout).count == expected)
    }
    let displayWarning = display.warnings(timeout: 300).first ?? ""
    #expect(displayWarning.hasPrefix("Warning: the display turns off after 5 minutes idle"))
    #expect(displayWarning.contains("Lock Screen, set Turn display off when inactive"))
    let saverWarning = screensaver.warnings(timeout: 300).first ?? ""
    #expect(saverWarning.hasPrefix("Warning: the macOS screensaver starts after 5 minutes idle"))
    #expect(saverWarning.contains("Lock Screen, set Start Screen Saver when inactive"))
  }

  @Test func neverUnsetAndUnreadableTimersNeverWarn() {
    let timers = SaverNativeTimers(screensaver: .never, displaySleep: .unreadable("pmset failed"))
    #expect(timers.warnings(timeout: 14_400).isEmpty)
    let unset = SaverNativeTimers(screensaver: .notSet, displaySleep: .never)
    #expect(unset.warnings(timeout: 14_400).isEmpty)
    let both = SaverNativeTimers(screensaver: .after(60), displaySleep: .after(60))
    #expect(both.warnings(timeout: 60).count == 2)
  }

  @Test func theNativeScreensaverTimerIsReadOnlyWithDefaults() {
    let replies: [(status: Int32, output: String, timer: NativeIdleTimer)] = [
      (0, "1200\n", .after(1_200)), (0, "0\n", .never),
      (1, "The domain/default pair of (com.apple.screensaver, idleTime) does not exist", .notSet),
      (1, "defaults: permission denied", .unreadable("defaults exited with status 1")),
      (0, "soon", .unreadable("defaults did not report a whole number of seconds")),
    ]
    for (status, output, expected) in replies {
      let requests = Mutex([ProcessRequest]())
      let timer = SaverNativeTimers.screensaver(
        processRunner: ProcessRunner { request in
          requests.withLock { $0.append(request) }
          return ProcessResult(terminationStatus: status, output: output)
        })
      #expect(timer == expected)
      let request = requests.withLock { $0.first }
      #expect(request?.executableURL.path == "/usr/bin/defaults")
      #expect(request?.arguments == ["-currentHost", "read", "com.apple.screensaver", "idleTime"])
      #expect(request?.timeout == 5)
    }
  }

  /// macOS may apply its own default to a screensaver timer that was never set.
  @Test func statusReportsAnUnsetScreensaverTimerAsUnsetNotNever() throws {
    let status = SaverIdleStatus(
      activation: SaverIdleActivation(agent: .absent, loaded: false, record: nil),
      timers: SaverNativeTimers(screensaver: .notSet, displaySleep: .never))
    let lines = status.message.split(separator: "\n").map(String.init)
    try #require(lines.count == 3)
    #expect(lines[1].hasPrefix("macOS screensaver: not set explicitly, so macOS may apply its own"))
    #expect(lines[1].hasSuffix("in System Settings > Lock Screen"))
    let screensaver = try #require(status.json["nativeScreensaver"] as? [String: Any])
    #expect(screensaver["state"] as? String == "notSet")
    #expect(screensaver["seconds"] is NSNull)
    #expect(screensaver["error"] is NSNull)
  }

  @Test func displaySleepIsReadOnlyWithPmset() {
    let replies: [(output: String, timer: NativeIdleTimer)] = [
      (" displaysleep         10\n disksleep            10\n", .after(600)),
      (" displaysleep         0\n", .never),
      (" displaysleep 15 (display sleep prevented by coreaudiod)\n", .after(900)),
      (" sleep 1\n", .unreadable("pmset did not report displaysleep")),
      (
        " displaysleep soon\n",
        .unreadable("pmset did not report displaysleep as a whole number of minutes")
      ),
    ]
    for (output, expected) in replies {
      let requests = Mutex([ProcessRequest]())
      let timer = SaverNativeTimers.displaySleep(
        processRunner: ProcessRunner { request in
          requests.withLock { $0.append(request) }
          return ProcessResult(
            terminationStatus: 0, output: "System-wide power settings:\n" + output)
        })
      #expect(timer == expected)
      let request = requests.withLock { $0.first }
      #expect(request?.executableURL.path == "/usr/bin/pmset")
      #expect(request?.arguments == ["-g"])
      #expect(request?.timeout == 5)
    }
  }

  @Test func timersThatCannotBeReadAreReportedNotFatal() {
    let timedOut = ProcessRunner { request in
      throw ProcessRunnerError.timedOut(request.executableURL, 5)
    }
    let timers = SaverNativeTimers.read(processRunner: timedOut)
    #expect(timers.screensaver.summary.hasPrefix("unknown, because defaults failed: Process"))
    #expect(timers.displaySleep.summary.hasPrefix("unknown, because pmset failed: Process"))
    #expect(timers.warnings(timeout: 14_400).isEmpty)
    let failing = ProcessRunner { _ in ProcessResult(terminationStatus: 1, output: "") }
    #expect(
      SaverNativeTimers.displaySleep(processRunner: failing)
        == .unreadable("pmset exited with status 1"))
  }

  @Test func timeoutsAcceptOneMinuteToFourHours() throws {
    let accepted: [(text: String, seconds: Int)] = [
      ("1m", 60), ("5m", 300), ("1h30m", 5_400), ("4h", 14_400),
    ]
    for (text, seconds) in accepted {
      #expect(try SaverIdle.timeout.parse(text) == .seconds(seconds))
    }
  }

  @Test(arguments: ["0m", "4h1m", "241m", "5h", "30s", "5", "", "m", "1.5h"])
  func timeoutsRejectAnythingElse(text: String) {
    let error = #expect(throws: ValidationError.self) { try SaverIdle.timeout.parse(text) }
    #expect(
      error?.message
        == "--after takes a duration from 1m to 4h, such as 30m, 2h or 1h30m; got '\(text)'")
  }

  @Test func commandsParse() throws {
    let on = try SaverCommand.Idle.On.parse(["--after", "30m"])
    #expect(on.timeout == Duration.seconds(1_800))
    #expect(try SaverCommand.Idle.On.parse([]).timeout == nil)
    #expect(throws: (any Error).self) { try SaverCommand.Idle.On.parse(["--after", "5h"]) }
    #expect(try SaverCommand.TogglePause.parse(["--alert-on-error"]).options.alertOnError)
    #expect(try SaverCommand.Status.parse(["--json"]).json)
    #expect(try Macarchy.parseAsRoot(["saver", "idle", "on"]) is SaverCommand.Idle.On)
    #expect(try Macarchy.parseAsRoot(["saver", "idle", "off"]) is SaverCommand.Idle.Off)
    #expect(try Macarchy.parseAsRoot(["saver", "pause"]) is SaverCommand.Pause)
    #expect(try Macarchy.parseAsRoot(["saver", "resume"]) is SaverCommand.Resume)
    #expect(try Macarchy.parseAsRoot(["saver", "toggle-pause"]) is SaverCommand.TogglePause)
    let alert = try SaverCommand.Observe.parse([
      "--state-root", "/Users/test/state", "--alert=-Kitty is missing",
    ])
    #expect(alert.alert == "-Kitty is missing")
  }

  private static let saverStatus = SaverStatus(
    engine: SaverEngine(url: URL(filePath: "/opt/homebrew/libexec/ttfx"), defect: nil),
    kitty: .present(version: "0.49.0"),
    textFile: URL(filePath: "/Users/me/.config/macarchy/screensaver.txt"),
    text: .banner(rejected: nil), sessions: [])

  private func withIdle(_ body: (SaverIdle, IdleCLIMachine) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-saver-idle-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: "Library"), withIntermediateDirectories: true)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let machine = IdleCLIMachine(stateRoot: state)
    let idle = SaverIdle(
      stateRoot: state,
      agent: .saverIdle(
        home: home, stateRoot: state, executable: URL(filePath: "/opt/homebrew/bin/macarchy"),
        userID: 501, runner: machine.launchd.runner),
      nativeTimers: { machine.timers },
      notifyBar: { machine.hints += 1 })
    try body(idle, machine)
  }
}

/// launchd, the native timers and the bar hint, as idle activation observes or causes them.
private final class IdleCLIMachine {
  let launchd = LaunchdFake()
  let record: RunStateRecord<SaverIdleRecord>
  var timers = SaverNativeTimers(screensaver: .never, displaySleep: .never)
  var hints = 0

  init(stateRoot: URL) {
    record = SaverIdleRecord.runState(stateRoot: stateRoot)
  }
}
