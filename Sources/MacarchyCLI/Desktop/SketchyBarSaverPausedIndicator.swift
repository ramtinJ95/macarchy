import ArgumentParser
import Foundation
import ThemeCore

/// Shows a pause icon left of the clock only while idle activation is on and paused. The state
/// comes from idle activation's record and launch agent, never from process names.
struct SketchyBarSaverPausedIndicator {
  static let item = "macarchy.saver-paused"
  static let detailItem = "macarchy.saver-paused.detail"

  let processRunner: ProcessRunner
  let paused: () throws -> Bool
  let resume: () throws -> Void

  func execute(sender: String, accent: String) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", Self.item, "popup.drawing=off"])
      try resume()
    case "mouse.entered":
      try bar(["--set", Self.item, "popup.drawing=on"])
      return
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", Self.item, "popup.drawing=off"])
      return
    default:
      break
    }
    guard try paused() else {
      try bar(["--set", Self.item, "drawing=off", "popup.drawing=off"])
      return
    }
    try bar([
      "--set", Self.item, "drawing=on", "icon=\(SketchyBarConfigurationComposer.saverPausedIcon)",
      "icon.color=\(accent)", "--set", Self.detailItem,
      "label=Idle screensaver paused. Click to resume.",
    ])
  }

  private func bar(_ arguments: [String]) throws {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else {
      throw SaverError("SketchyBar screensaver pause indicator failed: \(result.output)")
    }
  }
}

extension Desktop {
  struct SaverPausedIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_saver-paused-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String

    mutating func run() throws {
      let idle = SaverIdle.live(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL)
      try SketchyBarSaverPausedIndicator(
        processRunner: .live, paused: { try idle.activation().isPaused },
        resume: { _ = try idle.apply(.resume) }
      )
      .execute(sender: sender, accent: accent)
    }
  }
}
