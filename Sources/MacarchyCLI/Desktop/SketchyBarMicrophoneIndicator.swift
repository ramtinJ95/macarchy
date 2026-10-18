import ArgumentParser
import Foundation
import ThemeCore

struct SketchyBarMicrophoneIndicator {
  static let item = "macarchy.microphone"
  static let detailItem = "macarchy.microphone.detail"

  let processRunner: ProcessRunner
  let status: () throws -> MicrophoneStatus
  let unmute: () throws -> Void

  func execute(sender: String, accent: String) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", Self.item, "popup.drawing=off"])
      try unmute()
    case "mouse.entered":
      try bar(["--set", Self.item, "popup.drawing=on"])
      return
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", Self.item, "popup.drawing=off"])
      return
    default:
      break
    }
    guard case .input(let device, let state) = try status(), let detail = Self.detail(device, state)
    else {
      try bar(["--set", Self.item, "drawing=off", "popup.drawing=off"])
      return
    }
    try bar([
      "--set", Self.item, "drawing=on", "icon=\(SketchyBarConfigurationComposer.microphoneIcon)",
      "icon.color=\(accent)", "--set", Self.detailItem, "label=\(detail)",
    ])
  }

  /// Hover text while the default input is muted; nil while it is live.
  private static func detail(_ device: AudioDevice, _ state: MicrophoneMuteState) -> String? {
    switch state {
    case .hardwareMuted: "\(device.subject) muted (hardware mute). Click to unmute."
    case .silencedByLevel:
      "\(device.subject) silenced by input level, not a hardware mute. Click to restore."
    case .live, .unsupported: nil
    }
  }

  private func bar(_ arguments: [String]) throws {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else {
      throw MicrophoneError("SketchyBar microphone indicator failed: \(result.output)")
    }
  }
}

extension Desktop {
  struct MicrophoneIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_microphone-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String

    mutating func run() throws {
      let engine = Microphone.live(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL)
      try SketchyBarMicrophoneIndicator(
        processRunner: .live, status: engine.status, unmute: { _ = try engine.apply(.unmute) }
      )
      .execute(sender: sender, accent: accent)
    }
  }
}
