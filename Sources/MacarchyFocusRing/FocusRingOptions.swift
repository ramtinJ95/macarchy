import ArgumentParser

struct FocusRingOptions: ParsableArguments {
  @Option(help: "Canonical Macarchy state directory.")
  var stateRoot: String

  @Option(help: "Prototype duration in seconds (1–300).")
  var seconds: Double = 30

  @Flag(help: "Emit bounded JSON diagnostics after the outline is removed.")
  var json = false

  func validate() throws {
    guard FocusRingDuration.isValid(seconds) else {
      throw ValidationError("--seconds must be between 1 and 300.")
    }
  }
}

enum FocusRingDuration {
  static let bounds: ClosedRange<Double> = 1...300

  static func isValid(_ seconds: Double) -> Bool {
    seconds.isFinite && bounds.contains(seconds)
  }
}
