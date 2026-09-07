import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct BordersPreviewTests {
  @Test(arguments: ["0", "301", "nan", "inf"])
  func durationIsBoundedBeforeAnyProviderWork(seconds: String) {
    #expect(throws: (any Error).self) {
      _ = try Borders.Preview.parse(["--seconds", seconds])
    }
  }

  @Test
  func canonicalPaletteProducesExplicitPermissionlessFocusOnlyArguments() throws {
    let fixture = try BordersFixture()
    defer { fixture.remove() }
    let before = try FileManager.default.destinationOfSymbolicLink(
      atPath: fixture.root.appending(path: "current").path)
    let palette = try BordersPalette.read(root: fixture.root)
    #expect(palette.themeID == "catppuccin-mocha")
    #expect(
      palette.arguments == [
        "active_color=0xffcba6f7", "inactive_color=0x00000000",
        "background_color=0x00000000", "width=6.0", "style=round", "hidpi=on", "ax_focus=off",
      ])
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.root.appending(path: "current").path) == before)
    try FileManager.default.removeItem(at: fixture.root.appending(path: "current"))
    #expect(throws: (any Error).self) { try BordersPalette.read(root: fixture.root) }
  }

  @Test(arguments: [
    "missing", "version", "process", "inspection", "service", "loaded-job", "job-error", "ready",
  ])
  func preflightNeverStartsOrUpdatesTheProvider(condition: String) throws {
    let fixture = try BordersFixture()
    defer { fixture.remove() }
    let executable = fixture.directory.appending(path: "borders")
    if condition != "missing" {
      try Data("fixture executable; never executed".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    if condition == "service" {
      let agents = fixture.directory.appending(path: "Library/LaunchAgents")
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      // Even an inactive/dangling service entry is external state, not absence.
      try FileManager.default.createSymbolicLink(
        at: agents.appending(path: "homebrew.mxcl.borders.plist"),
        withDestinationURL: fixture.directory.appending(path: "missing-plist")
      )
    }
    let requests = Mutex<[ProcessRequest]>([])
    let runner = BordersPreviewRunner.live(
      root: fixture.root, executable: executable, home: fixture.directory,
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments == ["--version"] {
          return ProcessResult(
            terminationStatus: 0,
            output: condition == "version" ? "borders-v1.8.0" : "borders-v1.9.0"
          )
        }
        if request.executableURL.path == "/usr/bin/pgrep" {
          #expect(request.arguments == ["-u", String(getuid()), "-x", "borders"])
          return ProcessResult(
            terminationStatus: condition == "process" ? 0 : condition == "inspection" ? 2 : 1,
            output: condition == "process" ? "321" : ""
          )
        }
        #expect(request.executableURL.path == "/bin/launchctl")
        #expect(request.arguments == ["print", "gui/\(getuid())/homebrew.mxcl.borders"])
        return ProcessResult(
          terminationStatus: condition == "loaded-job" ? 0 : condition == "job-error" ? 5 : 113,
          output: ""
        )
      }
    )
    if condition == "ready" {
      #expect(try runner.preflight().themeID == "catppuccin-mocha")
    } else {
      #expect(throws: BordersPreviewError.self) { try runner.preflight() }
    }
    #expect(
      requests.withLock { $0 }.allSatisfy {
        $0.arguments == ["--version"]
          || ["/usr/bin/pgrep", "/bin/launchctl"].contains($0.executableURL.path)
      })
    #expect(
      !FileManager.default.fileExists(atPath: fixture.directory.appending(path: ".config").path))
  }

  @Test(arguments: [false, true])
  func previewTracksCanonicalChangesAndStopsOnlyItsChild(sameAccent: Bool) throws {
    let first = BordersPalette(generationID: "g-first", themeID: "first", accent: "#cba6f7")
    let second = BordersPalette(
      generationID: "g-second", themeID: "second", accent: sameAccent ? first.accent : "#abcdef"
    )
    let fixture = PreviewRuntimeFixture(first: first, second: second)
    let events = try fixture.runner().run(initial: first, seconds: 1, shouldStop: { false })
    #expect(fixture.starts == [first.arguments])
    #expect(fixture.updates == (sameAccent ? [] : [second.arguments]))
    #expect(fixture.stopCount == 1)
    // Callers cannot emit results until cleanup has completed. Closed/stalled
    // stdout therefore cannot strand this child or extend its lifetime.
    #expect(!fixture.running)
    #expect(events.map(\.event) == ["running", "palette_requested", "stopped"])
    #expect(events[1].generationID == second.generationID)
    #expect(fixture.time == 1)
  }

  @Test(arguments: [
    "startup", "early-exit", "last-exit", "canonical", "update", "cancel",
  ])
  func errorsAndCancellationCleanUpTheOwnedPreview(condition: String) throws {
    let first = BordersPalette(generationID: "g-first", themeID: "first", accent: "#cba6f7")
    let second = BordersPalette(generationID: "g-second", themeID: "second", accent: "#abcdef")
    let fixture = PreviewRuntimeFixture(first: first, second: second)
    fixture.failure = condition
    var events = [String]()
    let run = {
      events = try fixture.runner().run(
        initial: first, seconds: 1, shouldStop: { condition == "cancel" }
      ).map(\.event)
    }
    if condition == "cancel" {
      try run()
      #expect(events == ["running", "stopped"])
    } else {
      #expect(throws: (any Error).self, performing: run)
      #expect(!events.contains("stopped"))
    }
    #expect(!fixture.running)
    #expect(
      fixture.stopCount == (["startup", "early-exit", "last-exit"].contains(condition) ? 0 : 1))
  }

  @Test
  func nativeProcessCleanupIsBoundedAndIdempotent() throws {
    let child = try BordersPreviewProcess.start(
      executableURL: URL(filePath: "/bin/sleep"), arguments: ["30"]
    )
    defer { child.stop() }
    #expect(child.isRunning())
    child.stop()
    child.stop()
    #expect(!child.isRunning())
  }
}

private enum ProbeError: Error { case failed }

private final class PreviewRuntimeFixture {
  let first: BordersPalette
  let second: BordersPalette
  var starts = [[String]]()
  var updates = [[String]]()
  var stopCount = 0
  var running = false
  var time: TimeInterval = 0
  var failure = ""

  init(first: BordersPalette, second: BordersPalette) {
    self.first = first
    self.second = second
  }

  func runner() -> BordersPreviewRunner {
    BordersPreviewRunner(
      preflight: { self.first },
      pointer: {
        if self.failure == "canonical" { throw ProbeError.failed }
        return "generations/\(self.second.generationID)"
      },
      palette: { self.second },
      start: { arguments in
        if self.failure == "startup" { throw ProbeError.failed }
        self.starts.append(arguments)
        self.running = true
        return BordersPreviewProcess(
          processID: 123,
          isRunning: { self.running },
          terminationStatus: { 1 },
          stop: {
            if self.running {
              self.stopCount += 1
              self.running = false
            }
          }
        )
      },
      update: { arguments in
        if self.failure == "update" { throw ProbeError.failed }
        self.updates.append(arguments)
      },
      now: { self.time },
      wait: {
        self.time += 0.25
        if self.failure == "early-exit" || (self.failure == "last-exit" && self.time >= 1) {
          self.running = false
        }
      }
    )
  }
}

private struct BordersFixture {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-borders-\(UUID())")
  var root: URL { directory.appending(path: "state") }

  init() throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/catppuccin-mocha")
    )
    _ = try ThemeActivator(
      root: root, faultInjector: { _ in }, onThemeChanged: { _ in },
      postDarwinNotification: { _ in }
    ).activate(package: package)
  }

  func remove() {
    if let entries = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
    ) {
      for case let url as URL in entries {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
      }
    }
    try? FileManager.default.removeItem(at: directory)
  }
}
