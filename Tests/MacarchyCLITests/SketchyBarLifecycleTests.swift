import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SketchyBarLifecycleTests {
  @Test
  func unsupportedVersionBlocksBeforeRuntimeInspection() {
    let requests = Mutex([ProcessRequest]())
    let service = SketchyBarHomebrewService(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 0, output: "sketchybar-v3.0.0")
      },
      serviceInspection: {
        Issue.record("runtime inspection must not run for an unsupported version")
        return Self.runtime
      },
      controlIsAvailable: { true },
      wait: {}
    )

    #expect(throws: SketchyBarDesktopError.self) { try service.preflight() }
    #expect(
      requests.withLock { $0 }
        == [
          ProcessRequest(
            executableURL: SketchyBarHomebrewService.controlURL,
            arguments: ["--version"],
            timeout: 2
          )
        ]
    )
  }

  @Test
  func reloadUsesTheExactReviewedConfigurationPath() throws {
    let requests = Mutex([ProcessRequest]())
    let service = SketchyBarHomebrewService(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      serviceInspection: { Self.runtime },
      controlIsAvailable: { true },
      wait: {}
    )
    let configuration = URL(filePath: "/tmp/home/.config/sketchybar/../sketchybar/sketchybarrc")

    let runtime = try service.reload(configurationURL: configuration)

    #expect(runtime == Self.runtime)
    #expect(requests.withLock { $0.count } == 1)
    #expect(
      requests.withLock { $0.first?.arguments }
        == ["--reload", "/tmp/home/.config/sketchybar/sketchybarrc"]
    )
  }

  @Test
  func startAndStopStayScopedToTheHomebrewSketchyBarService() throws {
    struct State: Sendable {
      var running = false
      var transientInspectionFailures = 0
      var waits = 0
    }
    let state = Mutex(State())
    let requests = Mutex([ProcessRequest]())
    let service = SketchyBarHomebrewService(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        state.withLock {
          if request.arguments.starts(with: ["services", "start"]) {
            $0.running = true
          } else if request.arguments.starts(with: ["services", "stop"]) {
            $0.running = false
          }
          $0.transientInspectionFailures = 1
        }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      serviceInspection: {
        try state.withLock {
          if $0.transientInspectionFailures > 0 {
            $0.transientInspectionFailures -= 1
            throw SketchyBarLifecycleTestError.transitionalInspection
          }
          return $0.running ? Self.runtime : .stopped
        }
      },
      controlIsAvailable: { true },
      wait: { state.withLock { $0.waits += 1 } }
    )

    #expect(try service.start() == Self.runtime)
    try service.stop()

    let observed = requests.withLock { $0 }
    #expect(
      observed.map(\.arguments)
        == [
          ["services", "start", SketchyBarHomebrewService.formula],
          ["services", "stop", SketchyBarHomebrewService.formula],
        ]
    )
    #expect(observed.allSatisfy { $0.executableURL == SketchyBarHomebrewService.brewURL })
    #expect(
      observed.allSatisfy {
        $0.environmentOverrides == SketchyBarHomebrewService.mutationEnvironment
      }
    )
    #expect(state.withLock { $0.waits } == 2)
  }

  @Test
  func untrustedFormulaFailureNamesTheExternalTrustDecision() {
    let service = SketchyBarHomebrewService(
      processRunner: ProcessRunner { _ in
        ProcessResult(
          terminationStatus: 1,
          output: "Refusing to load formula because the tap is not trusted"
        )
      },
      serviceInspection: { .stopped },
      controlIsAvailable: { true },
      wait: {}
    )

    do {
      _ = try service.start()
      Issue.record("start should fail")
    } catch {
      #expect(String(describing: error).contains("brew trust felixkratz/formulae/sketchybar"))
    }
  }

  @Test
  func loadedServiceRequiresTheExactProgramAndSoleArgument() {
    let executable = SketchyBarHomebrewService.serviceExecutableURL.path
    let plist = "/Users/test/Library/LaunchAgents/homebrew.mxcl.sketchybar.plist"
    let output = """
      gui/501/homebrew.mxcl.sketchybar = {
        path = \(plist)
        state = running
        program = \(executable)
        arguments = {
          \(executable)
        }
        pid = 123
      }
      """

    #expect(
      SketchyBarHomebrewService.loadedServiceMatches(
        output,
        propertyListPath: plist,
        processID: 123
      )
    )
    #expect(
      !SketchyBarHomebrewService.loadedServiceMatches(
        output.replacingOccurrences(
          of: "\(executable)\n  }",
          with: "\(executable)\n    --config /tmp/foreign\n  }"
        ),
        propertyListPath: plist,
        processID: 123
      )
    )
  }

  @Test
  func malformedProcessEvidenceIsNeverPersisted() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-lifecycle-\(UUID().uuidString.lowercased())"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SketchyBarLifecycleEvidenceStore(stateRoot: root)
    let generationID = "s-00000000-0000-0000-0000-000000000000"
    let malformed = [
      SketchyBarRuntimeInspection(
        status: .running,
        message: "running",
        processID: 0,
        executablePath: "/opt/homebrew/Cellar/sketchybar/test/bin/sketchybar",
        serviceLabel: SketchyBarHomebrewService.serviceLabel
      ),
      SketchyBarRuntimeInspection(
        status: .running,
        message: "running",
        processID: 123,
        executablePath: "/tmp/sketchybar",
        serviceLabel: SketchyBarHomebrewService.serviceLabel
      ),
    ]

    for runtime in malformed {
      #expect(throws: SketchyBarDesktopError.self) {
        try store.write(
          SketchyBarLifecycleEvidence(
            generationID: generationID,
            runtime: runtime,
            coreRuntime: Self.coreRuntime
          )
        )
      }
    }
  }

  @Test
  func maximumBoundedPartialEvidenceRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-lifecycle-\(UUID().uuidString.lowercased())"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    var items = ["macarchy.clock", "macarchy.spaces.unavailable", "macarchy.theme.ready"]
    items += (0..<61).map {
      let prefix = "personal.\($0)."
      return prefix + String(repeating: "x", count: 128 - prefix.utf8.count)
    }
    let evidence = SketchyBarLifecycleEvidence(
      generationID: "s-00000000-0000-0000-0000-000000000000",
      runtime: Self.runtime,
      coreRuntime: SketchyBarCoreRuntimeInspection(
        status: .partial,
        message: "partial",
        themeGenerationID: "g-00000000-0000-0000-0000-000000000000",
        barColor: "0xf01e1e2e",
        items: items.sorted(),
        clockLabelPresent: true
      )
    )
    let store = SketchyBarLifecycleEvidenceStore(stateRoot: root)

    #expect(evidence.isValid)
    try store.write(evidence)
    #expect(try store.read() == evidence)
  }

  private static let runtime = SketchyBarRuntimeInspection(
    status: .running,
    message: "running",
    processID: 123,
    executablePath: "/opt/homebrew/Cellar/sketchybar/test/bin/sketchybar",
    serviceLabel: SketchyBarHomebrewService.serviceLabel
  )

  private static let coreRuntime = SketchyBarCoreRuntimeInspection(
    status: .converged,
    message: "converged",
    themeGenerationID: "g-00000000-0000-0000-0000-000000000000",
    barColor: "0xf01e1e2e",
    items: ["macarchy.clock", "macarchy.spaces.unavailable", "macarchy.theme.ready"],
    clockLabelPresent: true
  )
}

private enum SketchyBarLifecycleTestError: Error {
  case transitionalInspection
}
