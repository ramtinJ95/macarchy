import Foundation
import ImageIO
import Synchronization
import Testing
import ThemeCore

@testable import MacarchyCLI

struct SketchyBarMediaTests {
  @Test(arguments: ["com.spotify.client", "com.apple.Music", "other"])
  func parsesJSONProviderOutputAndBase64ArtworkWithoutShellSelectors(bundle: String) throws {
    let media = try NowPlayingMedia.parse(metadata(bundle: bundle))
    #expect(media.title == "Title $(bad) 'quoted'")
    #expect(media.artist == "Artist")
    #expect(media.playing == (bundle != "other"))
    #expect(media.artwork == Data([0, 1]))
    #expect(media.identity.count == 64)
    #expect(try NowPlayingMedia.parse("(null)").playing == false)
    #expect(try NowPlayingMedia.parse("{}").playing == false)
  }

  @Test(arguments: [
    "bad", "[]", "{ kMRMediaRemoteNowPlayingInfoPlaybackRate = 1; }",
    #"{"kMRMediaRemoteNowPlayingInfoPlaybackRate":"nope"}"#,
    #"{"kMRMediaRemoteNowPlayingInfoPlaybackRate":true}"#,
    #"{"kMRMediaRemoteNowPlayingInfoArtworkData":"not base64!"}"#,
    #"{"kMRMediaRemoteNowPlayingInfoArtworkData":42}"#,
  ])
  func malformedProviderResponsesFail(output: String) {
    #expect(throws: (any Error).self) { try NowPlayingMedia.parse(output) }
  }

  @Test(arguments: ["SF Pro", "MesloLGS Nerd Font Mono"])
  func rendersArtworkAndDetailsThenCollapsesWithoutPersistingArtwork(family: String) throws {
    let state = State()
    var now = 100.0
    var artworkCalls = 0
    let media = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: runner(state, font: "\(family):Bold:13.00"), uptime: { now },
      sleep: { now += $0 },
      withArtwork: {
        artworkCalls += 1
        #expect($0 == Data([0, 1]))
        try $1("/private/tmp/cover.png")
      }, launch: { _ in Issue.record("unexpected launch") })
    try media.execute(name: "macarchy.media", sender: "routine")
    let calls = state.value.withLock { $0.calls }
    #expect(artworkCalls == 1)
    #expect(
      calls.contains { $0.contains("icon=\(family == "SF Pro" ? "\u{10046a}" : "\u{f001}")") })
    #expect(
      calls.contains {
        $0.contains("label=Title $(bad) 'quoted'")
          && $0.contains("background.image=/private/tmp/cover.png")
      })
    #expect(calls.contains { $0.contains("label.width=dynamic") })
    #expect(calls.last?.contains("label.width=0") == true)
    try media.execute(name: "macarchy.media", sender: "routine")
    #expect(artworkCalls == 1)
  }

  @Test func hoverOwnsExpansionAndControlsUseClosedExternalArguments() throws {
    let state = State()
    let media = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: runner(state), uptime: { 100 },
      sleep: { _ in Issue.record("hover should not sleep") },
      withArtwork: { _, use in try use("/tmp/cover") },
      launch: { _ in Issue.record("unexpected launch") })
    try media.execute(name: "macarchy.media", sender: "mouse.entered")
    try media.execute(name: "macarchy.media", sender: "routine")
    for part in ["previous", "playpause", "next"] {
      try media.execute(name: "macarchy.media.\(part)", sender: "macarchy.media.\(part)")
    }
    #expect(
      state.value.withLock { $0.provider } == [
        ["get-raw"], ["previous"], ["get-raw"], ["togglePlayPause"], ["get-raw"], ["next"],
        ["get-raw"],
      ])
    try media.execute(name: "macarchy.media.title", sender: "mouse.exited.global")
    #expect(state.value.withLock { $0.calls.last?.contains("popup.drawing=off") } == true)
  }

  @Test(arguments: ["off", "on"])
  func clickTogglesControlsAndWatchesOnlyAnOpenedPopup(drawing: String) throws {
    let state = State()
    var launches: [[String]] = []
    let media = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: ProcessRunner { request in
        #expect(request.executableURL.path == "/opt/homebrew/bin/sketchybar")
        state.value.withLock { $0.calls.append(request.arguments) }
        return .init(
          terminationStatus: 0,
          output: #"{"popup": {"drawing": "\#(drawing)", "items": ["macarchy.media.next"]}}"#)
      },
      uptime: { 0 }, sleep: { _ in }, withArtwork: { _, _ in }, launch: { launches.append($0) })
    try media.execute(name: "macarchy.media", sender: "mouse.clicked")
    let opening = drawing == "off"
    #expect(
      state.value.withLock { $0.calls.last }
        == ["--set", "macarchy.media", "popup.drawing=\(opening ? "on" : "off")"])
    #expect(launches == (opening ? [BarPopup.media.watchArguments] : []))
  }

  @Test func inactiveMediaHidesAllPresentationAndProviderFailuresPropagate() throws {
    let state = State()
    let media = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: runner(state, output: "(null)"), uptime: { 0 }, sleep: { _ in },
      withArtwork: { _, _ in Issue.record("unexpected artwork") }, launch: { _ in })
    try media.execute(name: "macarchy.media", sender: "forced")
    #expect(state.value.withLock { $0.calls.last?.contains("label=inactive") } == true)
    let failed = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: ProcessRunner { _ in .init(terminationStatus: 1, output: "failure") },
      uptime: { 0 }, sleep: { _ in }, withArtwork: { _, _ in }, launch: { _ in })
    #expect(throws: MediaError.self) {
      try failed.execute(name: "macarchy.media", sender: "routine")
    }
  }

  @Test func metadataDeadlineAllowsNativeInactivePollingButTimeoutIsStillFailure() throws {
    let media = SketchyBarMedia(
      symbolFont: .init(supports: { _, _ in true }),
      processRunner: ProcessRunner { request in
        if request.executableURL.path == "/opt/homebrew/bin/nowplaying-cli" {
          #expect(request.arguments == ["get-raw"])
          #expect(request.timeout == 5)
          throw ProcessRunnerError.timedOut(request.executableURL, 5)
        }
        #expect(request.arguments.contains("icon.drawing=off"))
        #expect(request.arguments.contains("label=ERR"))
        return .init(terminationStatus: 0, output: "")
      },
      uptime: { 0 }, sleep: { _ in }, withArtwork: { _, _ in }, launch: { _ in })
    #expect(throws: ProcessRunnerError.self) {
      try media.execute(name: "macarchy.media", sender: "routine")
    }
  }

  @Test func artworkIsPrivateBoundedAndRemovedAfterSuccessOrFailure() throws {
    let data = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
      ))
    for fail in [false, true] {
      var path = ""
      do {
        try SketchyBarMedia.temporaryArtwork(data) { value in
          path = value
          let source = try #require(CGImageSourceCreateWithURL(URL(filePath: value) as CFURL, nil))
          let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
          #expect(image.width <= 32 && image.height <= 32)
          let permissions =
            try FileManager.default.attributesOfItem(
              atPath: URL(filePath: value).deletingLastPathComponent().path)[.posixPermissions]
            as? Int
          #expect(permissions == 0o700)
          if fail { throw MediaError.providerFailed }
        }
        #expect(!fail)
      } catch { #expect(fail) }
      #expect(!path.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: path))
    }
  }

  @Test(arguments: ["SF Pro", "MesloLGS Nerd Font Mono"])
  func fontFailurePresentationSurvivesRetainedScriptsAndRecovers(family: String) throws {
    let state = State()
    state.value.withLock {
      $0.properties["macarchy.media"] = [
        "icon": "\u{f001}", "icon.drawing": "on", "background.image.drawing": "on",
        "label.drawing": "off", "popup.drawing": "on",
      ]
    }
    let output =
      #"{"kMRMediaRemoteNowPlayingInfoClientBundleIdentifier":"com.spotify.client","kMRMediaRemoteNowPlayingInfoTitle":"Title","kMRMediaRemoteNowPlayingInfoPlaybackRate":1}"#
    let process = runner(state, font: "\(family):Bold:13.00", output: output)
    func helper(available: Bool) -> SketchyBarMedia {
      SketchyBarMedia(
        symbolFont: .init(supports: { _, _ in available }), processRunner: process,
        uptime: { 100 }, sleep: { _ in },
        withArtwork: { _, _ in Issue.record("unexpected artwork") }, launch: { _ in })
    }
    #expect(throws: SketchyBarSymbolFont.Failure.self) {
      try helper(available: false).execute(name: "macarchy.media", sender: "routine")
    }
    // Replay the error handler already deployed in pre-0.18.2 scripts. Its ERR
    // update must not undo the helper's clearing of stale private-use icons/artwork.
    let bar = SketchyBarControl(
      processRunner: process, timeout: 2,
      failure: { _, _ in MediaError.providerFailed })
    try bar([
      "--set", "macarchy.media", "drawing=on", "label.drawing=on", "label=ERR",
      "label.color=0xffff0000", "popup.drawing=off",
      "--set", "macarchy.media.artist", "drawing=off",
      "--set", "macarchy.media.title", "drawing=off",
    ])
    let failed = state.value.withLock { $0.properties }
    #expect(failed["macarchy.media"]?["icon"] == "\u{f001}")
    #expect(failed["macarchy.media"]?["icon.drawing"] == "off")
    #expect(failed["macarchy.media"]?["background.image.drawing"] == "off")
    #expect(failed["macarchy.media"]?["drawing"] == "on")
    #expect(failed["macarchy.media"]?["label.drawing"] == "on")
    #expect(failed["macarchy.media"]?["label"] == "ERR")
    #expect(failed["macarchy.media"]?["popup.drawing"] == "off")
    #expect(failed["macarchy.media.artist"]?["drawing"] == "off")
    #expect(failed["macarchy.media.title"]?["drawing"] == "off")
    try helper(available: true).execute(name: "macarchy.media", sender: "routine")
    let recovered = state.value.withLock { $0.properties["macarchy.media"]! }
    #expect(recovered["icon.drawing"] == "on")
    #expect(recovered["label.drawing"] == "off")
    #expect(recovered["icon"] == (family == "SF Pro" ? "\u{10046a}" : "\u{f001}"))
    #expect(recovered["label"] != "ERR")
  }

  private func metadata(bundle: String = "com.spotify.client") -> String {
    """
    { "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier": "\(bundle)",
      "kMRMediaRemoteNowPlayingInfoTitle": "Title $(bad) 'quoted'",
      "kMRMediaRemoteNowPlayingInfoArtist": "Artist",
      "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1,
      "kMRMediaRemoteNowPlayingInfoArtworkData": "AAE=" }
    """
  }
  private final class State: Sendable {
    struct Value {
      var calls: [[String]] = []
      var properties: [String: [String: String]] = [:]
      var provider: [[String]] = []
      var labels = ["macarchy.media": "inactive", "macarchy.media.preview": "0"]
    }
    let value = Mutex(Value())
  }
  private func runner(
    _ state: State, font: String = "MesloLGS Nerd Font Mono:Bold:13.00", output: String? = nil
  ) -> ProcessRunner {
    let metadata = output ?? metadata()
    return ProcessRunner { request in
      if request.executableURL.path == "/opt/homebrew/bin/nowplaying-cli" {
        #expect(request.timeout == (request.arguments == ["get-raw"] ? 5 : 2))
        state.value.withLock { $0.provider.append(request.arguments) }
        return .init(terminationStatus: 0, output: request.arguments == ["get-raw"] ? metadata : "")
      }
      #expect(request.timeout == 2)
      return state.value.withLock {
        $0.calls.append(request.arguments)
        if request.arguments.first == "--query" {
          return .init(
            terminationStatus: 0,
            output:
              "{\"name\":\"\(request.arguments[1])\",\"icon\":{\"font\":\"\(font)\"},\"label\":{\"value\":\"\($0.labels[request.arguments[1]] ?? "")\"}}"
          )
        }
        var target = ""
        for (index, arg) in request.arguments.enumerated() {
          if index > 0 && request.arguments[index - 1] == "--set" { target = arg }
          if arg.hasPrefix("label=") { $0.labels[target] = String(arg.dropFirst(6)) }
          let pair = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          if !target.isEmpty, pair.count == 2 {
            $0.properties[target, default: [:]][String(pair[0])] = String(pair[1])
          }
        }
        return .init(terminationStatus: 0, output: "")
      }
    }
  }
}
