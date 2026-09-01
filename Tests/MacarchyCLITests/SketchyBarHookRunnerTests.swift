import Foundation
import Testing

@testable import MacarchyCLI

@Suite(.serialized)
struct SketchyBarHookRunnerTests {
  @Test
  func executesSuccessfulHookAndTerminatesTimedOutSynchronousWork() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-sketchybar-hook-runner-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hook = root.appending(path: "hook.sh")
    let marker = root.appending(path: "marker")
    try "printf success > '\(marker.path)'\n".write(
      to: hook,
      atomically: true,
      encoding: .utf8
    )

    try SketchyBarHookRunner().execute(hook)

    #expect(try String(contentsOf: marker, encoding: .utf8) == "success")

    try FileManager.default.removeItem(at: marker)
    try "/bin/sleep 0.2\nprintf late > '\(marker.path)'\n".write(
      to: hook,
      atomically: true,
      encoding: .utf8
    )
    #expect(throws: SketchyBarHookRunnerError.self) {
      try SketchyBarHookRunner(executionLimit: 0.05).execute(hook)
    }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
