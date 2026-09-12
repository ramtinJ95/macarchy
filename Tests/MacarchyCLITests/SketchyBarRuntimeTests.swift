import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SketchyBarRuntimeTests {
  @Test(arguments: [
    "visible", "hidden", "stale", "dead", "starting", "error", "position",
    "script", "frequency", "updates", "events",
  ])
  func toggleRequiresFreshOwnedHeartbeatButNotAConstantVisibility(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = []\nright = [\"toggle\"]\n")
    let token = "00000000-0000-0000-0000-000000000001"
    let verifier = SketchyBarCoreRuntimeVerifier(
      stateRoot: fixture.state,
      processRunner: ProcessRunner { request in
        let output: String
        switch request.arguments {
        case ["--query", "bar"]:
          output = """
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"\(condition == "hidden" ? "on" : "off")","y_offset":0,"topmost":"on","items":["macarchy.toggle","macarchy.theme.ready"]}
            """
        case ["--query", "macarchy.toggle"]:
          let label =
            condition == "starting"
            ? token + "|starting"
            : condition == "error"
              ? "Toggle ERR" : token + "|7|\(condition == "stale" ? "1000" : "100000")|1000000"
          output = Self.itemJSON(
            name: "macarchy.toggle", drawing: condition == "error" ? "on" : "off",
            position: condition == "position" ? "left" : "right", label: label,
            script: condition == "script"
              ? "(null)"
              : SketchyBarConfigurationComposer.toggleScript(
                pluginPath: fixture.state.appending(
                  path: "desktop/sketchybar/current/plugins/toggle.sh"
                ).path,
                token: token),
            updateFrequency: condition == "frequency" ? 0 : 1,
            updateMask: condition == "events" ? 0 : 24,
            updates: condition == "updates" ? "when_shown" : "on")
        case ["--query", "events"]:
          output = #"{"system_woke":{"bit":8},"display_change":{"bit":16}}"#
        default:
          output = Self.itemJSON(name: "macarchy.theme.ready", drawing: "off", position: "right")
        }
        return .init(terminationStatus: 0, output: output)
      }, waitForSettle: {}, waitForPresentation: {},
      toggleProcessMatches: { $0.pid == 7 && $0.started == 1_000_000 && condition != "dead" },
      uptime: { 100 })
    let inspection = verifier.inspect(composition)
    let valid = ["visible", "hidden"].contains(condition)
    #expect(inspection.status == (valid ? .converged : .drifted))
    if valid {
      #expect(inspection.toggleStatePresent == true && inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
      #expect(
        !String(decoding: try JSONEncoder().encode(inspection), as: UTF8.self).contains(token))
    }
  }

  @Test(arguments: ["valid", "permission", "position", "script", "event"])
  func appleRequiresSuccessfulHelperPresentationAndOwnedInteraction(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = [\"apple\"]\nright = []\n")
    let verifier = fixture.verifier { request in
      let output: String
      switch request.arguments {
      case ["--query", "bar"]:
        output =
          #"{"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":["macarchy.apple","macarchy.theme.ready"]}"#
      case ["--query", "events"]:
        output = #"{"mouse.clicked":{"bit":1}}"#
      case ["--query", "macarchy.apple"]:
        output = Self.itemJSON(
          name: "macarchy.apple", drawing: "on",
          position: condition == "position" ? "right" : "left",
          label: condition == "permission" ? "Menu ERR" : "",
          labelDrawing: condition == "permission" ? "on" : "off",
          script: condition == "script"
            ? "/foreign"
            : fixture.state.appending(path: "desktop/sketchybar/current/plugins/apple.sh").path,
          updateMask: condition == "event" ? 0 : 1)
      default:
        output = Self.itemJSON(name: "macarchy.theme.ready", drawing: "off", position: "right")
      }
      return .init(terminationStatus: 0, output: output)
    }
    let inspection = verifier.inspect(composition)
    #expect(inspection.status == (condition == "valid" ? .converged : .drifted))
    if condition == "valid" {
      #expect(inspection.appleStatePresent == true)
      #expect(inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
    }
  }

  @Test(arguments: [
    "playing", "inactive", "error", "position", "script", "event", "control", "preview",
  ])
  func mediaVerifiesPresentationControlsAndVolatileEvidence(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = []\ncenter = []\nright = [\"media\"]\n")
    let script = fixture.state.appending(path: "desktop/sketchybar/current/plugins/media.sh").path
    let verifier = fixture.verifier { request in
      let name = request.arguments.last ?? ""
      let output: String
      if name == "bar" {
        let items = (SketchyBarMedia.items + ["macarchy.theme.ready"]).map { "\"\($0)\"" }.joined(
          separator: ",")
        output = """
          {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":[\(items)]}
          """
      } else if name == "events" {
        output =
          #"{"mouse.clicked":{"bit":1},"mouse.entered":{"bit":2},"mouse.exited":{"bit":4},"mouse.exited.global":{"bit":8},"system_woke":{"bit":16}}"#
      } else if name == "macarchy.theme.ready" {
        output = Self.itemJSON(name: name, drawing: "off", position: "right")
      } else {
        let main = name == "macarchy.media"
        let detail = ["macarchy.media.title", "macarchy.media.artist"].contains(name)
        let preview = name == "macarchy.media.preview"
        let label =
          preview
          ? (condition == "preview" ? "bad" : "0")
          : main
            ? (condition == "error"
              ? "ERR" : condition == "inactive" ? "inactive" : String(repeating: "a", count: 64))
            : detail ? "Example" : ""
        let click =
          main || detail || preview
          ? "(null)"
          : SketchyBarConfigurationComposer.pluginClickScript(sender: name, pluginPath: script)
        let object: [String: Any] = [
          "name": name, "type": "item",
          "geometry": [
            "position": condition == "position" && main
              ? "left" : main || detail || preview ? "right" : "popup",
            "drawing": preview || (condition == "inactive" && (main || detail)) ? "off" : "on",
            "associated_space_mask": 0,
          ],
          "label": ["value": label, "drawing": detail ? "on" : "off"],
          "scripting": [
            "script": main || detail ? (condition == "script" ? "/unmanaged" : script) : "(null)",
            "update_freq": main ? 2 : 0, "update_mask": condition == "event" ? 0 : main ? 31 : 14,
            "click_script": condition == "control" && !main && !detail && !preview
              ? "unmanaged" : click,
          ],
        ]
        output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      }
      return .init(terminationStatus: 0, output: output)
    }
    let inspection = verifier.inspect(composition)
    let valid = ["playing", "inactive"].contains(condition)
    #expect(inspection.status == (valid ? .converged : .drifted))
    if valid {
      #expect(inspection.mediaStatePresent == true)
      #expect(inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
      let data = try JSONEncoder().encode(inspection)
      #expect(!String(decoding: data, as: UTF8.self).contains("Example"))
      #expect(
        try JSONDecoder().decode(SketchyBarCoreRuntimeInspection.self, from: data) == inspection)
    }
  }

  @Test(arguments: ["external", "misplaced", "preview", "events", "error"])
  func calendarVerifiesAdaptivePlacementPreviewStateAndSubscriptions(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let verifier = SketchyBarCoreRuntimeVerifier(
      stateRoot: fixture.state,
      processRunner: ProcessRunner { request in
        let result = Self.dynamicResult(request, fixture: fixture, indices: [1])
        var output = result.output
        if request.arguments == ["--query", "macarchy.clock"], condition != "misplaced" {
          output = output.replacingOccurrences(
            of: "\"position\":\"right\"", with: "\"position\":\"center\"")
          if condition == "events" {
            output = output.replacingOccurrences(
              of: "\"update_mask\":25", with: "\"update_mask\":1")
          }
          if condition == "error" {
            output = output.replacingOccurrences(of: "Mon 01 Jan 12:00", with: "ERR")
          }
        }
        if request.arguments == ["--query", SketchyBarCalendar.previewItem], condition == "preview"
        {
          output = output.replacingOccurrences(of: "\"value\":\"0\"", with: "\"value\":\"bad\"")
        }
        return ProcessResult(terminationStatus: result.terminationStatus, output: output)
      }, waitForSettle: {}, waitForPresentation: {}, hasExternalDisplay: { true })
    #expect(
      verifier.inspect(fixture.dynamicComposition).status
        == (condition == "external" ? .converged : .drifted))
  }

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
        "macarchy.clock", "macarchy.clock.preview", "macarchy.space.1", "macarchy.space.2",
        "macarchy.theme.ready",
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
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
             "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on",
             "items":["macarchy.spaces.unavailable","macarchy.clock","macarchy.clock.preview","macarchy.theme.ready"]}
            """
        )
      case ["--query", "macarchy.clock.preview"], ["--query", "events"]:
        return Self.dynamicResult(request, fixture: fixture, indices: [])
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
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
             "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on",
             "items":["macarchy.clock","macarchy.clock.preview","macarchy.theme.ready"]}
            """
        )
      case ["--query", "macarchy.clock.preview"], ["--query", "events"]:
        return Self.dynamicResult(request, fixture: fixture, indices: [])
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
            {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
             "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":["macarchy.theme.ready"]}
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
  func verifiesTheOptInVolumeLevelAndRequiredEventSubscriptions() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      """
      schema_version = 1
      [sketchybar]
      left = []
      center = []
      right = ["volume"]
      """
    )

    for (label, updateMask, sliderLevel, rowState, expected) in [
      ("42%", UInt64(4_111), "42", "absent", SketchyBarCoreRuntimeStatus.converged),
      ("09%", UInt64(4_111), "9", "absent", .converged),
      ("42%", UInt64(8), "42", "absent", .drifted),
      ("042%", UInt64(4_111), "42", "absent", .drifted),
      ("9%", UInt64(4_111), "9", "absent", .drifted),
      ("42%", UInt64(4_111), "101", "absent", .drifted),
      ("42%", UInt64(4_111), "42", "valid", .converged),
      ("42%", UInt64(4_111), "42", "unmanaged", .drifted),
      ("42%", UInt64(4_111), "42", "wrong_parent", .drifted),
    ] {
      let rowName = SketchyBarAudioPicker.prefix + "7." + String(repeating: "a", count: 64)
      let verifier = fixture.verifier { request in
        switch request.arguments {
        case ["--query", "bar"]:
          return ProcessResult(
            terminationStatus: 0,
            output: """
              {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
               "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on",
               "items":["macarchy.volume","macarchy.volume.icon","macarchy.volume.bracket","macarchy.volume.padding","macarchy.volume.slider","macarchy.theme.ready"\(rowState == "absent" ? "" : ",\"\(rowName)\"")]}
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
        case ["--query", "macarchy.volume"]:
          return ProcessResult(
            terminationStatus: 0,
            output: Self.itemJSON(
              name: "macarchy.volume",
              drawing: "on",
              position: "right",
              label: label,
              labelDrawing: "on",
              script: fixture.volumeScript,
              updateMask: updateMask
            )
          )
        case ["--query", "macarchy.volume.icon"]:
          return .init(
            terminationStatus: 0,
            output: Self.itemJSON(
              name: "macarchy.volume.icon", drawing: "on", position: "right", label: "􀊧",
              labelDrawing: "on", script: fixture.volumeScript, updateMask: 3))
        case ["--query", "macarchy.volume.padding"]:
          let output = Self.itemJSON(
            name: "macarchy.volume.padding", drawing: "on", position: "right"
          )
          .replacingOccurrences(
            of: "\"associated_space_mask\":0", with: "\"associated_space_mask\":0,\"width\":8")
          return .init(terminationStatus: 0, output: output)
        case ["--query", "macarchy.volume.bracket"]:
          let object: [String: Any] = [
            "name": "macarchy.volume.bracket", "type": "bracket",
            "geometry": ["drawing": "on", "position": "right"],
            "label": ["drawing": "off", "value": ""],
            "scripting": ["script": "", "click_script": "", "update_freq": 0],
            "bracket": ["macarchy.volume", "macarchy.volume.icon"],
            "popup": [
              "drawing": "off",
              "items": ["macarchy.volume.slider"]
                + (["absent", "wrong_parent"].contains(rowState) ? [] : [rowName]),
            ],
          ]
          return .init(
            terminationStatus: 0,
            output: String(
              decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        case ["--query", rowName]:
          let object: [String: Any] = [
            "name": rowName, "type": "item",
            "geometry": ["drawing": "on", "position": "popup"],
            "label": ["drawing": "on", "value": "Speaker"],
            "scripting": [
              "script": "", "update_freq": 0,
              "click_script": rowState != "unmanaged"
                ? SketchyBarAudioPicker.clickScript(name: rowName, pluginPath: fixture.volumeScript)
                : "unmanaged",
            ],
          ]
          return ProcessResult(
            terminationStatus: 0,
            output: String(
              decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        case ["--query", "macarchy.volume.slider"]:
          let object: [String: Any] = [
            "name": "macarchy.volume.slider", "type": "slider",
            "geometry": ["drawing": "on", "position": "popup", "associated_space_mask": 0],
            "label": ["drawing": "off", "value": ""],
            "scripting": [
              "script": "(null)",
              "click_script": SketchyBarConfigurationComposer.pluginClickScript(
                sender: "macarchy.slider", pluginPath: fixture.volumeScript),
              "update_freq": 0,
            ],
            "slider": ["percentage": sliderLevel],
          ]
          return ProcessResult(
            terminationStatus: 0,
            output: String(
              decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        case ["--query", "events"]:
          return ProcessResult(
            terminationStatus: 0,
            output:
              #"{"volume_change":{"bit":4096},"system_woke":{"bit":8},"mouse.clicked":{"bit":1},"mouse.scrolled":{"bit":2},"mouse.exited.global":{"bit":4}}"#
          )
        default:
          Issue.record("unexpected request: \(request)")
          return ProcessResult(terminationStatus: 1, output: "unexpected")
        }
      }

      let inspection = verifier.inspect(composition)

      #expect(inspection.status == expected)
      if expected == .converged {
        #expect(inspection.volumeLevelPresent == true)
        #expect(inspection.isValidEvidence)
        #expect(!inspection.items.contains(rowName))
        #expect(verifier.settleRestored(inspection))
      }
    }
  }

  @Test(arguments: [
    "valid", "unavailable", "rate", "ssid", "position", "script", "frequency", "subscription",
    "group",
  ])
  func verifiesWiFiInventoryRatesPrivacyStateAndInteractions(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = []\ncenter = []\nright = [\"wifi\"]\n")
    let verifier = fixture.verifier { request in
      let output: String
      let name = request.arguments.last ?? ""
      if name == "bar" {
        let items =
          (SketchyBarCoreRuntimeInspection.wifiItems + [
            "macarchy.theme.ready", "macarchy.wifi.bracket",
          ])
          .map { "\"\($0)\"" }.joined(separator: ",")
        output = """
          {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":[\(items)]}
          """
      } else if name == "events" {
        output =
          #"{"mouse.clicked":{"bit":1},"mouse.exited.global":{"bit":2},"system_woke":{"bit":4}}"#
      } else if name == "macarchy.theme.ready" {
        output = Self.itemJSON(name: name, drawing: "off", position: "right")
      } else if name == "macarchy.wifi.bracket" {
        let object: [String: Any] = [
          "name": name, "type": "bracket",
          "geometry": ["drawing": "on", "position": "right", "associated_space_mask": 0],
          "label": ["drawing": "off", "value": ""],
          "scripting": ["script": "", "click_script": "", "update_freq": 0],
          "bracket": [
            condition == "group" ? "foreign" : "macarchy.wifi", "macarchy.wifi.up",
            "macarchy.wifi.down",
          ],
          "popup": [
            "drawing": "off",
            "items": [
              "macarchy.wifi.hostname", "macarchy.wifi.ip", "macarchy.wifi.mask",
              "macarchy.wifi.router", "macarchy.wifi.ssid",
            ],
          ],
        ]
        output = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      } else if SketchyBarCoreRuntimeInspection.wifiItems.contains(name) {
        let main = name == "macarchy.wifi"
        let rate = name.hasSuffix(".up") || name.hasSuffix(".down")
        let ssid = name.hasSuffix(".ssid")
        let label =
          rate
          ? (condition == "rate" ? "ERR" : condition == "unavailable" ? "Unavailable" : "001KBps")
          : ssid
            ? (condition == "ssid" ? "Network query failed" : "Privacy restricted") : "Unavailable"
        let script = URL(filePath: fixture.volumeScript).deletingLastPathComponent().appending(
          path: "wifi.sh"
        ).path
        output = Self.itemJSON(
          name: name, drawing: "on",
          position: condition == "position" ? "left" : main || rate ? "right" : "popup",
          label: label, labelDrawing: main ? "off" : "on",
          script: condition == "script" ? "/tmp/stale.sh" : script,
          updateFrequency: condition == "frequency" ? 30 : main ? 2 : 0,
          updateMask: condition == "subscription" ? 0 : main ? 7 : 1)
      } else {
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
      return ProcessResult(terminationStatus: 0, output: output)
    }
    let inspection = verifier.inspect(composition)
    let success = ["valid", "unavailable"].contains(condition)
    #expect(inspection.status == (success ? .converged : .drifted))
    if success {
      #expect(inspection.wifiStatePresent == true)
      #expect(inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
      #expect(
        try JSONDecoder().decode(
          SketchyBarCoreRuntimeInspection.self,
          from: JSONEncoder().encode(inspection)) == inspection)
    }
  }

  @Test(arguments: ["valid", "error", "unpadded", "position", "script", "frequency", "click"])
  func verifiesMetricScriptsLabelsAndInteractions(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = []\ncenter = []\nright = [\"cpu\", \"memory\"]\n")
    let verifier = fixture.verifier { request in
      let output: String
      switch request.arguments {
      case ["--query", "bar"]:
        output =
          #"{"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":["macarchy.cpu","macarchy.memory","macarchy.memory.padding","macarchy.theme.ready"]}"#
      case ["--query", "macarchy.theme.ready"]:
        output = Self.itemJSON(name: "macarchy.theme.ready", drawing: "off", position: "right")
      case ["--query", "macarchy.memory.padding"]:
        output = Self.itemJSON(
          name: "macarchy.memory.padding", drawing: "on", position: "right", width: 8)
      case ["--query", "macarchy.cpu"], ["--query", "macarchy.memory"]:
        let cpu = request.arguments[1] == "macarchy.cpu"
        let module = cpu ? "cpu" : "memory"
        let label =
          condition == "error"
          ? "ERR" : "\(cpu ? "cpu" : "mem") \(condition == "unpadded" ? "9" : "09")%"
        let script = URL(filePath: fixture.volumeScript).deletingLastPathComponent().appending(
          path: "\(module).sh"
        ).path
        output = Self.itemJSON(
          name: "macarchy.\(module)", drawing: "on",
          position: condition == "position" ? "left" : "right", label: label, labelDrawing: "on",
          script: condition == "script" ? "/tmp/stale.sh" : script,
          clickScript: condition == "click" ? "" : "/usr/bin/open -a \\\"Activity Monitor\\\"",
          updateFrequency: condition == "frequency" ? 0 : cpu ? 2 : 5)
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
      return ProcessResult(terminationStatus: 0, output: output)
    }
    let inspection = verifier.inspect(composition)
    #expect(inspection.status == (condition == "valid" ? .converged : .drifted))
    if condition == "valid" {
      #expect(inspection.metricModules == ["cpu", "memory"])
      #expect(inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
      #expect(
        try JSONDecoder().decode(
          SketchyBarCoreRuntimeInspection.self,
          from: JSONEncoder().encode(inspection)) == inspection)
    }
  }

  @Test
  func planningRequiresTheNewCanonicalBatteryPaletteWithoutInvalidatingOldGenerations() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let inspector = SketchyBarPalettePlanInspector()
    #expect(inspector.inspect(stateRoot: fixture.state, enabled: true).status == .current)
    let manifest = try ReconciliationStatusStore(root: fixture.state).activeManifest()
    let url = fixture.state.appending(path: "generations/\(manifest.generationID)/manifest.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var versions = try #require(object["renderer_versions"] as? [String: Int])
    versions["sketchybar"] = 2
    object["renderer_versions"] = versions
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    #expect(inspector.inspect(stateRoot: fixture.state, enabled: true).status == .refreshRequired)
    #expect(inspector.inspect(stateRoot: fixture.state, enabled: false).status == .disabled)
    #expect(
      try ReconciliationStatusStore(root: fixture.state).activeManifest().generationID
        == manifest.generationID)
  }

  @Test(arguments: [
    "percentage", "desktop", "error", "unpadded", "missing_event", "wrong_position", "wrong_script",
    "bad_estimate",
  ])
  func verifiesBatteryStatePopupAndSubscriptions(condition: String) throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nleft = []\ncenter = []\nright = [\"battery\"]\n")
    let script = URL(filePath: fixture.volumeScript).deletingLastPathComponent().appending(
      path: "battery.sh"
    ).path
    let verifier = fixture.verifier { request in
      let output: String
      switch request.arguments {
      case ["--query", "bar"]:
        output =
          #"{"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,"margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":["macarchy.battery","macarchy.battery.remaining","macarchy.battery.padding","macarchy.theme.ready"]}"#
      case ["--query", "macarchy.theme.ready"]:
        output = Self.itemJSON(name: "macarchy.theme.ready", drawing: "off", position: "right")
      case ["--query", "macarchy.battery"]:
        let label =
          condition == "desktop"
          ? "No battery" : condition == "error" ? "ERR" : condition == "unpadded" ? "9%" : "09%"
        output = Self.itemJSON(
          name: "macarchy.battery", drawing: "on",
          position: condition == "wrong_position" ? "left" : "right", label: label,
          labelDrawing: "on",
          script: condition == "wrong_script" ? "/tmp/stale.sh" : script, updateFrequency: 180,
          updateMask: condition == "missing_event" ? 7 : 15)
      case ["--query", "macarchy.battery.padding"]:
        output = Self.itemJSON(
          name: "macarchy.battery.padding", drawing: "on", position: "right", width: 8)
      case ["--query", "macarchy.battery.remaining"]:
        output = Self.itemJSON(
          name: "macarchy.battery.remaining", drawing: "on", position: "popup",
          label: condition == "desktop"
            ? "No battery" : condition == "bad_estimate" ? "ERR" : "2:34h", labelDrawing: "on")
      case ["--query", "events"]:
        output =
          #"{"power_source_change":{"bit":1},"system_woke":{"bit":2},"mouse.clicked":{"bit":4},"mouse.exited.global":{"bit":8}}"#
      default:
        Issue.record("unexpected request: \(request)")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }
      return ProcessResult(terminationStatus: 0, output: output)
    }
    let inspection = verifier.inspect(composition)
    let succeeds = ["percentage", "desktop"].contains(condition)
    #expect(inspection.status == (succeeds ? .converged : .drifted))
    if succeeds {
      #expect(inspection.batteryStatePresent == true)
      #expect(inspection.isValidEvidence)
      #expect(verifier.settleRestored(inspection))
      let decoded = try JSONDecoder().decode(
        SketchyBarCoreRuntimeInspection.self, from: JSONEncoder().encode(inspection))
      #expect(decoded == inspection)
    }
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
              {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
               "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on",
               "items":["macarchy.clock","macarchy.clock.preview","macarchy.theme.ready","macarchy.space.1"\(extra)]}
              """
          )
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      }

      let inspection = verifier.inspect(fixture.dynamicComposition)

      #expect(inspection.status == .drifted, Comment(rawValue: change.rawValue))
    }
  }

  @Test
  func hookAllowsForeignItemsButPreservesTheManagedNamespace() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "# trusted\n".write(
      to: fixture.root.appending(path: "hook.sh"),
      atomically: true,
      encoding: .utf8
    )
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nhook = \"hook.sh\"\n"
    )

    for (extra, expected) in [
      ("personal.demo", SketchyBarCoreRuntimeStatus.partial),
      ("macarchy.unmanaged", .drifted),
    ] {
      let verifier = fixture.verifier { request in
        if request.executableURL.path == SketchyBarCoreRuntimeVerifier.controlURL.path,
          request.arguments == ["--query", "bar"]
        {
          return ProcessResult(
            terminationStatus: 0,
            output: """
              {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
               "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on",
               "items":["macarchy.clock","macarchy.clock.preview","macarchy.theme.ready","macarchy.space.1","\(extra)"]}
              """
          )
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      }

      let inspection = verifier.inspect(composition)

      #expect(inspection.status == expected, Comment(rawValue: extra))
      if expected == .partial { #expect(inspection.isValidEvidence) }
    }
  }

  @Test
  func hookSettleDoesNotFailBeforeTheRunnerExecutionBound() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try "# trusted\n".write(
      to: fixture.root.appending(path: "hook.sh"),
      atomically: true,
      encoding: .utf8
    )
    let composition = try fixture.composition(
      "schema_version = 1\n[sketchybar]\nhook = \"hook.sh\"\n"
    )
    let waits = Mutex(0)
    let verifier = SketchyBarCoreRuntimeVerifier(
      stateRoot: fixture.state,
      processRunner: ProcessRunner { request in
        if request.executableURL == SketchyBarCoreRuntimeVerifier.yabaiURL {
          return ProcessResult(terminationStatus: 1, output: "temporary yabai failure")
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      },
      waitForSettle: { waits.withLock { $0 += 1 } },
      waitForPresentation: {}, hasExternalDisplay: { false }
    )

    let inspection = verifier.settle(composition)

    #expect(inspection.status == .failed)
    #expect(waits.withLock { $0 } == 100)
  }

  @Test
  func coreSettleAllowsTheObservedTwoSecondReloadWindow() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let barQueries = Mutex(0)
    let waits = Mutex(0)
    let verifier = SketchyBarCoreRuntimeVerifier(
      stateRoot: fixture.state,
      processRunner: ProcessRunner { request in
        if request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL,
          request.arguments == ["--query", "bar"]
        {
          let query = barQueries.withLock { count in
            count += 1
            return count
          }
          if query <= 20 {
            return ProcessResult(
              terminationStatus: 0,
              output: """
                {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
                 "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":[]}
                """
            )
          }
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      },
      waitForSettle: { waits.withLock { $0 += 1 } },
      waitForPresentation: {}, hasExternalDisplay: { false }
    )

    let inspection = verifier.settle(fixture.dynamicComposition)

    #expect(inspection.status == .converged)
    #expect(waits.withLock { $0 } == 20)
  }

  @Test
  func rollbackSettleRestoresThePreviousObservableRuntime() throws {
    let fixture = try SketchyBarRuntimeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let current = fixture.verifier {
      Self.dynamicResult($0, fixture: fixture, indices: [1])
    }.inspect(fixture.dynamicComposition)
    let expected = SketchyBarCoreRuntimeInspection(
      status: current.status,
      message: "evidence from the previous theme",
      themeGenerationID: "g-00000000-0000-0000-0000-000000000001",
      barColor: "0xff000000",
      items: current.items,
      spaceIndices: current.spaceIndices,
      clockLabelPresent: current.clockLabelPresent,
      volumeLevelPresent: current.volumeLevelPresent ?? false
    )
    let barQueries = Mutex(0)
    let waits = Mutex(0)
    let verifier = SketchyBarCoreRuntimeVerifier(
      stateRoot: fixture.state,
      processRunner: ProcessRunner { request in
        if request.executableURL == SketchyBarCoreRuntimeVerifier.controlURL,
          request.arguments == ["--query", "bar"]
        {
          let query = barQueries.withLock { count in
            count += 1
            return count
          }
          if query <= 20 {
            return ProcessResult(
              terminationStatus: 0,
              output: """
                {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
                 "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":[]}
                """
            )
          }
        }
        return Self.dynamicResult(request, fixture: fixture, indices: [1])
      },
      waitForSettle: { waits.withLock { $0 += 1 } },
      waitForPresentation: {}, hasExternalDisplay: { false }
    )

    #expect(expected.agreesWithProviderRuntime(current))
    #expect(verifier.settleRestored(expected))
    #expect(waits.withLock { $0 } == 20)
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
        ["macarchy.clock", "macarchy.clock.preview", "macarchy.theme.ready"]
        + indices.map { "macarchy.space.\($0)" }
      let items = names.map { "\"\($0)\"" }.joined(separator: ",")
      return ProcessResult(
        terminationStatus: 0,
        output: """
          {"position":"top","drawing":"on","color":"0xf01e1e2e","height":30,
           "margin":0,"corner_radius":0,"hidden":"off","y_offset":0,"topmost":"on","items":[\(items)]}
          """
      )
    case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "macarchy.clock.preview"]):
      return ProcessResult(
        terminationStatus: 0,
        output: itemJSON(
          name: "macarchy.clock.preview", drawing: "off", position: "right", label: "0"))
    case (SketchyBarCoreRuntimeVerifier.controlURL.path, ["--query", "events"]):
      return ProcessResult(
        terminationStatus: 0,
        output: #"{"mouse.clicked":{"bit":1},"system_woke":{"bit":8},"display_change":{"bit":16}}"#)
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
    width: Int? = nil,
    label: String = "",
    labelDrawing: String = "off",
    script: String = "(null)",
    clickScript: String = "(null)",
    updateFrequency: Int = 0,
    updateMask: UInt64? = nil,
    updates: String = "when_shown"
  ) -> String {
    let mask =
      (updateMask ?? (name == "macarchy.clock" ? 25 : nil)).map { ",\"update_mask\":\($0)" } ?? ""
    let widthField = width.map { ",\"width\":\($0)" } ?? ""
    return """
      {"name":"\(name)","type":"\(type)",
       "geometry":{"drawing":"\(drawing)","position":"\(position)","associated_space_mask":\(associatedSpaceMask)\(widthField)},
       "label":{"value":"\(label)","drawing":"\(labelDrawing)"},
       "scripting":{"script":"\(script)","click_script":"\(clickScript)","update_freq":\(updateFrequency),"updates":"\(updates)"\(mask)}}
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
    // Keep the core verifier fixtures isolated from the independently tested
    // personal default modules. Individual module cases select their full layout.
    let defaults = root.appending(path: "defaults.toml")
    let coreDefaults = try String(
      contentsOf: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml"),
      encoding: .utf8
    )
    .replacingOccurrences(
      of: #"(?m)^left = .*$"#, with: "left = [\"spaces\"]", options: .regularExpression
    )
    .replacingOccurrences(
      of: #"(?m)^center = .*$"#, with: "center = []", options: .regularExpression
    )
    .replacingOccurrences(
      of: #"(?m)^right = .*$"#, with: "right = [\"clock\"]", options: .regularExpression)
    try coreDefaults.write(to: defaults, atomically: true, encoding: .utf8)
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

  var volumeScript: String {
    state.appending(path: "desktop/sketchybar/current/plugins/volume.sh").path
  }

  func composition(_ profile: String) throws -> SketchyBarComposition {
    try SketchyBarConfigurationComposer().compose(
      defaultsURL: root.appending(path: "defaults.toml"),
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
      waitForPresentation: {}, hasExternalDisplay: { false }
    )
  }
}
