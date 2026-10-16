import ArgumentParser
import ThemeCore

struct FocusRingOptions: ParsableArguments {
  @Option(help: "Canonical Macarchy state directory.")
  var stateRoot: String

  @Option(help: "Preview duration in seconds (1–300; default 30). Not used by managed services.")
  var seconds: Double?

  @Flag(help: "Run persistently as the exact Macarchy-owned launchd job; not a standalone preview.")
  var managed = false

  var previewDuration: Double { seconds ?? 30 }

  @Flag(help: "Emit bounded JSON diagnostics after the outline is removed.")
  var json = false

  func validate() throws {
    guard !managed || seconds == nil else {
      throw ValidationError("--managed and --seconds are mutually exclusive.")
    }
    guard previewDuration.isFinite, BordersPalette.previewSeconds.contains(previewDuration) else {
      throw ValidationError("--seconds must be between 1 and 300.")
    }
    guard stateRoot.hasPrefix("/") else {
      throw ValidationError("--state-root must be an absolute path.")
    }
  }
}
