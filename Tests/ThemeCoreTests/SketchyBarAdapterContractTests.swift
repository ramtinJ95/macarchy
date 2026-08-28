import Foundation
import Synchronization
import Testing

@testable import ThemeCore

extension AdapterContractTests {
  @Test
  func sketchyBarReloadsTheExactEntryConfigAndDetectsABrokenPaletteSeam() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let requests = Mutex([ProcessRequest]())
    let queryCount = Mutex(0)
    let settleCount = Mutex(0)
    let presentationCount = Mutex(0)
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments == ["--query", "bar"] {
          let count = queryCount.withLock { count in
            count += 1
            return count
          }
          if count < 2 {
            throw ProcessRunnerError.timedOut(SketchyBarAdapter.liveExecutableURL, 0.1)
          }
          return ProcessResult(
            terminationStatus: 0,
            output: #"{"drawing":"on","color":"0xf01e1e2e","items":["macarchy.theme.ready"]}"#
          )
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitForSettle: { settleCount.withLock { $0 += 1 } },
      waitForPresentation: { presentationCount.withLock { $0 += 1 } }
    )

    #expect(adapter.inspection().status == .ready)
    #expect(requests.withLock { $0 }.isEmpty)
    #expect(try await adapter.reconciliation().run().status == .applied)
    #expect(settleCount.withLock { $0 } == 1)
    #expect(presentationCount.withLock { $0 } == 1)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--reload", configuration.path],
            timeout: 2
          ),
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.1
          ),
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.1
          ),
        ]
    )

    try "return {}\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "colors.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(adapter.inspection().status == .drifted)
    #expect(try await adapter.reconciliation().run().status == .drifted)
    #expect(requests.withLock { $0 }.count == 3)

    try "\(SketchyBarAdapter.paletteImport(root: root))\nreturn colors\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "colors.lua"),
      atomically: true,
      encoding: .utf8
    )
    try "-- missing ready marker\n".write(
      to: configuration.deletingLastPathComponent().appending(path: "init.lua"),
      atomically: true,
      encoding: .utf8
    )
    #expect(adapter.inspection().status == .drifted)
    #expect(try await adapter.reconciliation().run().status == .drifted)
    #expect(requests.withLock { $0 }.count == 3)
  }

  @Test
  func sketchyBarRuntimeInspectionIsExplicitAndNonMutating() throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let requests = Mutex([ProcessRequest]())
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(
          terminationStatus: 0,
          output: #"{"drawing":"off","color":"0x44000000","items":[]}"#
        )
      }
    )

    #expect(adapter.inspection().status == .ready)
    #expect(requests.withLock { $0 }.isEmpty)
    #expect(adapter.inspection(includeRuntimeChecks: true).status == .drifted)
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: SketchyBarAdapter.liveExecutableURL,
            arguments: ["--query", "bar"],
            timeout: 0.2
          )
        ]
    )
  }

  @Test
  func sketchyBarReportsUnavailableControlAndReloadFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try Self.sketchyBarConfiguration(root: root)

    let unavailable = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { false },
      processRunner: ProcessRunner { _ in
        Issue.record("Unavailable SketchyBar control must not run")
        return ProcessResult(terminationStatus: 0, output: "")
      }
    )
    #expect(unavailable.inspection().status == .failed)
    #expect(try await unavailable.reconciliation().run().status == .failed)

    let rejected = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { _ in
        ProcessResult(terminationStatus: 1, output: "reload denied")
      }
    )
    let outcome = try await rejected.reconciliation().run()
    #expect(outcome.status == .failed)
    #expect(outcome.message == "reload denied")
  }

  @Test
  func sketchyBarStopsPollingWhenTheSettleWindowIsExhausted() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let queryCount = Mutex(0)
    let settleCount = Mutex(0)
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.arguments == ["--query", "bar"] {
          queryCount.withLock { $0 += 1 }
          return ProcessResult(
            terminationStatus: 0,
            output: #"{"drawing":"off","color":"0x44000000","items":[]}"#
          )
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitForSettle: { settleCount.withLock { $0 += 1 } },
      waitForPresentation: {
        Issue.record("Presentation wait must not run for drift")
      }
    )

    let outcome = try await adapter.reconciliation().run()

    #expect(outcome.status == .drifted)
    #expect(queryCount.withLock { $0 } == 11)
    #expect(settleCount.withLock { $0 } == 10)
  }

  @Test
  func sketchyBarRetriesQueryTimeoutsButFailsWhenTheWholeWindowTimesOut() async throws {
    let root = try temporaryDirectory()
    defer {
      makeWritableForRemoval(root)
      try? FileManager.default.removeItem(at: root)
    }
    let configuration = try Self.sketchyBarConfiguration(root: root)
    _ = try testActivator(root: root).activate(package: catppuccinPackage())
    let queryCount = Mutex(0)
    let settleCount = Mutex(0)
    let adapter = SketchyBarAdapter(
      root: root,
      configurationURL: configuration,
      executableURL: SketchyBarAdapter.liveExecutableURL,
      controlIsAvailable: { true },
      processRunner: ProcessRunner { request in
        if request.arguments == ["--query", "bar"] {
          queryCount.withLock { $0 += 1 }
          throw ProcessRunnerError.timedOut(SketchyBarAdapter.liveExecutableURL, 0.1)
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      waitForSettle: { settleCount.withLock { $0 += 1 } },
      waitForPresentation: {
        Issue.record("Presentation wait must not run without an observed state")
      }
    )

    let outcome = try await adapter.reconciliation().run()

    #expect(outcome.status == .failed)
    #expect(outcome.message?.contains("timed out through the bounded settle window") == true)
    #expect(queryCount.withLock { $0 } == 11)
    #expect(settleCount.withLock { $0 } == 10)
  }

  @Test
  func sketchyBarEscapesCustomStateRootsInLuaImports() {
    let root = URL(filePath: "/tmp/quote\"back\\slash\nline")
    #expect(
      SketchyBarAdapter.paletteImport(root: root)
        == #"local colors = dofile("/tmp/quote\"back\\slash\nline/current/generated/sketchybar.lua")"#
    )
  }

}
