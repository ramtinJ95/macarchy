import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func spicetifyOneShotIsAwaitedAndItsOptionalFailureIsPersisted() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let store = ReconciliationStatusStore(root: root)
    let state = Mutex((requests: [ProcessRequest](), finished: false))
    let executable = URL(filePath: "/opt/homebrew/bin/spicetify")
    let configuration = try spicetifyConfiguration(root: root).directory
    let adapter = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: executable,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        state.withLock { $0.requests.append(request) }
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 0, output: "123")
        }
        Thread.sleep(forTimeInterval: 0.1)
        state.withLock { $0.finished = true }
        return ProcessResult(terminationStatus: 1, output: "refresh failed")
      }
    )

    let reconciliation = Task {
      try await ThemeReconciler(statusStore: store).reconcile(
        manifest: manifest,
        adapters: [adapter.reconciliation()]
      )
    }
    try await waitUntil { state.withLock { $0.requests.count == 2 } }
    #expect(!state.withLock { $0.finished })
    #expect(try store.read() == .missing(activeGenerationID: manifest.generationID))

    let record = try await reconciliation.value
    #expect(
      state.withLock { $0.requests }
        == [
          ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-x", "Spotify"],
            timeout: 1
          ),
          ProcessRequest(
            executableURL: executable,
            arguments: ["--no-restart", "refresh"],
            timeout: 30
          ),
        ]
    )
    #expect(
      record.results
        == [
          AdapterResult(
            adapterID: "spicetify",
            requirement: .optional,
            status: .failed,
            message: "refresh failed"
          )
        ]
    )
    #expect(try store.read() == .current(record))
  }

  @Test
  func spicetifyRefreshesWithoutLaunchingClosedSpotifyAndRestartsRunningSpotify() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let configurationFixture = try spicetifyConfiguration(root: root)
    let configuration = configurationFixture.directory
    let configurationURL = configurationFixture.url
    let validConfiguration = configurationFixture.contents

    let runningRequests = Mutex([ProcessRequest]())
    let runningProcessChecks = Mutex(0)
    let running = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        runningRequests.withLock { $0.append(request) }
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return runningProcessChecks.withLock { checks in
            checks += 1
            return ProcessResult(
              terminationStatus: 0,
              output: checks == 1 ? "123\n" : "456\n"
            )
          }
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitBetweenProcessChecks: {}
    )
    let runningOutcome = try await running.reconciliation().run()
    #expect(runningOutcome.status == .applied)
    #expect(
      runningOutcome.message == "Spicetify refreshed the active palette and restarted Spotify")
    let runningCommands = runningRequests.withLock { $0 }
    #expect(runningCommands.contains { $0.arguments == ["--no-restart", "refresh"] })
    #expect(runningCommands.contains { $0.arguments == ["restart"] })
    #expect(!runningCommands.contains { $0.executableURL == URL(filePath: "/usr/bin/open") })

    let fallbackRequests = Mutex([ProcessRequest]())
    let processChecks = Mutex(0)
    let fallbackWaits = Mutex(0)
    let fallback = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        fallbackRequests.withLock { $0.append(request) }
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return processChecks.withLock { checks in
            checks += 1
            return ProcessResult(
              terminationStatus: (3...4).contains(checks) ? 1 : 0,
              output: checks == 1 ? "123\n" : "456\n"
            )
          }
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitBetweenProcessChecks: { fallbackWaits.withLock { $0 += 1 } }
    )
    #expect(try await fallback.reconciliation().run().status == .applied)
    let fallbackCommands = fallbackRequests.withLock { $0 }
    let restartIndex = try #require(fallbackCommands.firstIndex { $0.arguments == ["restart"] })
    let launchIndex = try #require(
      fallbackCommands.firstIndex { $0.executableURL == URL(filePath: "/usr/bin/open") })
    #expect(restartIndex < launchIndex)
    #expect(fallbackWaits.withLock { $0 } == 3)

    let closedRequests = Mutex([ProcessRequest]())
    let closed = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        closedRequests.withLock { $0.append(request) }
        return ProcessResult(
          terminationStatus: request.executableURL == URL(filePath: "/usr/bin/pgrep") ? 1 : 0,
          output: ""
        )
      },
      waitBetweenProcessChecks: {}
    )
    let closedOutcome = try await closed.reconciliation().run()
    #expect(closedOutcome.status == .applied)
    #expect(closedOutcome.message == "Spotify will use the active palette on next launch")
    let closedCommands = closedRequests.withLock { $0 }
    #expect(closedCommands.contains { $0.arguments == ["--no-restart", "refresh"] })
    #expect(!closedCommands.contains { $0.arguments == ["restart"] })
    #expect(!closedCommands.contains { $0.executableURL == URL(filePath: "/usr/bin/open") })

    let staleWaits = Mutex(0)
    let stale = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        ProcessResult(
          terminationStatus: 0,
          output: request.executableURL == URL(filePath: "/usr/bin/pgrep") ? "123\n" : ""
        )
      },
      waitBetweenProcessChecks: { staleWaits.withLock { $0 += 1 } }
    )
    do {
      _ = try await stale.reconciliation().run()
      Issue.record("Expected reconciliation to reject a stale Spotify process")
    } catch {
      #expect(String(describing: error) == "Spicetify did not replace the running Spotify client")
    }
    #expect(staleWaits.withLock { $0 } == 19)

    let missingAfterLaunchChecks = Mutex(0)
    let missingAfterLaunchWaits = Mutex(0)
    let missingAfterLaunch = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        guard request.executableURL == URL(filePath: "/usr/bin/pgrep") else {
          return ProcessResult(terminationStatus: 0, output: "")
        }
        return missingAfterLaunchChecks.withLock { checks in
          checks += 1
          return ProcessResult(
            terminationStatus: checks == 1 ? 0 : 1,
            output: checks == 1 ? "123\n" : ""
          )
        }
      },
      waitBetweenProcessChecks: { missingAfterLaunchWaits.withLock { $0 += 1 } }
    )
    let missingAfterLaunchOutcome = try await missingAfterLaunch.reconciliation().run()
    #expect(missingAfterLaunchOutcome.status == .failed)
    #expect(
      missingAfterLaunchOutcome.message
        == "Spicetify refreshed the palette, but Spotify did not relaunch")
    #expect(missingAfterLaunchWaits.withLock { $0 } == 19)

    try validConfiguration.replacingOccurrences(
      of: SpicetifyAdapter.colorSchemeName,
      with: "Other"
    ).write(to: configurationURL, atomically: true, encoding: .utf8)
    #expect(closed.inspection().status == .drifted)
    try "[Setting]\ncurrent_theme = text ; suffix\ncolor_scheme = MacarchyCurrent\n"
      .write(to: configurationURL, atomically: true, encoding: .utf8)
    #expect(closed.inspection().status == .drifted)
    try (validConfiguration + "[Backup]\nmalformed later section\n")
      .write(to: configurationURL, atomically: true, encoding: .utf8)
    #expect(closed.inspection().status == .failed)
    try "[Setting]\ncurrent_theme = text\ncurrent_theme = text\ncolor_scheme = MacarchyCurrent\n"
      .write(
        to: configurationURL, atomically: true, encoding: .utf8)
    #expect(closed.inspection().status == .failed)
  }

  @Test
  func spicetifySerializesOverlappingReconciliations() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let configuration = try spicetifyConfiguration(root: root).directory
    let state = Mutex((refreshes: 0, active: 0, maximumActive: 0, releaseFirst: false))
    defer { state.withLock { $0.releaseFirst = true } }
    let adapter = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 1, output: "")
        }
        let shouldWait = state.withLock { state in
          state.refreshes += 1
          state.active += 1
          state.maximumActive = max(state.maximumActive, state.active)
          return state.refreshes == 1
        }
        if shouldWait {
          while !state.withLock({ $0.releaseFirst }) {
            Thread.sleep(forTimeInterval: 0.001)
          }
        }
        state.withLock { $0.active -= 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )

    let first = Task { try await adapter.reconciliation().run() }
    try await waitUntil { state.withLock { $0.refreshes == 1 } }
    let secondStarted = Mutex(false)
    let second = Task {
      secondStarted.withLock { $0 = true }
      return try await adapter.reconciliation().run()
    }
    try await waitUntil { secondStarted.withLock { $0 } }
    try await Task.sleep(for: .milliseconds(25))
    #expect(state.withLock { $0.refreshes } == 1)

    state.withLock { $0.releaseFirst = true }
    #expect((try await first.value).status == .applied)
    #expect((try await second.value).status == .applied)
    #expect(state.withLock { $0.refreshes } == 2)
    #expect(state.withLock { $0.maximumActive } == 1)
  }

  private func spicetifyConfiguration(root: URL) throws -> (
    directory: URL, url: URL, contents: String
  ) {
    let directory = root.appending(path: "spicetify", directoryHint: .isDirectory)
    let theme = directory.appending(
      path: "Themes/\(SpicetifyAdapter.themeName)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
    let url = directory.appending(path: "config-xpui.ini")
    let contents =
      "[Setting]\nspotify_launch_flags =\ncurrent_theme = \(SpicetifyAdapter.themeName)\ncolor_scheme = \(SpicetifyAdapter.colorSchemeName)\n"
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: theme.appending(path: "color.ini"),
      withDestinationURL: root.appending(path: "current/\(SpicetifyAdapter.outputPath)")
    )
    return (directory, url, contents)
  }

}
