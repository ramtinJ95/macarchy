import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@MainActor
struct FlameshotCaptureTests {
  @Test func copiesAfterEditorCompletionDespiteTranslationWarnings() throws {
    var count = 12
    let capture = FlameshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { request in
        #expect(request.executableURL.path == "/usr/bin/true")
        #expect(request.arguments == ["gui", "--clipboard"])
        #expect(request.timeout == nil)
        count += 1
        return ProcessResult(terminationStatus: 0, output: "Unable to load translation")
      },
      clipboard: ScreenshotClipboard(
        changeCount: { count }, containsImage: { true },
        copyPNG: { _ in Issue.record("Provider owns clipboard output") }))
    #expect(try capture.execute() == ScreenshotOutcome(status: .copied, savedPath: nil))
  }

  @Test(arguments: [2, 1])
  func abortAndFailureAreNotSilentlyCalledCancellation(code: Int32) throws {
    var runs = 0
    let capture = FlameshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { _ in
        runs += 1
        return ProcessResult(terminationStatus: code, output: "provider diagnostic")
      }, clipboard: clipboard())
    do {
      _ = try capture.execute()
      Issue.record("Provider failure was swallowed")
    } catch FlameshotCaptureError.providerFailure(let status, let detail) {
      #expect(status == code)
      #expect(detail == "provider diagnostic")
    }
    #expect(runs == 1)
  }

  @Test(arguments: [false, true])
  func successfulExitRequiresChangedImage(changed: Bool) throws {
    var count = 3
    let capture = FlameshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { _ in
        if changed { count += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      },
      clipboard: ScreenshotClipboard(
        changeCount: { count }, containsImage: { !changed },
        copyPNG: { _ in Issue.record("Unexpected clipboard write") }))
    #expect(throws: FlameshotCaptureError.self) { try capture.execute() }
  }

  @Test func missingProviderDoesNotLaunch() {
    let capture = FlameshotCapture(
      executableURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      run: { _ in
        Issue.record("Missing provider launched")
        return ProcessResult(terminationStatus: 0, output: "")
      }, clipboard: clipboard())
    #expect(throws: FlameshotCaptureError.self) { try capture.execute() }
  }

  @Test func launchFailurePropagates() {
    struct LaunchFailure: Error {}
    let capture = FlameshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { _ in throw LaunchFailure() }, clipboard: clipboard())
    #expect(throws: LaunchFailure.self) { try capture.execute() }
  }

  private func clipboard() -> ScreenshotClipboard {
    ScreenshotClipboard(
      changeCount: { 1 }, containsImage: { true },
      copyPNG: { _ in Issue.record("Unexpected clipboard write") })
  }
}
