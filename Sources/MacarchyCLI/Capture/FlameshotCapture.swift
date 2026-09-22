import Foundation
import ThemeCore

/// Flameshot owns its editor, preferences and background process. Never install,
/// reconfigure, retry or terminate that provider from a capture request.
@MainActor
struct FlameshotCapture {
  let executableURL: URL
  let run: (ProcessRequest) throws -> ProcessResult
  let clipboard: ScreenshotClipboard

  static var live: Self {
    Self(
      executableURL: URL(filePath: "/Applications/Flameshot.app/Contents/MacOS/flameshot"),
      run: ProcessRunner.live.run, clipboard: .live)
  }

  func execute() throws -> ScreenshotOutcome {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw FlameshotCaptureError.missingProvider(executableURL.path)
    }
    let before = clipboard.changeCount()
    let result = try run(
      ProcessRequest(executableURL: executableURL, arguments: ["gui", "--clipboard"]))
    // v14 emits translation warnings even on success. Exit 2 is shared by
    // cancellation and capture failures; never infer cancellation from it.
    guard result.terminationStatus == 0 else {
      throw FlameshotCaptureError.providerFailure(result.terminationStatus, result.output)
    }
    guard clipboard.changeCount() != before, clipboard.containsImage() else {
      throw FlameshotCaptureError.noImage
    }
    return ScreenshotOutcome(status: .copied, savedPath: nil)
  }
}

enum FlameshotCaptureError: Error, CustomStringConvertible {
  case missingProvider(String)
  case providerFailure(Int32, String)
  case noImage

  var description: String {
    switch self {
    case .missingProvider(let path):
      "Flameshot is not executable at \(path). Install and manually open Flameshot before using annotation; see the screenshot section of the user guide. Native capture remains available with macarchy capture screenshot."
    case .providerFailure(let code, let detail):
      (code == 2
        ? "Flameshot aborted; capture may have been cancelled or failed."
        : "Flameshot failed (exit \(code)).")
        + (detail.isEmpty ? "" : " \(detail)")
        + " Review Flameshot and macOS Screen & System Audio Recording permissions if needed. Macarchy does not grant permissions or retry automatically."
    case .noImage:
      "Flameshot finished without a new clipboard image. Use Copy in the editor; the shared clipboard may also have been replaced by another app. No previous clipboard contents were restored."
    }
  }
}
