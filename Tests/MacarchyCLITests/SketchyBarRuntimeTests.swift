import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SketchyBarRuntimeTests {
  @Test
  func verifiesTheCanonicalPaletteDynamicSpacesClockAndHiddenReadyMarker() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let requests = Mutex([ProcessRequest]())
    let verifier = fixture.verifier { request in
      requests.withLock { $0.append(request) }
      switch (request.executableURL.path, request.arguments) {
      case (SketchyBarCoreRuntimeVerifier.yabaiURL.path, ["-m", "query", "--spaces"]):
        return ProcessResult(terminationStatus: 0, output: #"[{"index":2},{"index":1}]"#)
      case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "bar"]):
        return ProcessResult(
          terminationStatus: 0,
          output: """
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
             "margin":8,"corner_radius":9,
             "items":["macarchy.space.2","macarchy.clock","macarchy.theme.ready","macarchy.space.1"]}
            """
        )
      case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "macarchy.clock"]):
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.clock",
            drawing: "on",
            position: "right",
            label: "Mon 01 Jan 12:00",
            labelDrawing: "on",
            script: fixture.clockScript,
            updateFrequency: 30
          )
        )
      case (
        SketchyBarCoreRuntimeVerifier.controlURL.path,
        ["--query", "macarchy.theme.ready"]
      ):
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.theme.ready",
            drawing: "off",
            position: "right"
          )
        )
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
    }

    let inspection = verifier.inspect(fixture.dynamicComposition)

    #expect(inspection.status == .converged)
    #expect(inspection.isValidEvidence)
    #expect(inspection.spaceIndices == [1, 2])
    #expect(
      inspection.items == [
        "macarchy.clock", "macarchy.space.1", "macarchy.space.2", "macarchy.theme.ready",
      ])
    #expect(requests.withLock { $0 }.count == 4)
  }

  @Test
  func verifiesTheVisibleFallbackWhenTheDesktopRoleIsDisabled() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let verifier = fixture.verifier { request in
      switch request.arguments {
      case ["--query", "bar"]:
        return ProcessResult(
          terminationStatus: 0,
          output: """
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
             "margin":8,"corner_radius":9,
             "items":["macarchy.spaces.unavailable","macarchy.clock","macarchy.theme.ready"]}
            """
        )
      case ["--query", "macarchy.clock"]:
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.clock",
            drawing: "on",
            position: "right",
            label: "Mon 01 Jan 12:00",
            labelDrawing: "on",
            script: fixture.clockScript,
            updateFrequency: 30
          )
        )
      case ["--query", "macarchy.theme.ready"]:
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.theme.ready",
            drawing: "off",
            position: "right"
          )
        )
      case ["--query", "macarchy.spaces.unavailable"]:
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.spaces.unavailable",
            drawing: "on",
            position: "left",
            label: "Spaces unavailable",
            labelDrawing: "on"
          )
        )
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
    }

    let inspection = verifier.inspect(fixture.fallbackComposition)

    #expect(inspection.status == .converged)
    #expect(inspection.spaceIndices.isEmpty)
    #expect(inspection.items.contains("macarchy.spaces.unavailable"))
  }

  private static func itemJSON(
    name: String,
    drawing: String,
    position: String,
    label: String = "",
    labelDrawing: String = "off",
    script: String = "(null)",
    updateFrequency: Int = 0
  ) -> String {
    """
    {"name":"\(name)","type":"item",
     "geometry":{"drawing":"\(drawing)","position":"\(position)"},
     "label":{"value":"\(label)","drawing":"\(labelDrawing)"},
     "scripting":{"script":"\(script)","update_freq":\(updateFrequency)}}
    """
  }
}

private struct SketchyBarRuntimeFixture {
  let root: URL
  let state: URL
  let dynamicComposition: SketchyBarComposition
  let fallbackComposition: SketchyBarComposition

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-runtime-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    state = root.appending(path: "state", directoryHint: .isDirectory)
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(
        path: "Themes/catppuccin-mocha",
        directoryHint: .isDirectory
      )
    )
    _ = try ThemeActivator(root: state).activate(package: package)
    let defaults = repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml")
    let dynamicProfile = try PortableProfileLoader().decode(
      "schema_version = 1\n",
      source: root.appending(path: "dynamic.toml")
    )
    dynamicComposition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaults,
      profile: dynamicProfile,
      stateRoot: state
    )
    let fallbackProfile = try PortableProfileLoader().decode(
      """
      schema_version = 1
      [desktop]
      provider = "disabled"
      """,
      source: root.appending(path: "fallback.toml")
    )
    fallbackComposition = try SketchyBarConfigurationComposer().compose(
      defaultsURL: defaults,
      profile: fallbackProfile,
      stateRoot: state
    )
  }

  var clockScript: String {
    state.appending(path: "desktop/sketchybar/current/plugins/clock.sh").path
  }

  func verifier(
    _ run: @escaping @Sendable (ProcessRequest) throws -> ProcessResult
  ) -> SketchyBarCoreRuntimeVerifier {
    SketchyBarCoreRuntimeVerifier(
      stateRoot: state,
      processRunner: ProcessRunner(run: run),
      waitForSettle: {},
      waitForPresentation: {}
    )
  }
}
