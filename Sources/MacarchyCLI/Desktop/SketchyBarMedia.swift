import ArgumentParser
import CryptoKit
import Foundation
import ImageIO
import ThemeCore
import UniformTypeIdentifiers

struct NowPlayingMedia: Equatable {
  let title: String
  let artist: String
  let artwork: Data?
  let playing: Bool

  static func parse(_ output: String) throws -> Self {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == "(null)" { return .init(title: "", artist: "", artwork: nil, playing: false) }
    guard text.utf8.count <= 16_777_216,
      let values = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        as? [String: Any]
    else { throw MediaError.invalidMetadata }
    func string(_ key: String) throws -> String {
      guard let value = values["kMRMediaRemoteNowPlayingInfo" + key] else { return "" }
      guard let value = value as? String, value.utf8.count <= 16_384 else {
        throw MediaError.invalidMetadata
      }
      return value
    }
    let bundle = try string("ClientBundleIdentifier")
    let title = try string("Title")
    let artist = try string("Artist")
    let rawRate = values["kMRMediaRemoteNowPlayingInfoPlaybackRate"]
    let rate: Double
    if rawRate == nil {
      rate = 0
    } else if let number = rawRate as? NSNumber {
      rate = number.doubleValue
    } else if let string = rawRate as? String, let number = Double(string) {
      rate = number
    } else {
      throw MediaError.invalidMetadata
    }
    guard rate.isFinite, rate >= 0 else { throw MediaError.invalidMetadata }
    let rawArtwork = values["kMRMediaRemoteNowPlayingInfoArtworkData"]
    guard rawArtwork == nil || rawArtwork is Data else { throw MediaError.invalidMetadata }
    let artwork = rawArtwork as? Data
    return Self(
      title: title, artist: artist, artwork: artwork?.isEmpty == false ? artwork : nil,
      playing: ["com.spotify.client", "com.apple.Music"].contains(bundle) && rate > 0
        && !title.isEmpty)
  }

  var identity: String {
    var data = Data(title.utf8)
    data.append(0)
    data.append(contentsOf: artist.utf8)
    data.append(0)
    if let artwork { data.append(artwork) }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct SketchyBarMedia {
  static let items = [
    "macarchy.media", "macarchy.media.artist", "macarchy.media.title",
    "macarchy.media.previous", "macarchy.media.playpause", "macarchy.media.next",
    "macarchy.media.preview",
  ]
  let processRunner: ProcessRunner
  let uptime: () -> TimeInterval
  let sleep: (TimeInterval) -> Void
  let withArtwork: (Data, (String) throws -> Void) throws -> Void

  func execute(name: String, sender: String) throws {
    guard Self.items.contains(name) else { throw MediaError.invalidInvocation }
    if sender == "mouse.exited.global" {
      try bar(["--set", "macarchy.media", "popup.drawing=off"])
      return
    }
    if sender == "mouse.clicked" {
      try bar(["--set", "macarchy.media", "popup.drawing=toggle"])
      return
    }
    if sender == "mouse.entered" || sender == "mouse.exited" {
      let entering = sender == "mouse.entered"
      try bar(["--set", "macarchy.media.preview", "label=\(entering ? "hover" : "0")"])
      try detail(entering)
      return
    }
    let controls = [
      "macarchy.media.previous": "previous", "macarchy.media.playpause": "togglePlayPause",
      "macarchy.media.next": "next",
    ]
    if let command = controls[sender] {
      guard name == sender else { throw MediaError.invalidInvocation }
      _ = try run("/opt/homebrew/bin/nowplaying-cli", [command])
    } else if name != "macarchy.media" {
      return
    }
    let media = try NowPlayingMedia.parse(run("/opt/homebrew/bin/nowplaying-cli", ["get-raw"]))
    guard media.playing else {
      try bar([
        "--set", "macarchy.media", "drawing=off", "label=inactive", "label.drawing=off",
        "popup.drawing=off",
        "background.image.drawing=off",
        "--set", "macarchy.media.artist", "drawing=off", "label=",
        "--set", "macarchy.media.title", "drawing=off", "label=",
        "--set", "macarchy.media.preview", "label=0",
      ])
      return
    }
    let changed = try label("macarchy.media") != media.identity
    let preview = try label("macarchy.media.preview")
    guard preview == "hover" || UInt64(preview).map({ String($0) == preview }) == true else {
      throw MediaError.invalidPreview
    }
    let deadline = UInt64((uptime() + 5) * 1000)
    let expanded =
      changed || preview == "hover" || Double(preview).map { $0 > uptime() * 1000 } == true
    var args = [
      "--set", "macarchy.media", "drawing=on", "label.drawing=off", "label=\(media.identity)",
      "icon.drawing=\(media.artwork == nil ? "on" : "off")", "icon=􀑪",
      "--set", "macarchy.media.artist", "drawing=on", "label=\(media.artist)",
      "--set", "macarchy.media.title", "drawing=on", "label=\(media.title)",
    ]
    if changed, preview != "hover" {
      args += ["--set", "macarchy.media.preview", "label=\(deadline)"]
    }
    if changed, let artwork = media.artwork {
      try withArtwork(artwork) { path in
        try bar(args + ["--set", "macarchy.media", "background.image=\(path)"])
      }
    } else {
      if media.artwork == nil {
        args += ["--set", "macarchy.media", "background.image.drawing=off"]
      }
      try bar(args)
    }
    try detail(expanded)
    if changed, preview != "hover" {
      sleep(5)
      if try label("macarchy.media.preview") == String(deadline),
        uptime() * 1000 >= Double(deadline)
      {
        try detail(false)
      }
    }
  }

  private func label(_ name: String) throws -> String {
    struct Item: Decodable {
      struct Label: Decodable { let value: String }
      let label: Label
    }
    return try JSONDecoder().decode(Item.self, from: Data(bar(["--query", name]).utf8)).label.value
  }

  private func detail(_ expanded: Bool) throws {
    try bar([
      "--animate", "tanh", "30", "--set", "macarchy.media.artist",
      "label.width=\(expanded ? "dynamic" : "0")",
      "--set", "macarchy.media.title", "label.width=\(expanded ? "dynamic" : "0")",
    ])
  }

  @discardableResult private func bar(_ arguments: [String]) throws -> String {
    try run("/opt/homebrew/bin/sketchybar", arguments)
  }

  private func run(_ path: String, _ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(executableURL: URL(filePath: path), arguments: arguments, timeout: 2))
    guard result.terminationStatus == 0 else { throw MediaError.providerFailed }
    return result.output
  }

  static func temporaryArtwork(_ data: Data, use: (String) throws -> Void) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 32,
        ] as CFDictionary)
    else { throw MediaError.invalidArtwork }
    let png = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        png, UTType.png.identifier as CFString, 1, nil)
    else { throw MediaError.invalidArtwork }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MediaError.invalidArtwork }
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-artwork-\(UUID())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let path = root.appending(path: "cover.png")
      try (png as Data).write(to: path, options: .withoutOverwriting)
      try use(path.path)
    } catch {
      do { try FileManager.default.removeItem(at: root) } catch let cleanup {
        throw MediaError.artworkCleanup(
          "Artwork operation failed (\(error)); cleanup failed (\(cleanup))")
      }
      throw error
    }
    try FileManager.default.removeItem(at: root)
  }
}

enum MediaError: Error {
  case invalidMetadata, invalidInvocation, invalidPreview, providerFailed, invalidArtwork
  case artworkCleanup(String)
}

extension Desktop {
  struct Media: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_media", shouldDisplay: false)
    @Option var name: String
    @Option var sender = "forced"
    mutating func run() throws {
      try SketchyBarMedia(
        processRunner: .live, uptime: { ProcessInfo.processInfo.systemUptime },
        sleep: Thread.sleep(forTimeInterval:), withArtwork: SketchyBarMedia.temporaryArtwork
      )
      .execute(name: name, sender: sender)
    }
  }
}
