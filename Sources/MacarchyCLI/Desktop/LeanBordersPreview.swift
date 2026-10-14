import ArgumentParser
import Darwin
import Foundation
import ThemeCore

enum BordersPreviewRenderer: String, CaseIterable, ExpressibleByArgument {
  case borders, lean
}

/// Bounded preview through the sibling `macarchy-focus-ring` helper. The helper
/// owns native preflight, its duration and its report; this parent only checks
/// the palette and helper file, then supervises the owned child.
enum LeanBordersPreview {
  static let helperName = "macarchy-focus-ring"
  /// Time for the helper to hide, close and report after its own duration.
  static let exitGrace: TimeInterval = 5

  static func helperURL(beside executable: URL) -> URL {
    executable.deletingLastPathComponent().appending(path: helperName)
  }

  static func helperArguments(stateRoot: String, seconds: Double, json: Bool) -> [String] {
    ["--state-root", stateRoot, "--seconds", String(seconds)] + (json ? ["--json"] : [])
  }

  /// Returns the handled signal that ended supervision, or nil after a clean exit.
  static func supervise(helper: URL, arguments: [String], limit: TimeInterval) throws -> Int32? {
    try withPreviewStopSignals { received -> Int32? in
      // The helper reports only after hiding and closing its window, so it may
      // share stdout; a stalled reader is bounded by the deadline below.
      let process = try BordersPreviewProcess.start(
        executableURL: helper, arguments: arguments, standardOutput: .standardOutput)
      // Stops the owned child on every exit path before the signal handlers are restored.
      defer { process.stop() }
      let deadline = ProcessInfo.processInfo.systemUptime + limit
      while process.isRunning(), received() == nil {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw LeanBordersPreviewError.didNotExit(limit)
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      if let signal = received() { return signal }
      let status = process.terminationStatus()
      guard status == 0 else { throw LeanBordersPreviewError.exited(status) }
      return nil
    }
  }
}

struct LeanBordersPreviewPlan: Encodable {
  let event: String
  let renderer: String
  let message: String
  let dryRun: Bool
  let generationID: String
  let themeID: String
  let helper: String
  let arguments: [String]

  enum CodingKeys: String, CodingKey {
    case event, renderer, message, helper, arguments
    case dryRun = "dry_run"
    case generationID = "generation_id"
    case themeID = "theme_id"
  }
}

enum LeanBordersPreviewError: Error, CustomStringConvertible {
  case helperUnavailable(String)
  case exited(Int32)
  case didNotExit(TimeInterval)

  var description: String {
    switch self {
    case .helperUnavailable(let path):
      "The lean renderer helper is missing or not executable at \(path); build the macarchy-focus-ring product beside macarchy. No preview was started."
    case .exited(let status):
      "macarchy-focus-ring exited with status \(status); its native stderr is preserved. No other process was stopped."
    case .didNotExit(let limit):
      "macarchy-focus-ring did not exit within \(limit)s; only the owned helper was stopped."
    }
  }
}

extension Borders.Preview {
  func runLean(helper: URL) throws {
    let palette = try BordersPalette.read(root: URL(filePath: stateRoot))
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
      throw LeanBordersPreviewError.helperUnavailable(helper.path)
    }
    let arguments = LeanBordersPreview.helperArguments(
      stateRoot: stateRoot, seconds: seconds, json: json)
    let message =
      dryRun
      ? "Dry run: only the canonical palette and the helper file were checked. No renderer or native capability check, no pixel proof; the helper was not launched."
      : "Launch the owned \(LeanBordersPreview.helperName) for \(seconds)s from '\(palette.themeID)'. The helper preflights native capability, the GUI session and incumbent renderers on every run; its report follows cleanup. No service, configuration, permission or canonical-state changes."
    let plan = LeanBordersPreviewPlan(
      event: "planned", renderer: "lean", message: message, dryRun: dryRun,
      generationID: palette.generationID, themeID: palette.themeID,
      helper: helper.path, arguments: arguments
    )
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      print(String(decoding: try encoder.encode(plan), as: UTF8.self))
    } else {
      print("planned: \(message)")
      print("  \(helper.path) " + arguments.joined(separator: " "))
    }
    // Flush the plan before the child can draw: a stalled stdout must block here.
    fflush(stdout)
    if dryRun { return }
    if let signal = try LeanBordersPreview.supervise(
      helper: helper, arguments: arguments, limit: seconds + LeanBordersPreview.exitGrace)
    {
      throw ExitCode(128 + signal)
    }
  }
}
