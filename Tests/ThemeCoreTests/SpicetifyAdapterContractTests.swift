import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func spicetifyRefreshIsAwaitedRequiredAndNeverRestartsSpotify() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let configuration = try spicetifyConfiguration(root: root).directory
    let requests = Mutex([ProcessRequest]())
    let finished = Mutex(false)
    let adapter = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 0, output: "123\n")
        }
        Thread.sleep(forTimeInterval: 0.1)
        finished.withLock { $0 = true }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      spicetifyVersionProvider: { "2.44.0" },
      spotifyVersionProvider: { "1.2.97.3" }
    )

    let task = Task {
      try await ThemeReconciler(statusStore: ReconciliationStatusStore(root: root)).reconcile(
        manifest: manifest,
        adapters: [adapter.reconciliation()]
      )
    }
    try await waitUntil { requests.withLock { $0.count == 2 } }
    #expect(!finished.withLock { $0 })
    let record = try await task.value
    #expect(
      record.results == [
        AdapterResult(
          adapterID: "spicetify",
          requirement: .required,
          status: .restartRequired,
          message:
            "Spicetify refreshed without restarting Spotify; restart the running client manually to repaint"
        )
      ]
    )
    let observed = requests.withLock { $0 }
    #expect(observed.contains { $0.arguments == ["--no-restart", "refresh"] })
    #expect(!observed.contains { $0.arguments == ["restart"] })
    #expect(!observed.contains { $0.executableURL == URL(filePath: "/usr/bin/open") })
  }

  @Test
  func spicetifyRuntimeEvidenceMakesMatchingRepeatANoopAndVersionsInvalidateIt() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let configuration = try spicetifyConfiguration(root: root).directory
    let versions = Mutex((spicetify: "2.44.0", spotify: "1.2.97"))
    let refreshes = Mutex(0)
    let adapter = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 1, output: "")
        }
        refreshes.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      spicetifyVersionProvider: { versions.withLock { $0.spicetify } },
      spotifyVersionProvider: { versions.withLock { $0.spotify } }
    )

    #expect((try await adapter.reconciliation().run()).status == .applied)
    #expect((try await adapter.reconciliation().run()).status == .applied)
    #expect(refreshes.withLock { $0 } == 1)
    versions.withLock { $0.spicetify = "2.45.0" }
    _ = try await adapter.reconciliation().run()
    versions.withLock { $0.spotify = "1.2.98" }
    _ = try await adapter.reconciliation().run()
    #expect(refreshes.withLock { $0 } == 3)
  }

  @Test
  func spicetifyRejectsVersionsAndConfigurationDrift() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try spicetifyConfiguration(root: root)
    let old = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: fixture.directory,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") },
      spicetifyVersionProvider: { "2.43.9" },
      spotifyVersionProvider: { "1.2.97" }
    )
    #expect(old.inspection().status == .failed)

    let current = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: fixture.directory,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") },
      spicetifyVersionProvider: { "2.44.0" },
      spotifyVersionProvider: { "not-a-version" }
    )
    #expect(current.inspection().status == .failed)

    try fixture.contents.replacingOccurrences(of: "MacarchyCurrent", with: "Other")
      .write(to: fixture.url, atomically: true, encoding: .utf8)
    let drifted = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: fixture.directory,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") }
    )
    #expect(drifted.inspection().status == .drifted)
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
    let adapter = SpicetifyAdapter(
      root: root,
      configurationDirectoryURL: configuration,
      executableURL: SpicetifyAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.executableURL == URL(filePath: "/usr/bin/pgrep") {
          return ProcessResult(terminationStatus: 1, output: "")
        }
        let wait = state.withLock { value in
          value.refreshes += 1
          value.active += 1
          value.maximumActive = max(value.maximumActive, value.active)
          return value.refreshes == 1
        }
        while wait && !state.withLock({ $0.releaseFirst }) {
          Thread.sleep(forTimeInterval: 0.001)
        }
        state.withLock { $0.active -= 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )
    let first = Task { try await adapter.reconciliation().run() }
    try await waitUntil { state.withLock { $0.refreshes == 1 } }
    let second = Task { try await adapter.reconciliation().run() }
    try await Task.sleep(for: .milliseconds(25))
    #expect(state.withLock { $0.refreshes } == 1)
    state.withLock { $0.releaseFirst = true }
    _ = try await first.value
    _ = try await second.value
    #expect(state.withLock { $0.refreshes } == 1)
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
