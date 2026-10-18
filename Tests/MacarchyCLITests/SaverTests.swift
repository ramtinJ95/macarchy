import Foundation
import Testing
import ThemeCore

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
      engine: SaverEngine(url: engine, defect: nil), kitty: .present(version: "0.49.0"),
      textFile: SaverFixture.textFile, text: .banner(rejected: nil), sessions: [])
    let missing = SaverStatus(
      engine: SaverEngine(url: engine, defect: .absent), kitty: .missing,
      textFile: SaverFixture.textFile, text: .banner(rejected: nil), sessions: [])

    #expect(
      try ready.renderJSON()
        == #"{"engine":{"path":"/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx","reason":null,"#
        + #""remedy":null,"state":"present"},"kitty":{"path":"/Applications/kitty.app","#
        + #""remedy":null,"state":"present","version":"0.49.0"},"running":false,"sessions":[],"#
        + #""text":{"path":"/Users/me/.config/macarchy/screensaver.txt","rejected":null,"#
        + #""source":"banner"}}"#)
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
        Text: the Macarchy banner (add /Users/me/.config/macarchy/screensaver.txt to show your own)
        Screensaver: not running
        """)
    #expect(missing.message.contains("missing at \(engine.path) (not found)"))
    #expect(missing.message.contains("brew reinstall ramtinj95/tap/macarchy"))
    #expect(missing.message.contains("brew install --cask kitty"))
  }

  @Test func statusNamesRunningDisplaysAndTheTextSourceButNeverTheText() throws {
    let engine = SaverEngine(url: URL(filePath: "/opt/homebrew/libexec/ttfx"), defect: nil)
    let outputs = SaverStatus(
      engine: engine, kitty: .present(version: "0.49.0"), textFile: SaverFixture.textFile,
      text: .custom("Gone fishing"),
      sessions: [SaverFixture.session(700, "DP-1"), SaverFixture.session(710, "HDMI-1")])
    let main = SaverStatus(
      engine: engine, kitty: .present(version: "0.49.0"), textFile: SaverFixture.textFile,
      text: .banner(rejected: "it is not valid UTF-8"), sessions: [SaverFixture.session(700, nil)])

    #expect(
      outputs.message.hasSuffix(
        "Text: /Users/me/.config/macarchy/screensaver.txt\nScreensaver: running on DP-1, HDMI-1"))
    #expect(
      try outputs.renderJSON().hasSuffix(
        #""running":true,"sessions":[{"display":"DP-1","pid":700},{"display":"HDMI-1","pid":710}],"#
          + #""text":{"path":"/Users/me/.config/macarchy/screensaver.txt","rejected":null,"#
          + #""source":"custom"}}"#))
    #expect(try outputs.renderJSON().contains("Gone fishing") == false)
    #expect(
      main.message.hasSuffix(
        "Text: the Macarchy banner; /Users/me/.config/macarchy/screensaver.txt is not used"
          + " because it is not valid UTF-8\nScreensaver: running; it covers the main display only"
      ))
    #expect(try main.renderJSON().contains(#""sessions":[{"display":null,"pid":700}]"#))
    #expect(
      try main.renderJSON().contains(#""rejected":"it is not valid UTF-8","source":"banner""#))
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

struct SaverHostTests {
  @Test func panelArgumentsAreExactAndNeverCarryTheText() {
    let named = SaverHost.panelArguments(
      for: .output("DP-1"), token: SaverFixture.launch.token, palette: SaverFixture.palette,
      stateRoot: SaverFixture.stateRoot, command: SaverFixture.command)
    let main = SaverHost.panelArguments(
      for: .main, token: SaverFixture.launch.token, palette: SaverFixture.palette,
      stateRoot: SaverFixture.stateRoot, command: SaverFixture.command)

    let head = [
      "-n", "-a", "/Applications/kitty.app", "--env",
      "KITTY_CACHE_DIRECTORY=/Users/me/.config/macarchy/run/saver/kitty-cache", "--args",
      "+kitten", "panel", "--edge=center", "--layer=overlay", "--focus-policy=exclusive",
    ]
    let options = [
      "-o", "macos_use_physical_screen_frame=yes", "-o", "background=#1a1b26", "-o",
      "foreground=#c0caf5", "-o", "font_size=18", "-o", "window_padding_width=0", "-o",
      "mouse_hide_wait=0.25", "-o", "macos_quit_when_last_window_closed=yes", "--config", "NONE",
      "/opt/homebrew/bin/macarchy", "saver", "_run", "--state-root", "/Users/me/.config/macarchy",
      "--launch", "0123456789abcdef0123456789abcdef",
    ]
    let expectedNamed = head + ["--output-name=DP-1"] + options + ["--display", "DP-1"]
    let expectedMain = head + options
    #expect(named == expectedNamed)
    #expect(main == expectedMain)
  }

  @Test func displayListAcceptsNamesOrNamedObjects() {
    let names = SaverCoverage.outputs(["DP-1", "HDMI-1"])
    let objects = SaverCoverage.outputs(["Built-in Retina Display", "DELL U2723QE"])
    let unnamed = SaverCoverage.mainOnly(reason: "Kitty reported no display names")
    let unreadable = SaverCoverage.mainOnly(
      reason: "Kitty did not list its displays as a JSON array")

    #expect(SaverHost.coverage(listJSON: #"["DP-1","HDMI-1"]"#) == names)
    #expect(
      SaverHost.coverage(
        listJSON: #"[{"name":"Built-in Retina Display","x":0},{"name":"DELL U2723QE"},"#
          + #"{"name":"DELL U2723QE"},{"name":""},{"id":3},"bad\u0007name",7]"#) == objects)
    #expect(SaverHost.coverage(listJSON: "[]") == unnamed)
    #expect(SaverHost.coverage(listJSON: #"[{"id":1}]"#) == unnamed)
    #expect(SaverHost.coverage(listJSON: #"{"name":"DP-1"}"#) == unreadable)
    #expect(SaverHost.coverage(listJSON: "Unknown option --output-name") == unreadable)
    let mainDisplay: [SaverDisplay] = [.main]
    let namedDisplays: [SaverDisplay] = [.output("DP-1"), .output("HDMI-1")]
    #expect(unnamed.displays == mainDisplay)
    #expect(names.displays == namedDisplays)
  }

  @Test(arguments: ["listed", "failed-status", "throws"])
  func displayListComesFromKittensPanelHelper(outcome: String) {
    let runner = ProcessRunner { request in
      #expect(request.executableURL.path == "/Applications/kitty.app/Contents/MacOS/kitten")
      #expect(request.arguments == ["panel", "--output-name=listjson"])
      switch outcome {
      case "listed": return ProcessResult(terminationStatus: 0, output: #"["DP-1"]"#)
      case "failed-status": return ProcessResult(terminationStatus: 2, output: "error")
      default: throw SaverError("timed out")
      }
    }
    let expected =
      switch outcome {
      case "listed": SaverCoverage.outputs(["DP-1"])
      case "failed-status": SaverCoverage.mainOnly(reason: "kitten panel exited with status 2")
      default: SaverCoverage.mainOnly(reason: "kitten panel failed: timed out")
      }

    #expect(SaverHost.coverage(processRunner: runner) == expected)
  }
}

struct SaverSessionTests {
  @Test func startCoversEveryNamedDisplayOnceAndStopEndsEverySession() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.text = .custom("Away until 3 pm")
      let saver = machine.saver()
      #expect(try saver.isRunning() == false)

      let start = try saver.start()
      #expect(try saver.isRunning())

      let expectedStart = SaverStart.started(
        .outputs(["DP-1", "HDMI-1"]), .custom("Away until 3 pm"))
      #expect(start == expectedStart)
      #expect(
        start.message(textFile: SaverFixture.textFile)
          == "Screensaver started on DP-1, HDMI-1. Press any key or move the mouse to dismiss it.")
      let token = try SaverMachine.token(machine.launched[0])
      #expect(token.count == 32)
      #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
      let expectedLaunches = [
        SaverHost.panelArguments(
          for: .output("DP-1"), token: token, palette: SaverFixture.palette, stateRoot: root,
          command: SaverFixture.command),
        SaverHost.panelArguments(
          for: .output("HDMI-1"), token: token, palette: SaverFixture.palette, stateRoot: root,
          command: SaverFixture.command),
      ]
      #expect(machine.launched == expectedLaunches)
      #expect(!machine.launched.joined().contains { $0.contains("Away") })
      #expect(FileManager.default.fileExists(atPath: SaverRecords(stateRoot: root).kittyCache.path))
      #expect(try SaverRecords(stateRoot: root).launch.read() == nil)
      let sessions = try saver.status().sessions
      let expectedOutputs: [String?] = ["DP-1", "HDMI-1"]
      #expect(sessions.map(\.output) == expectedOutputs)

      #expect(try saver.start() == .alreadyRunning)
      #expect(machine.launched.count == 2)

      #expect(try saver.stop() == .stopped)
      #expect(machine.terminated.sorted() == sessions.map(\.runner.pid).sorted())
      #expect(machine.processes.isEmpty)
      #expect(try saver.status().sessions.isEmpty)
      #expect(try saver.isRunning() == false)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)

      #expect(try saver.stop() == .notRunning)
      #expect(machine.terminated.count == 2)
    }
  }

  @Test func withoutDisplayNamesOnePanelCoversTheMainDisplay() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.coverage = .mainOnly(reason: "Kitty reported no display names")
      let saver = machine.saver()

      let start = try saver.start()

      #expect(
        start.message(textFile: SaverFixture.textFile)
          == "Screensaver started; it covers the main display only because Kitty reported no"
          + " display names. Press any key or move the mouse to dismiss it.")
      #expect(machine.launched.count == 1)
      #expect(!machine.launched.joined().contains { $0.hasPrefix("--output-name") })
      #expect(!machine.launched.joined().contains("--display"))
      #expect(try saver.status().message.hasSuffix("running; it covers the main display only"))
    }
  }

  @Test func startNamesARejectedTextFile() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.text = .banner(rejected: "it is a symbolic link")

      let start = try machine.saver().start()

      #expect(
        start.message(textFile: SaverFixture.textFile).hasSuffix(
          "dismiss it. Showing the Macarchy banner: /Users/me/.config/macarchy/screensaver.txt"
            + " is not used because it is a symbolic link."))
    }
  }

  @Test(arguments: ["kitty", "engine"])
  func startNeedsKittyAndTheEngineAndNamesTheRemedy(missing: String) throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      if missing == "kitty" {
        machine.kitty = .missing
      } else {
        machine.engineDefect = .notExecutable
      }
      let saver = machine.saver()

      let error = #expect(throws: SaverError.self) { try saver.start() }

      let remedy = missing == "kitty" ? SaverKitty.remedy : SaverEngine.remedy
      #expect(error?.description.hasSuffix(remedy) == true)
      #expect(machine.launched.isEmpty)
    }
  }

  @Test(arguments: ["open-fails", "never-registers"])
  func partialStartStopsTheDisplaysThatStarted(failure: String) throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      if failure == "open-fails" {
        machine.failingDisplays = ["HDMI-1"]
      } else {
        machine.silentDisplays = ["HDMI-1"]
      }
      let saver = machine.saver()

      let error = #expect(throws: SaverError.self) { try saver.start() }

      let reason =
        failure == "open-fails" ? "open failed" : "its panel did not start within 5 seconds"
      #expect(
        error?.description
          == "The screensaver did not start on HDMI-1 (\(reason)). Stopped the displays that did"
          + " start.")
      #expect(machine.launched.count == 2)
      #expect(machine.terminated == [701])
      #expect(machine.processes.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
      #expect(try SaverRecords(stateRoot: root).launch.read() == nil)
    }
  }

  @Test func runnerOfADisplayWhoseOpenFailedIsStoppedEvenThoughItRegistered() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.lateFailingDisplays = ["HDMI-1"]
      let saver = machine.saver()

      let error = #expect(throws: SaverError.self) { try saver.start() }

      #expect(
        error?.description
          == "The screensaver did not start on HDMI-1 (open timed out). Stopped the displays that"
          + " did start.")
      let expectedTerminated: [Int32] = [701, 703]
      #expect(machine.terminated.sorted() == expectedTerminated)
      #expect(machine.processes.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
      #expect(try SaverRecords(stateRoot: root).launch.read() == nil)
    }
  }

  @Test func startWhileAnotherStartWaitsForItsPanelsLeavesThatStartAlone() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let saver = machine.saver()
      var second: SaverStart?
      machine.beforeRegistration = { second = try saver.start() }

      let first = try saver.start()

      let expectedFirst = SaverStart.started(.outputs(["DP-1", "HDMI-1"]), .banner(rejected: nil))
      #expect(first == expectedFirst)
      let outcome = try #require(second)
      #expect(outcome == .alreadyStarting)
      #expect(
        outcome.message(textFile: SaverFixture.textFile) == "The screensaver is already starting.")
      #expect(machine.launched.count == 2)
      #expect(try saver.status().sessions.count == 2)
    }
  }

  @Test(arguments: ["crashed", "clock-moved-back", "in-progress"])
  func launchRecordHoldsOffStartsOnlyWithinTheRegistrationWindow(kind: String) throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let records = SaverRecords(stateRoot: root)
      let offset: TimeInterval =
        switch kind {
        case "crashed": -Saver.launchWindow - 1
        case "clock-moved-back": Saver.launchWindow + 1
        default: 1 - Saver.launchWindow
        }
      let pending = SaverLaunch(
        token: String(repeating: "e", count: 32), created: machine.clock.addingTimeInterval(offset))
      try records.create()
      try records.launch.write(pending)

      let start = try machine.saver().start()

      if kind == "in-progress" {
        #expect(start == .alreadyStarting)
        #expect(machine.launched.isEmpty)
        #expect(try records.launch.read() == pending)
      } else {
        let expected = SaverStart.started(.outputs(["DP-1", "HDMI-1"]), .banner(rejected: nil))
        #expect(start == expected)
        #expect(machine.launched.count == 2)
        #expect(try SaverMachine.token(machine.launched[0]) != pending.token)
        #expect(try records.launch.read() == nil)
      }
    }
  }

  @Test func runnerThatArrivesAfterStartGaveUpClosesWithoutARecord() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.silentDisplays = ["HDMI-1"]
      let saver = machine.saver()
      #expect(throws: SaverError.self) { try saver.start() }
      let token = try SaverMachine.token(machine.launched[1])
      let late = try RunnerMachine(
        root, output: "HDMI-1", pid: 850,
        launch: SaverLaunch(token: token, created: SaverFixture.created), opensLaunch: false)

      #expect(late.runner().run() == 1)

      #expect(late.screen == [RunnerMachine.refusal])
      #expect(late.startedArguments.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
      #expect(try saver.status().sessions.isEmpty)
    }
  }

  @Test func stopClosesAnOpenLaunchSoItsRunnersNeverPlay() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let records = SaverRecords(stateRoot: root)
      // As when a start has opened this panel and still waits for its runner.
      let late = try RunnerMachine(root)
      #expect(try records.launch.read() == SaverFixture.launch)

      #expect(try machine.saver().stop() == .notRunning)

      #expect(try records.launch.read() == nil)
      #expect(late.runner().run() == 1)
      #expect(late.screen == [RunnerMachine.refusal])
      #expect(late.startedArguments.isEmpty)
      #expect(try records.entries().isEmpty)
    }
  }

  @Test func staleRunnerOfAFailedStartLeavesTheRetriedStartsRecordAlone() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let saver = machine.saver()
      machine.silentDisplays = ["HDMI-1"]
      #expect(throws: SaverError.self) { try saver.start() }
      machine.silentDisplays = []
      let retried = try saver.start()
      let records = SaverRecords(stateRoot: root)
      let found = try records.record(.output("HDMI-1")).read()
      let current = try #require(found)
      let staleToken = try SaverMachine.token(machine.launched[1])
      let stale = try RunnerMachine(
        root, output: "HDMI-1", pid: 850,
        launch: SaverLaunch(token: staleToken, created: SaverFixture.created), opensLaunch: false)
      let sessions = try saver.status().sessions
      stale.processes = Dictionary(
        uniqueKeysWithValues: sessions.map { ($0.runner.pid, $0.runner) })

      #expect(stale.runner().run() == 1)

      let expected = SaverStart.started(.outputs(["DP-1", "HDMI-1"]), .banner(rejected: nil))
      #expect(retried == expected)
      #expect(try current.launch == SaverMachine.token(machine.launched[3]))
      #expect(stale.screen == [RunnerMachine.refusal])
      #expect(stale.terminated.isEmpty)
      #expect(try records.record(.output("HDMI-1")).read() == current)
      #expect(try saver.status().sessions.count == 2)
    }
  }

  @Test(arguments: ["dead", "reused", "foreign-panel", "foreign-runner", "corrupt"])
  func staleRecordsAreRemovedAndNeverSignalled(kind: String) throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let records = SaverRecords(stateRoot: root)
      try records.create()
      let record = records.record(.output("DP-1"))
      let stale = SaverRunnerRecord(
        output: "DP-1", launch: SaverFixture.launch.token,
        runner: SaverProcess(
          pid: 600, started: 600_000,
          executablePath: kind == "foreign-runner" ? "/bin/zsh" : machine.macarchy),
        panel: SaverProcess(
          pid: 601, started: 601_000,
          executablePath: kind == "foreign-panel" ? "/bin/zsh" : SaverKitty.executable))
      if kind == "corrupt" {
        try Data(#"{"runner":"#.utf8).write(to: record.url)
      } else {
        try record.write(stale)
      }
      switch kind {
      case "reused":
        machine.processes[600] = SaverProcess(
          pid: 600, started: 1, executablePath: machine.macarchy)
        machine.processes[601] = SaverProcess(
          pid: 601, started: 1, executablePath: SaverKitty.executable)
      case "foreign-panel", "foreign-runner":
        machine.processes[600] = stale.runner
        machine.processes[601] = stale.panel
      default: break
      }
      let saver = machine.saver()

      #expect(try saver.isRunning() == false)
      #expect(try saver.status().sessions.isEmpty)
      #expect(try saver.stop() == .notRunning)
      #expect(machine.terminated.isEmpty)
      #expect(try records.entries().isEmpty)
      #expect(try saver.start() != .alreadyRunning)
      #expect(machine.terminated.isEmpty)
    }
  }

  @Test func sessionStaysOwnedAfterItsRunnersExecutableIsRemoved() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let saver = machine.saver()
      _ = try saver.start()
      let sessions = try saver.status().sessions
      // As when `brew cleanup` removes the version the runners started from.
      try FileManager.default.removeItem(atPath: machine.macarchy)

      #expect(try saver.status().sessions == sessions)
      #expect(try saver.start() == .alreadyRunning)
      #expect(try saver.stop() == .stopped)
      #expect(machine.terminated.sorted() == sessions.map(\.runner.pid).sorted())
      #expect(machine.processes.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
    }
  }

  @Test func panelThatOutlivesItsRunnerIsStoppedWhileItMatchesItsRecord() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      machine.panelsQuitWithRunner = false
      let saver = machine.saver()
      _ = try saver.start()
      let sessions = try saver.status().sessions

      #expect(try saver.stop() == .stopped)

      // Every runner first, then the panels that stayed behind.
      #expect(machine.terminated.prefix(2).sorted() == sessions.map(\.runner.pid).sorted())
      #expect(machine.terminated.dropFirst(2).sorted() == sessions.map(\.panel.pid).sorted())
      #expect(machine.processes.isEmpty)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
    }
  }

  @Test func orphanPanelOfACrashedRunnerIsStoppedAndItsRecordRemoved() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let records = SaverRecords(stateRoot: root)
      try records.create()
      let orphan = SaverFixture.session(600, nil, macarchy: machine.macarchy)
      try records.record(.main).write(orphan)
      machine.processes[601] = orphan.panel

      #expect(try machine.saver().stop() == .stopped)

      #expect(machine.terminated == [601])
      #expect(try records.entries().isEmpty)
    }
  }

  @Test func stopChecksEachIdentityRightBeforeItsSignal() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let saver = machine.saver()
      _ = try saver.start()
      let sessions = try saver.status().sessions
      // While the first runner is signalled, the other exits with its panel and its PID is reused.
      machine.afterTerminate = { pid in
        guard machine.terminated.count == 1,
          let other = sessions.first(where: { $0.runner.pid != pid })
        else { return }
        machine.processes[other.panel.pid] = nil
        machine.processes[other.runner.pid] = SaverProcess(
          pid: other.runner.pid, started: 1, executablePath: other.runner.executablePath)
      }

      #expect(try saver.stop() == .stopped)

      #expect(machine.terminated.count == 1)
      let signalled = try #require(machine.terminated.first)
      let reused = try #require(sessions.first(where: { $0.runner.pid != signalled }))
      #expect(machine.processes[reused.runner.pid]?.started == 1)
      #expect(try SaverRecords(stateRoot: root).entries().isEmpty)
    }
  }

  @Test func runnerThatIgnoresSIGTERMKeepsItsRecordAndFailsTheStop() throws {
    try withTemporaryDirectory { root throws in
      let machine = try SaverMachine(root)
      let saver = machine.saver()
      _ = try saver.start()
      machine.exitsOnSIGTERM = false

      let error = #expect(throws: SaverError.self) { try saver.stop() }

      #expect(error?.description.contains("did not exit after SIGTERM") == true)
      #expect(try saver.status().sessions.count == 2)
      #expect(try SaverRecords(stateRoot: root).entries().count == 2)
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

/// The processes `Saver` can observe and cause. Each launched panel's runner registers through
/// `SaverRecords.register` at start's next pause, once start has released the lock, as a real
/// runner does, and a runner that exits removes its record the way the real runner does.
private final class SaverMachine {
  var processes: [Int32: SaverProcess] = [:]
  var launched: [[String]] = []
  var terminated: [Int32] = []
  var failingDisplays: Set<String> = []
  /// Displays whose `open` fails after it opened the panel, as when it times out.
  var lateFailingDisplays: Set<String> = []
  var silentDisplays: Set<String> = []
  var exitsOnSIGTERM = true
  var panelsQuitWithRunner = true
  /// Runs after each SIGTERM.
  var afterTerminate: (Int32) -> Void = { _ in }
  /// Runs once, at start's first pause after it opened panels, before their runners register.
  var beforeRegistration: (() throws -> Void)?
  var clock = SaverFixture.created
  var coverage = SaverCoverage.outputs(["DP-1", "HDMI-1"])
  var text = SaverText.banner(rejected: nil)
  var kitty = SaverKitty.present(version: "0.49.0")
  var engineDefect: SaverEngineDefect?
  /// Every runner's executable, a regular file named macarchy.
  let macarchy: String
  private let records: SaverRecords
  private var lastPID: Int32 = 700
  private var panels: [Int32: Int32] = [:]
  private var opened: [SaverRunnerRecord] = []
  private var running: [Int32: SaverRunnerRecord] = [:]

  init(_ root: URL) throws {
    macarchy = try SaverFixture.macarchyFile(in: root)
    records = SaverRecords(stateRoot: root)
  }

  /// The launch token in one panel's `open` arguments.
  static func token(_ arguments: [String]) throws -> String {
    let index = try #require(arguments.firstIndex(of: "--launch"))
    return arguments[index + 1]
  }

  func saver() -> Saver {
    Saver(
      stateRoot: records.stateRoot,
      engine: SaverEngine(
        url: URL(filePath: "/opt/homebrew/Cellar/macarchy/0.14.0/libexec/ttfx"),
        defect: engineDefect),
      kitty: kitty,
      command: SaverFixture.command,
      palette: { SaverFixture.palette },
      text: { self.text },
      coverage: { self.coverage },
      launch: { arguments in
        self.launched.append(arguments)
        let output = arguments.firstIndex(of: "--display").map { arguments[$0 + 1] }
        if let output, self.failingDisplays.contains(output) { throw SaverError("open failed") }
        if let output, self.silentDisplays.contains(output) { return }
        let token = try SaverMachine.token(arguments)
        let runner = self.spawn(self.macarchy)
        let panel = self.spawn(SaverKitty.executable)
        self.panels[runner.pid] = panel.pid
        self.opened.append(
          SaverRunnerRecord(output: output, launch: token, runner: runner, panel: panel))
        if let output, self.lateFailingDisplays.contains(output) {
          throw SaverError("open timed out")
        }
      },
      observe: { self.processes[$0] },
      terminate: { pid in
        self.terminated.append(pid)
        if self.exitsOnSIGTERM { self.end(pid) }
        self.afterTerminate(pid)
      },
      pause: { self.registerOpenedRunners() },
      now: { self.clock })
  }

  private func registerOpenedRunners() {
    if !opened.isEmpty, let hook = beforeRegistration {
      beforeRegistration = nil
      do {
        try hook()
      } catch {
        Issue.record("the hook before registration failed: \(error)")
      }
    }
    for session in opened {
      do {
        if try records.register(session) {
          running[session.runner.pid] = session
        } else {
          end(session.runner.pid)
        }
      } catch {
        Issue.record("a runner could not register: \(error)")
      }
    }
    opened = []
  }

  private func spawn(_ executablePath: String) -> SaverProcess {
    lastPID += 1
    let process = SaverProcess(
      pid: lastPID, started: UInt64(lastPID) * 1_000, executablePath: executablePath)
    processes[lastPID] = process
    return process
  }

  private func end(_ pid: Int32) {
    processes[pid] = nil
    if let session = running.removeValue(forKey: pid) { try? records.unregister(session) }
    if panelsQuitWithRunner, let panel = panels.removeValue(forKey: pid) {
      processes[panel] = nil
    }
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
