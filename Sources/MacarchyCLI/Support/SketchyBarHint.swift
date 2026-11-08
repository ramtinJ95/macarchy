import Foundation
import ThemeCore

/// Asks a running SketchyBar to refresh a companion indicator now. Features whose state a bar
/// indicator shows send these without depending on the desktop bar code.
enum SketchyBarHint {
  /// Its 30-second timer is the backstop, so a failed hint only warns and the owning state stays
  /// authoritative.
  static func trigger(
    event: String, processRunner: ProcessRunner, installed: Bool, warn: (String) -> Void
  ) {
    guard installed else { return }
    let result = try? processRunner.run(
      .init(executableURL: ExternalTool.sketchybar, arguments: ["--trigger", event], timeout: 1))
    if result?.terminationStatus == 0 { return }
    warn("SketchyBar was not notified of \(event); the indicator refreshes within 30 seconds.")
  }

  static func triggerRunningBar(event: String) {
    trigger(
      event: event, processRunner: .live,
      installed: FileManager.default.isExecutableFile(atPath: ExternalTool.sketchybar.path),
      warn: { try? FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
  }
}
