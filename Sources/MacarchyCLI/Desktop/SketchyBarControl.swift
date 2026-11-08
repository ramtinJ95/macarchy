import Foundation
import ThemeCore

/// Sends one command to the running SketchyBar. Every bar helper goes through here; each caller
/// names the error its own failure reports. Features that only ask a bar indicator to refresh use
/// `SketchyBarHint`.
struct SketchyBarControl {
  let processRunner: ProcessRunner
  var timeout: TimeInterval = 1
  /// The error a nonzero exit becomes, given the arguments and the bar's output.
  let failure: (_ arguments: [String], _ output: String) -> any Error

  @discardableResult func callAsFunction(_ arguments: [String]) throws -> String {
    let result = try processRunner.run(
      .init(executableURL: ExternalTool.sketchybar, arguments: arguments, timeout: timeout))
    guard result.terminationStatus == 0 else { throw failure(arguments, result.output) }
    return result.output
  }
}
