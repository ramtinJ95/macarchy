import ArgumentParser
import ThemeCore

struct FocusRingOptions: ParsableArguments {
  @Option(
    name: .customLong(FocusRingHelperCommand.stateRootOption),
    help: "Canonical Macarchy state directory.")
  var stateRoot: String

  @Option(
    name: .customLong(FocusRingHelperCommand.secondsOption),
    help: "Preview duration in seconds (1–300; default 30). Not used by managed services.")
  var seconds: Double?

  @Flag(
    name: .customLong(FocusRingHelperCommand.managedFlag),
    help: "Run persistently as the exact Macarchy-owned launchd job; not a standalone preview.")
  var managed = false

  var previewDuration: Double { seconds ?? BordersPalette.defaultPreviewSeconds }

  @Flag(
    name: .customLong(FocusRingHelperCommand.jsonFlag),
    help: "Emit bounded JSON diagnostics after the outline is removed.")
  var json = false

  func validate() throws {
    guard !managed || seconds == nil else {
      throw ValidationError("--managed and --seconds are mutually exclusive.")
    }
    guard previewDuration.isFinite, BordersPalette.previewSeconds.contains(previewDuration) else {
      throw ValidationError(BordersPalette.previewSecondsRangeMessage)
    }
    guard stateRoot.hasPrefix("/") else {
      throw ValidationError("--state-root must be an absolute path.")
    }
  }
}
