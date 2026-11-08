import Foundation
import ThemeCore

/// Sends one command to the running SketchyBar. Every bar helper and every feature that refreshes
/// a bar indicator goes through here; each caller names the error its own failure reports.
struct SketchyBarControl {
  let processRunner: ProcessRunner
  var timeout: TimeInterval = 1
  /// The error a nonzero exit becomes, given the arguments and the bar's output.
  let failure: (_ arguments: [String], _ output: String) -> any Error

  /// Runs `sketchybar <arguments>` and returns its output.
  @discardableResult func callAsFunction(_ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(executableURL: ExternalTool.sketchybar, arguments: arguments, timeout: timeout))
    guard result.terminationStatus == 0 else { throw failure(arguments, result.output) }
    return result.output
  }

  /// Asks a running bar to refresh a companion now. Its 30-second timer is the backstop, so a
  /// failed hint only warns and the owning state stays authoritative.
  static func hintBar(
    event: String, processRunner: ProcessRunner, installed: Bool, warn: (String) -> Void
  ) {
    guard installed else { return }
    let result = try? processRunner.run(
      .init(executableURL: ExternalTool.sketchybar, arguments: ["--trigger", event], timeout: 1))
    if result?.terminationStatus == 0 { return }
    warn("SketchyBar was not notified of \(event); the indicator refreshes within 30 seconds.")
  }

  static func hintRunningBar(event: String) {
    hintBar(
      event: event, processRunner: .live,
      installed: FileManager.default.isExecutableFile(atPath: ExternalTool.sketchybar.path),
      warn: { try? FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
  }
}
