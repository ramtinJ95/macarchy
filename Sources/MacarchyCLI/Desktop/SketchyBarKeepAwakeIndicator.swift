import ArgumentParser
import Foundation
import ThemeCore

struct SketchyBarKeepAwakeIndicator {
  static let item = "macarchy.keep-awake"
  static let detailItem = "macarchy.keep-awake.detail"

  let processRunner: ProcessRunner
  let status: () throws -> KeepAwakeStatus
  let turnOff: () throws -> Void

  func execute(sender: String, accent: String) throws {
    switch sender {
    case "mouse.clicked":
      try bar(["--set", Self.item, "popup.drawing=off"])
      try turnOff()
    case "mouse.entered":
      try bar(["--set", Self.item, "popup.drawing=on"])
      return
    case "mouse.exited", "mouse.exited.global":
      try bar(["--set", Self.item, "popup.drawing=off"])
      return
    default:
      break
    }
    switch try status() {
    case .off:
      try bar(["--set", Self.item, "drawing=off", "popup.drawing=off"])
    case .on(let session):
      try bar([
        "--set", Self.item, "drawing=on", "icon=\(SketchyBarConfigurationComposer.keepAwakeIcon)",
        "icon.color=\(accent)", "--set", Self.detailItem,
        "label=Keep-awake on \(session.until). Idle screensaver and idle lock won't start. "
          + "Click to turn off.",
      ])
    }
  }

  private func bar(_ arguments: [String]) throws {
    let result = try processRunner.run(
      .init(
        executableURL: SketchyBarCoreRuntimeVerifier.controlURL, arguments: arguments, timeout: 1))
    guard result.terminationStatus == 0 else {
      throw KeepAwakeError("SketchyBar keep-awake indicator failed: \(result.output)")
    }
  }
}

extension Desktop {
  struct KeepAwakeIndicator: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_keep-awake-indicator", shouldDisplay: false)
    @Option var sender = "forced"
    @Option var stateRoot: String
    @Option var accent: String

    mutating func run() throws {
      let engine = KeepAwake.live(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL)
      try SketchyBarKeepAwakeIndicator(
        processRunner: .live, status: engine.status, turnOff: { _ = try engine.apply(.off) }
      )
      .execute(sender: sender, accent: accent)
    }
  }
}
