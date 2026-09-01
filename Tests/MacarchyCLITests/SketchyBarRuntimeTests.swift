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
    let verifier = fixture.verifier {
      Self.dynamicResult($0, fixture: fixture, indices: [2, 1])
    }

    let inspection = verifier.inspect(fixture.dynamicComposition)

    #expect(inspection.status == .converged)
    #expect(inspection.isValidEvidence)
    #expect(inspection.spaceIndices == [1, 2])
    #expect(
      inspection.items == [
        "macarchy.clock", "macarchy.space.1", "macarchy.space.2", "macarchy.theme.ready",
      ])
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

  @Test
  func verifiesHiddenSpacesAndACenteredClockWithoutQueryingYabai() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      """
      schema_version = 1
      [sketchybar]
      left = []
      center = ["clock"]
      right = []
      """
    )
    let verifier = fixture.verifier { request in
      switch request.arguments {
      case ["--query", "bar"]:
        return ProcessResult(
          terminationStatus: 0,
          output: """
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
             "margin":8,"corner_radius":9,
             "items":["macarchy.clock","macarchy.theme.ready"]}
            """
        )
      case ["--query", "macarchy.clock"]:
        return ProcessResult(
          terminationStatus: 0,
          output: Self.itemJSON(
            name: "macarchy.clock",
            drawing: "on",
            position: "center",
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
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
    }

    let inspection = verifier.inspect(composition)

    #expect(inspection.status == .converged)
    #expect(inspection.isValidEvidence)
    #expect(inspection.spaceIndices.isEmpty)
  }

  @Test
  func classifiesDynamicSpaceFailuresWithoutHidingMalformedResponses() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for (observation, expected) in [
      (SpaceObservation.misplaced, SketchyBarCoreRuntimeStatus.drifted),
      (.missing, .drifted),
      (.malformed, .failed),
    ] {
      let verifier = fixture.verifier { request in
        if request.executableURL.path == SketchyBarCoreRuntimeVerifier.controlURL.path,
          request.arguments == ["--query", "macarchy.space.1"]
        {
          if observation == .missing {
            return ProcessResult(
              terminationStatus: 1,
              output: "[!] Query: Invalid query, or item 'macarchy.space.1' not found"
            )
          }
          return ProcessResult(
            terminationStatus: 0,
            output: observation == .malformed
              ? "not json"
              : Self.spaceItemJSON(name: "macarchy.space.1", position: "right")
          )
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      }

      let inspection = verifier.inspect(fixture.dynamicComposition)

      #expect(inspection.status == expected, Comment(rawValue: observation.rawValue))
    }
  }

  @Test
  func verifiesAnAllHiddenLayoutFromTheReadyMarkerAlone() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      """
      schema_version = 1
      [sketchybar]
      left = []
      center = []
      right = []
      """
    )
    let verifier = fixture.verifier { request in
      switch request.arguments {
      case ["--query", "bar"]:
        return ProcessResult(
          terminationStatus: 0,
          output: """
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
             "margin":8,"corner_radius":9,"items":["macarchy.theme.ready"]}
            """
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
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
    }

    let inspection = verifier.inspect(composition)

    #expect(inspection.status == .converged)
    #expect(inspection.isValidEvidence)
    #expect(inspection.items == ["macarchy.theme.ready"])
  }

  @Test
  func rejectsChangingDynamicSpaceSnapshotsAsDrift() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for change in [SnapshotChange.yabai, .bar] {
      let yabaiQueries = Mutex(0)
      let barQueries = Mutex(0)
      let verifier = fixture.verifier { request in
        if request.executableURL.path == SketchyBarCoreRuntimeVerifier.yabaiURL.path,
          request.arguments == ["-m", "query", "--spaces"]
        {
          let query = yabaiQueries.withLock { count in
            count += 1
            return count
          }
          let output =
            change == .yabai && query == 2
            ? #"[{"index":1},{"index":2}]"# : #"[{"index":1}]"#
          return ProcessResult(terminationStatus: 0, output: output)
        }
        if request.executableURL.path == SketchyBarCoreRuntimeVerifier.controlURL.path,
          request.arguments == ["--query", "bar"]
        {
          let query = barQueries.withLock { count in
            count += 1
            return count
          }
          let extra = change == .bar && query == 2 ? ",\"foreign.item\"" : ""
          return ProcessResult(
            terminationStatus: 0,
            output: """
              {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
               "margin":8,"corner_radius":9,
               "items":["macarchy.clock","macarchy.theme.ready","macarchy.space.1"\(extra)]}
              """
          )
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      }

      let inspection = verifier.inspect(fixture.dynamicComposition)

      #expect(inspection.status == .drifted, Comment(rawValue: change.rawValue))
    }
  }

  private static func dynamicResult(
    _ request: ProcessRequest,
    fixture: SketchyBarRuntimeFixture,
    indices: [Int]
  ) -> ProcessResult {
    switch (request.executableURL.path, request.arguments) {
    case (SketchyBarCoreRuntimeVerifier.yabaiURL.path, ["-m", "query", "--spaces"]):
      let spaces = indices.map { "{\"index\":\($0)}" }.joined(separator: ",")
      return ProcessResult(terminationStatus: 0, output: "[\(spaces)]")
    case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "bar"]):
      let names =
        ["macarchy.clock", "macarchy.theme.ready"]
        + indices.map { "macarchy.space.\($0)" }
      let items = names.map { "\"\($0)\"" }.joined(separator: ",")
      return ProcessResult(
        terminationStatus: 0,
        output: """
          {"position":"top","drawing":"on","color":"0xf01e1e2e","height":35,
           "margin":8,"corner_radius":9,"items":[\(items)]}
          """
      )
    case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "macarchy.clock"]):
      return ProcessResult(
        terminationStatus: 0,
        output: itemJSON(
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
        output: itemJSON(
          name: "macarchy.theme.ready",
          drawing: "off",
          position: "right"
        )
      )
    case (let path, let arguments)
    where path == SketchyBarCoreRuntimeVerifier.controlURL.path
      && arguments.count == 2
      && arguments[0] == "--query"
      && arguments[1].hasPrefix("macarchy.space."):
      return ProcessResult(
        terminationStatus: 0,
        output: spaceItemJSON(name: arguments[1], position: "left")
      )
    default:
      Issue.record("unexpected request: \(request)")
      return ProcessResult(terminationStatus: 1, output: "unexpected")
    }
  }

  private static func spaceItemJSON(name: String, position: String) -> String {
    let index = Int(name.split(separator: ".").last!)!
    return itemJSON(
      name: name,
      type: "space",
      drawing: "on",
      position: position,
      associatedSpaceMask: UInt32(1) << UInt32(index),
      clickScript: "\(SketchyBarCoreRuntimeVerifier.yabaiURL.path) -m space --focus \(index)"
    )
  }

  private static func itemJSON(
    name: String,
    type: String = "item",
    drawing: String,
    position: String,
    associatedSpaceMask: UInt32 = 0,
    label: String = "",
    labelDrawing: String = "off",
    script: String = "(null)",
    clickScript: String = "(null)",
    updateFrequency: Int = 0
  ) -> String {
    """
    {"name":"\(name)","type":"\(type)",
     "geometry":{"drawing":"\(drawing)","position":"\(position)","associated_space_mask":\(associatedSpaceMask)},
     "label":{"value":"\(label)","drawing":"\(labelDrawing)"},
     "scripting":{"script":"\(script)","click_script":"\(clickScript)","update_freq":\(updateFrequency)}}
    """
  }
}

private enum SpaceObservation: String, Sendable {
  case misplaced
  case missing
  case malformed
}

private enum SnapshotChange: String, Sendable {
  case yabai
  case bar
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

  func composition(_ profile: String) throws -> SketchyBarComposition {
    try SketchyBarConfigurationComposer().compose(
      defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml"),
      profile: PortableProfileLoader().decode(
        profile,
        source: root.appending(path: "custom.toml")
      ),
      stateRoot: state
    )
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
