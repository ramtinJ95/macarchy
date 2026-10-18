import Foundation
import Testing

@testable import MacarchyCLI

// Saver tests drive every process, panel, signal and terminal through injected seams: they never
// start Kitty, open, ttfx or a shell, never signal a real process and never change the test
// process's terminal. Files are regular files and directories in a temporary directory.

struct SaverInstallationTests {
  @Test(arguments: ["present", "absent", "directory", "not-executable"])
  func engineMustBeARegularExecutableBesideTheBinDirectory(layout: String) throws {
    try withTemporaryDirectory { root in
      let prefix = root.appending(path: "Cellar/macarchy/0.14.0", directoryHint: .isDirectory)
      let binary = prefix.appending(path: "bin/macarchy")
      let engine = prefix.appending(path: "libexec/ttfx")
      try writeFile("", to: binary, permissions: 0o755)
      switch layout {
      case "present": try writeFile("", to: engine, permissions: 0o755)
      case "directory":
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
      case "not-executable": try writeFile("", to: engine, permissions: 0o644)
      default: break
      }

      let located = SaverEngine.locate(executable: binary, resolve: { $0 })

      let expected: SaverEngineDefect? =
        switch layout {
        case "absent": .absent
        case "directory": .notRegularFile
        case "not-executable": .notExecutable
        default: nil
        }
      #expect(located.url.path == engine.path)
      #expect(located.defect == expected)
    }
  }

  @Test func symlinkedEntryPointFindsTheEngineBesideThePhysicalBinary() throws {
    try withTemporaryDirectory { root in
      let physical = root.appending(path: "Cellar/macarchy/0.14.0/bin/macarchy")
      let engine = root.appending(path: "Cellar/macarchy/0.14.0/libexec/ttfx")
      try writeFile("", to: physical, permissions: 0o755)
      try writeFile("", to: engine, permissions: 0o755)
      let link = URL(filePath: "/opt/homebrew/bin/macarchy")

      let located = SaverEngine.locate(executable: link) { $0 == link ? physical : $0 }

      #expect(located.url.path == engine.path)
      #expect(located.defect == nil)
    }
  }

  @Test func kittyIsPresentOnlyWithItsExecutableAndReportsItsVersion() throws {
    try withTemporaryDirectory { root in
      let application = root.appending(path: "kitty.app", directoryHint: .isDirectory)
      #expect(SaverKitty.inspect(application: application) == .missing)

      try writeFile("", to: application.appending(path: "Contents/MacOS/kitty"), permissions: 0o755)
      #expect(SaverKitty.inspect(application: application) == .present(version: nil))

      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": "0.49.0"], format: .xml, options: 0)
      try info.write(to: application.appending(path: "Contents/Info.plist"))
      #expect(SaverKitty.inspect(application: application) == .present(version: "0.49.0"))
    }
  }

  @Test func statusNamesTheEngineKittyAndTheirRemedies() throws {
    let engine = URL(filePath: "/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx")
    let ready = SaverStatus(
      engine: SaverEngine(url: engine, defect: nil), kitty: .present(version: "0.49.0"))
    let missing = SaverStatus(
      engine: SaverEngine(url: engine, defect: .absent), kitty: .missing)

    #expect(
      try ready.renderJSON()
        == #"{"engine":{"path":"/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx","reason":null,"#
        + #""remedy":null,"state":"present"},"kitty":{"path":"/Applications/kitty.app","#
        + #""remedy":null,"state":"present","version":"0.49.0"},"running":false,"sessions":[]}"#)
    let document = try jsonObject(try missing.renderJSON())
    let engineDocument = try #require(document["engine"] as? [String: Any])
    let kittyDocument = try #require(document["kitty"] as? [String: Any])
    #expect(engineDocument["state"] as? String == "missing")
    #expect(engineDocument["reason"] as? String == "absent")
    #expect(engineDocument["remedy"] as? String == SaverEngine.remedy)
    #expect(kittyDocument["state"] as? String == "missing")
    #expect(kittyDocument["version"] is NSNull)
    #expect(kittyDocument["remedy"] as? String == SaverKitty.remedy)
    #expect(document["running"] as? Bool == false)

    #expect(
      ready.message
        == """
        ttfx engine: present at \(engine.path)
        Kitty: 0.49.0 at /Applications/kitty.app
        Screensaver: not running
        """)
    #expect(missing.message.contains("missing at \(engine.path) (not found)"))
    #expect(missing.message.contains("brew reinstall ramtinj95/tap/macarchy"))
    #expect(missing.message.contains("brew install --cask kitty"))
  }
}

struct SaverTextTests {
  @Test func missingFileShowsTheBannerWithoutANotice() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      #expect(file.path == root.appending(path: "screensaver.txt").path)
      #expect(SaverText.read(file) == .absent)
      #expect(SaverText.read(root.appending(path: "missing/screensaver.txt")) == .absent)

      let text = SaverText.choose(.absent)
      #expect(text == .banner(rejected: nil))
      #expect(text.content == SaverText.bannerText)
      #expect(text.notice(textFile: file) == nil)
    }
  }

  @Test func customTextKeepsNewlinesAndTabsAndDropsOtherControlCharacters() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      let contents = Data("Back at\t3 pm\r\n\u{1B}[31mbye\u{7}".utf8)
      try contents.write(to: file)

      let found = SaverText.read(file)

      #expect(found == .contents(contents))
      #expect(SaverText.choose(found) == .custom("Back at\t3 pm\n[31mbye"))
      #expect(SaverText.choose(found).notice(textFile: file) == nil)
    }
  }

  @Test func textUpToTheLimitIsUsed() throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      try Data(repeating: 0x61, count: SaverText.maximumSize).write(to: file)

      let text = SaverText.choose(SaverText.read(file))

      #expect(text.content.count == SaverText.maximumSize)
    }
  }

  @Test(arguments: [
    "symbolic-link", "directory", "too-large", "invalid-utf8", "blank", "unreadable",
  ])
  func unusableFileFallsBackToTheBannerAndSaysWhy(kind: String) throws {
    try withTemporaryDirectory { root in
      let file = SaverText.fileURL(stateRoot: root)
      let found: SaverTextFile
      switch kind {
      // The reader opens without following links; tests never create one.
      case "symbolic-link": found = .symbolicLink
      case "directory":
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        found = SaverText.read(file)
        #expect(found == .notRegularFile)
      case "too-large":
        try Data(repeating: 0x61, count: SaverText.maximumSize + 1).write(to: file)
        found = SaverText.read(file)
        #expect(found == .tooLarge)
      case "invalid-utf8": found = .contents(Data([0x48, 0xFF, 0xFE]))
      case "blank": found = .contents(Data(" \n\t\u{7}".utf8))
      default: found = .unreadable("errno 13")
      }
      let reason =
        switch kind {
        case "symbolic-link": "it is a symbolic link"
        case "directory": "it is not a regular file"
        case "too-large": "it is larger than 64 KiB"
        case "invalid-utf8": "it is not valid UTF-8"
        case "blank": "it contains no visible text"
        default: "it cannot be read (errno 13)"
        }

      let text = SaverText.choose(found)

      #expect(text == .banner(rejected: reason))
      #expect(text.content == SaverText.bannerText)
      #expect(
        text.notice(textFile: file)
          == "Showing the Macarchy banner: \(file.path) is not used because \(reason).")
    }
  }
}

struct SaverRecordsTests {
  @Test func recordNamesStayInsideTheRecordsDirectory() {
    let names = [SaverDisplay.main, .output("DP-1"), .output("HDMI-1"), .output("../../etc/x")]
      .map(\.recordName)

    #expect(names[0] == "main.json")
    #expect(Set(names).count == names.count)
    for name in names.dropFirst() {
      #expect(name.hasPrefix("output-") && name.hasSuffix(".json"))
      #expect(name.count == "output-".count + 16 + ".json".count)
      #expect(!name.contains("/"))
    }
  }
}

struct SaverRunnerTests {
  @Test func ttfxArgumentsPutTerminalOptionsBeforeTheEffectAndCarryNoText() {
    let expected = [
      "--frame-rate", "30", "--canvas-width", "0", "--canvas-height", "0", "--anchor-canvas", "c",
      "--anchor-text", "c", "--reuse-canvas", "--no-eol", "--no-restore-cursor",
      "--terminal-background-color", "#1a1b26", "beams", "--final-gradient-stops", "#7aa2f7",
      "#7dcfff", "#c0caf5",
    ]

    #expect(SaverRunner.arguments(effect: "beams", palette: SaverFixture.palette) == expected)
    #expect(SaverRunner.effects.count == 34)
    #expect(Set(SaverRunner.effects).count == SaverRunner.effects.count)
    for excluded in ["matrix", "thunderstorm", "synthgrid"] {
      #expect(!SaverRunner.effects.contains(excluded))
    }
  }

  @Test func inputEndsTheSessionAfterEffectsThatNeverRepeatBackToBack() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      machine.script(.engineExited(0), at: 4)
      machine.script(.input, at: 6)

      #expect(machine.runner().run() == 0)

      #expect(machine.randomBounds == [34, 33])
      let expectedArguments = [
        SaverRunner.arguments(effect: "beams", palette: SaverFixture.palette),
        SaverRunner.arguments(effect: "binarypath", palette: SaverFixture.palette),
      ]
      #expect(machine.startedArguments == expectedArguments)
      #expect(machine.inputs == ["Back soon", "Back soon"])
      #expect(!machine.startedArguments.joined().contains("Back soon"))
      #expect(machine.stopped == [902])
      #expect(machine.screen == ["prepare", "restore"])
      let expectedRecords: [SaverRunnerRecord?] = [machine.identity, machine.identity]
      #expect(machine.recorded == expectedRecords)
      #expect(try SaverRecords(stateRoot: root).record(.output("DP-1")).read() == nil)
    }
  }

  @Test func inputWhileThePanelSettlesIsIgnored() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      machine.script(.input, at: 0.4)
      machine.script(.timeout, at: 0.8)
      machine.script(.input, at: 1.2)

      #expect(machine.runner().run() == 0)

      #expect(machine.startedArguments.count == 1)
      #expect(machine.stopped == [901])
      #expect(machine.waits.count == 3)
    }
  }

  @Test func signalEndsTheSessionEvenWhileThePanelSettles() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      machine.script(.terminate, at: 0.2)

      #expect(machine.runner().run() == 0)

      #expect(machine.stopped == [901])
      #expect(machine.screen == ["prepare", "restore"])
      #expect(try SaverRecords(stateRoot: root).record(.output("DP-1")).read() == nil)
    }
  }

  @Test func ttfxFailureIsShownThenTheSessionEndsWithAnError() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      machine.script(.engineExited(0), at: 3)
      machine.script(.engineExited(2), at: 5)
      machine.script(.timeout, at: 10)

      #expect(machine.runner().run() == 1)

      let expectedScreen = [
        "prepare", "Macarchy screensaver stopped: ttfx binarypath exited with status 2", "restore",
      ]
      #expect(machine.screen == expectedScreen)
      let expectedWaits: [Duration?] = [nil, nil, .seconds(5)]
      #expect(machine.waits == expectedWaits)
      #expect(machine.stopped.isEmpty)
      #expect(try SaverRecords(stateRoot: root).record(.output("DP-1")).read() == nil)
    }
  }

  @Test func ttfxThatCannotStartIsShownThenTheSessionEndsWithAnError() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      machine.startFails = true
      machine.script(.input, at: 2)

      #expect(machine.runner().run() == 1)

      let expectedScreen = [
        "prepare", "Macarchy screensaver stopped: cannot start ttfx: exec format error", "restore",
      ]
      #expect(machine.screen == expectedScreen)
      let expectedWaits: [Duration?] = [.seconds(5)]
      #expect(machine.waits == expectedWaits)
    }
  }

  @Test(arguments: ["another-launch", "no-launch", "display-taken"])
  func runnerOutsideTheCurrentLaunchClosesWithoutPlayingOrSignalling(kind: String) throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root, opensLaunch: kind == "display-taken")
      let records = SaverRecords(stateRoot: root)
      try records.create()
      if kind == "another-launch" {
        try records.launch.write(
          SaverLaunch(token: String(repeating: "f", count: 32), created: SaverFixture.created))
      }
      let sibling = SaverFixture.session(810, "HDMI-1", macarchy: machine.macarchy)
      try records.record(.output("HDMI-1")).write(sibling)
      let taken = SaverFixture.session(850, "DP-1", macarchy: machine.macarchy)
      if kind == "display-taken" { try records.record(.output("DP-1")).write(taken) }
      machine.processes = [800: machine.identity.runner, 810: sibling.runner]

      #expect(machine.runner().run() == 1)

      #expect(machine.screen == [RunnerMachine.refusal])
      #expect(machine.waits.isEmpty)
      #expect(machine.startedArguments.isEmpty)
      #expect(machine.terminated.isEmpty)
      #expect(try records.record(.output("HDMI-1")).read() == sibling)
      let expected: SaverRunnerRecord? = kind == "display-taken" ? taken : nil
      #expect(try records.record(.output("DP-1")).read() == expected)
    }
  }

  @Test func endingRemovesTheDisplayRecordOnlyWhileItNamesThisRunner() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      let records = SaverRecords(stateRoot: root)
      let other = SaverFixture.session(850, "DP-1", macarchy: machine.macarchy)
      machine.duringPlay = { try records.record(.output("DP-1")).write(other) }
      machine.script(.input, at: 2)

      #expect(machine.runner().run() == 0)

      #expect(try records.record(.output("DP-1")).read() == other)
    }
  }

  @Test func endingStopsOnlySiblingRunnersThatStillMatchTheirRecords() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      let records = SaverRecords(stateRoot: root)
      try records.create()
      let sibling = SaverFixture.session(810, "HDMI-1", macarchy: machine.macarchy)
      let reused = SaverFixture.session(820, "DP-2", macarchy: machine.macarchy)
      try records.record(.output("HDMI-1")).write(sibling)
      try records.record(.output("DP-2")).write(reused)
      machine.processes = [
        800: machine.identity.runner, 810: sibling.runner,
        820: SaverProcess(pid: 820, started: 1, executablePath: machine.macarchy),
      ]
      machine.script(.input, at: 2)

      #expect(machine.runner().run() == 0)

      #expect(machine.terminated == [810])
      #expect(try records.record(.output("HDMI-1")).read() == sibling)
      #expect(try records.record(.output("DP-1")).read() == nil)
    }
  }

  @Test func runnerWhoseExecutableIsNotARegularFileNeitherRegistersNorPlays() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root)
      try FileManager.default.removeItem(atPath: machine.macarchy)
      try FileManager.default.createDirectory(
        atPath: machine.macarchy, withIntermediateDirectories: false)
      machine.script(.timeout, at: 5)

      #expect(machine.runner().run() == 1)

      let expectedScreen = [
        "Macarchy screensaver cannot start: this runner's executable \(machine.macarchy) is not a"
          + " regular file"
      ]
      #expect(machine.screen == expectedScreen)
      #expect(machine.startedArguments.isEmpty)
      #expect(machine.terminated.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
    }
  }

  @Test func runnerThatCannotRegisterNeitherPlaysNorSignals() throws {
    try withTemporaryDirectory { root throws in
      let machine = try RunnerMachine(root, opensLaunch: false)
      // A regular file where the run directory belongs.
      try Data().write(to: root.appending(path: "run"))
      machine.script(.timeout, at: 5)

      #expect(machine.runner().run() == 1)

      #expect(machine.screen.count == 1)
      #expect(machine.screen.first?.hasPrefix("Macarchy screensaver cannot start: ") == true)
      let expectedWaits: [Duration?] = [.seconds(5)]
      #expect(machine.waits == expectedWaits)
      #expect(machine.startedArguments.isEmpty)
      #expect(machine.terminated.isEmpty)
    }
  }
}

private enum SaverFixture {
  static let macarchy = "/opt/homebrew/Cellar/macarchy/0.14.0/bin/macarchy"
  static let command = URL(filePath: "/opt/homebrew/bin/macarchy")
  static let stateRoot = URL(filePath: "/Users/me/.config/macarchy", directoryHint: .isDirectory)
  static let textFile = URL(filePath: "/Users/me/.config/macarchy/screensaver.txt")
  static let palette = SaverPalette(
    background: "#1a1b26", foreground: "#c0caf5", accents: ["#7aa2f7", "#7dcfff", "#c0caf5"])
  static let created = Date(timeIntervalSince1970: 1_800_000_000)
  static let launch = SaverLaunch(token: "0123456789abcdef0123456789abcdef", created: created)

  /// A session whose runner is `pid` and whose panel Kitty is `pid + 1`.
  static func session(
    _ pid: Int32, _ output: String?, macarchy: String = SaverFixture.macarchy,
    launch: SaverLaunch = SaverFixture.launch
  ) -> SaverRunnerRecord {
    SaverRunnerRecord(
      output: output, launch: launch.token,
      runner: SaverProcess(pid: pid, started: UInt64(pid) * 1_000, executablePath: macarchy),
      panel: SaverProcess(
        pid: pid + 1, started: UInt64(pid + 1) * 1_000,
        executablePath: SaverKitty.executable))
  }

  /// A regular file named macarchy in `root`, as a runner's executable must be when it registers.
  static func macarchyFile(in root: URL) throws -> String {
    let url = root.appending(path: "Cellar/macarchy/0.14.0/bin/macarchy")
    try writeFile("", to: url, permissions: 0o755)
    return url.path
  }
}

/// The panel terminal, ttfx and clock a runner sees, replayed from a script of events.
private final class RunnerMachine {
  static let refusal =
    "Macarchy screensaver did not start: this panel is not part of a start in progress."

  let identity: SaverRunnerRecord
  var waits: [Duration?] = []
  var randomBounds: [Int] = []
  var startedArguments: [[String]] = []
  var inputs: [String] = []
  var recorded: [SaverRunnerRecord?] = []
  var stopped: [Int32] = []
  var screen: [String] = []
  var processes: [Int32: SaverProcess] = [:]
  var terminated: [Int32] = []
  var startFails = false
  /// Runs as each ttfx starts.
  var duringPlay: () throws -> Void = {}
  private let records: SaverRecords
  private var events: [SaverRunnerEvent] = []
  private var times: [TimeInterval] = []
  private var time: TimeInterval = 0
  private var lastPID: Int32 = 900

  /// A runner of `launch` whose executable is a regular file in `root`. With `opensLaunch`,
  /// `launch` is the current launch, as when its start has just opened the panel.
  init(
    _ root: URL, output: String = "DP-1", pid: Int32 = 800,
    launch: SaverLaunch = SaverFixture.launch, opensLaunch: Bool = true
  ) throws {
    let macarchy = try SaverFixture.macarchyFile(in: root)
    records = SaverRecords(stateRoot: root)
    identity = SaverFixture.session(pid, output, macarchy: macarchy, launch: launch)
    guard opensLaunch else { return }
    try records.create()
    try records.launch.write(launch)
  }

  var macarchy: String { identity.runner.executablePath }

  /// `next` returns `event` once the clock reads `time` seconds after the runner began.
  func script(_ event: SaverRunnerEvent, at time: TimeInterval) {
    events.append(event)
    times.append(time)
  }

  func runner() -> SaverRunner {
    let records = self.records
    let identity = self.identity
    return SaverRunner(
      identity: identity,
      records: records,
      palette: SaverFixture.palette,
      text: "Back soon",
      terminal: SaverTerminal(
        prepare: { self.screen.append("prepare") },
        restore: { self.screen.append("restore") },
        show: { self.screen.append($0) }),
      processes: SaverEngineProcesses(
        start: { arguments, input in
          if self.startFails { throw SaverError("exec format error") }
          try self.duringPlay()
          self.startedArguments.append(arguments)
          self.inputs.append(input)
          self.recorded.append(try records.record(identity.display).read())
          self.lastPID += 1
          return self.lastPID
        },
        stop: { self.stopped.append($0) }),
      next: { _, timeout in
        self.waits.append(timeout)
        guard !self.events.isEmpty else {
          Issue.record("the runner waited past its scripted events")
          return .terminate
        }
        self.time = self.times.removeFirst()
        return self.events.removeFirst()
      },
      observe: { self.processes[$0] },
      terminate: { self.terminated.append($0) },
      random: { bound in
        self.randomBounds.append(bound)
        return 0
      },
      now: { Date(timeIntervalSince1970: self.time) })
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-saver-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func writeFile(_ contents: String, to url: URL, permissions: Int) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(contents.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}
