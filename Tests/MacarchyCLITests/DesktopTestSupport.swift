import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

func linkTarget(_ url: URL) throws -> String {
  try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

func sketchyBarAdoptionDigest(home: URL, stateRoot: URL) throws -> String {
  let provider = SketchyBarProviderPlanInspector().inspect(
    homeDirectory: home,
    stateRoot: stateRoot,
    enabled: true,
    generation: SketchyBarGenerationInspector(stateRoot: stateRoot).inspect()
  )
  return try #require(provider.adoptionEvidenceDigest)
}

extension SketchyBarCoreRuntimeController {
  /// Reports `core` for every inspection and settle.
  static func fixed(_ core: SketchyBarCoreRuntimeInspection) -> Self {
    SketchyBarCoreRuntimeController(
      inspect: { _ in core },
      settle: { _ in core },
      settleRestored: { $0.agreesWithProviderRuntime(core) }
    )
  }
}

extension SketchyBarRuntimeInspection {
  static func testRunning(
    processID: Int32,
    executablePath: String = "/opt/homebrew/Cellar/sketchybar/test/bin/sketchybar"
  ) -> Self {
    SketchyBarRuntimeInspection(
      status: .running,
      message: "running",
      processID: processID,
      executablePath: executablePath,
      serviceLabel: SketchyBarHomebrewService.serviceLabel
    )
  }
}

final class SketchyBarPublicLifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])
  private let running = Mutex(false)

  var isRunning: Bool { running.withLock { $0 } }

  var controller: SketchyBarLifecycleController {
    SketchyBarLifecycleController(
      inspect: {
        self.calls.withLock { $0.append("inspect") }
        return self.running.withLock { $0 } ? Self.runtime : .stopped
      },
      preflight: {
        self.calls.withLock { $0.append("preflight") }
        return self.running.withLock { $0 }
      },
      reload: { _ in
        self.calls.withLock { $0.append("reload") }
        return Self.runtime
      },
      start: {
        self.calls.withLock { $0.append("start") }
        self.running.withLock { $0 = true }
        return Self.runtime
      },
      stop: {
        self.calls.withLock { $0.append("stop") }
        self.running.withLock { $0 = false }
      }
    )
  }

  private static let runtime = SketchyBarRuntimeInspection.testRunning(
    processID: 42,
    executablePath: "/opt/homebrew/Cellar/sketchybar/2.23.0/bin/sketchybar"
  )
}

final class YabaiLifecycleFixture: Sendable {
  let calls = Mutex<[String]>([])
  private let running: Mutex<Bool>
  private let runtimeStatus: YabaiRuntimeStatus
  private let failingRestart: Int?

  /// `failingRestart` is the 1-based restart call that throws instead of starting yabai.
  init(running: Bool, runtimeStatus: YabaiRuntimeStatus = .converged, failingRestart: Int? = nil) {
    self.running = Mutex(running)
    self.runtimeStatus = runtimeStatus
    self.failingRestart = failingRestart
  }

  var isRunning: Bool { running.withLock { $0 } }

  var controller: YabaiLifecycleController {
    YabaiLifecycleController(
      preflight: {
        self.calls.withLock { $0.append("preflight") }
        return self.running.withLock { $0 }
      },
      restart: {
        let restarts = self.calls.withLock { calls in
          calls.append("restart")
          return calls.filter { $0 == "restart" }.count
        }
        if restarts == self.failingRestart {
          throw YabaiDesktopError.lifecycle("injected restart failure")
        }
        self.running.withLock { $0 = true }
      },
      stop: {
        self.calls.withLock { $0.append("stop") }
        self.running.withLock { $0 = false }
      },
      inspect: { composition in
        self.calls.withLock { $0.append("inspect") }
        return YabaiRuntimeInspection(
          status: self.runtimeStatus,
          message: self.runtimeStatus == .drifted ? "injected runtime drift" : "verified",
          verifiedSettings: [composition.settings.layout],
          verifiedRuleLabels: composition.settings.rules.compactMap(\.label),
          wallpaperSignalVerified: self.runtimeStatus != .drifted,
          processID: 42,
          executablePath: "/opt/homebrew/bin/yabai"
        )
      },
      waitBetweenInspections: {}
    )
  }
}
