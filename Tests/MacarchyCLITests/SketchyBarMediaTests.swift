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

  @Test func rendersArtworkAndDetailsThenCollapsesWithoutPersistingArtwork() throws {
    let state = State()
    var now = 100.0
    var artworkCalls = 0
    let media = SketchyBarMedia(
      processRunner: runner(state), uptime: { now }, sleep: { now += $0 },
      withArtwork: {
        artworkCalls += 1
        #expect($0 == Data([0, 1]))
        try $1("/private/tmp/cover.png")
      })
    try media.execute(name: "macarchy.media", sender: "routine")
    let calls = state.value.withLock { $0.calls }
    #expect(artworkCalls == 1)
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
      processRunner: runner(state), uptime: { 100 },
      sleep: { _ in Issue.record("hover should not sleep") },
      withArtwork: { _, use in try use("/tmp/cover") })
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

  @Test func inactiveMediaHidesAllPresentationAndProviderFailuresPropagate() throws {
    let state = State()
    let media = SketchyBarMedia(
      processRunner: runner(state, output: "(null)"), uptime: { 0 }, sleep: { _ in },
      withArtwork: { _, _ in Issue.record("unexpected artwork") })
    try media.execute(name: "macarchy.media", sender: "forced")
    #expect(state.value.withLock { $0.calls.last?.contains("label=inactive") } == true)
    let failed = SketchyBarMedia(
      processRunner: ProcessRunner { _ in .init(terminationStatus: 1, output: "failure") },
      uptime: { 0 }, sleep: { _ in }, withArtwork: { _, _ in })
    #expect(throws: MediaError.self) {
      try failed.execute(name: "macarchy.media", sender: "routine")
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
      var provider: [[String]] = []
      var labels = ["macarchy.media": "inactive", "macarchy.media.preview": "0"]
    }
    let value = Mutex(Value())
  }
  private func runner(_ state: State, output: String? = nil) -> ProcessRunner {
    let metadata = output ?? metadata()
    return ProcessRunner { request in
      if request.executableURL.path == "/opt/homebrew/bin/nowplaying-cli" {
        state.value.withLock { $0.provider.append(request.arguments) }
        return .init(terminationStatus: 0, output: request.arguments == ["get-raw"] ? metadata : "")
      }
      return state.value.withLock {
        $0.calls.append(request.arguments)
        if request.arguments.first == "--query" {
          return .init(
            terminationStatus: 0,
            output: "{\"label\":{\"value\":\"\($0.labels[request.arguments[1]] ?? "")\"}}")
        }
        var target = ""
        for (index, arg) in request.arguments.enumerated() {
          if index > 0 && request.arguments[index - 1] == "--set" { target = arg }
          if arg.hasPrefix("label=") { $0.labels[target] = String(arg.dropFirst(6)) }
        }
        return .init(terminationStatus: 0, output: "")
      }
    }
  }
}
