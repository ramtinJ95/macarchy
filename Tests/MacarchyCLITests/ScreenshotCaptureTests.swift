import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@MainActor
struct ScreenshotCaptureTests {
  @Test(arguments: [false, true])
  func directCaptureUsesNativePickerAndNoDiskOrClipboardRead(window: Bool) throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { [unowned fixture] _ in
      fixture.changeCount += 1
      fixture.hasImage = true
      return .init(terminationStatus: 0, output: "")
    }
    let outcome = try fixture.runner.execute(window: window)
    #expect(outcome == ScreenshotOutcome(status: .copied, savedPath: nil))
    let request = try #require(fixture.requests.first)
    #expect(request.arguments == ["-i", "-t", "png"] + (window ? ["-W"] : []) + ["-c"])
    #expect(request.timeout == nil)
    #expect(fixture.requests.count == 1)
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test func cancelledSelectionDoesNotMistakeAnOldImageForSuccess() throws {
    let fixture = try ScreenshotFixture()
    fixture.hasImage = true
    #expect(try fixture.runner.execute() == .cancelled)
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test func nonzeroExitIsNotSilentlyClassifiedAsCancellation() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { _ in .init(terminationStatus: 1, output: "") }
    do {
      _ = try fixture.runner.execute()
      Issue.record("Native failure was accepted")
    } catch ScreenshotError.nativeFailure(let actual, let detail) {
      #expect(actual == 1)
      #expect(detail.isEmpty)
    }
    #expect(fixture.requests.count == 1)
    #expect(fixture.copied.isEmpty)
  }

  @Test func permissionDiagnosticsRemainVisibleWithoutRetryOrClipboardRestoration() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { [unowned fixture] _ in
      fixture.changeCount += 1
      return .init(terminationStatus: 1, output: "Screen capture permission denied")
    }
    do {
      _ = try fixture.runner.execute()
      Issue.record("Denied capture was accepted")
    } catch {
      #expect(String(describing: error).contains("Screen capture permission denied"))
    }
    #expect(fixture.requests.count == 1)
    #expect(fixture.copied.isEmpty)
  }

  @Test func unexpectedNativeDiagnosticsAreNotDiscarded() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { _ in .init(terminationStatus: 0, output: "unexpected diagnostic") }
    #expect(throws: ScreenshotError.self) { try fixture.runner.execute() }
  }

  @Test func changedNonImageClipboardFailsWithoutOverwritingIt() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { [unowned fixture] _ in
      fixture.changeCount += 1
      return .init(terminationStatus: 0, output: "")
    }
    #expect(throws: ScreenshotError.self) { try fixture.runner.execute() }
    #expect(fixture.copied.isEmpty)
  }

  @Test func missingExecutableAndLaunchFailureAreExplicit() throws {
    let fixture = try ScreenshotFixture()
    let missing = ScreenshotCapture(
      executableURL: fixture.root.appending(path: "missing"), run: fixture.runner.run,
      clipboard: fixture.runner.clipboard, temporaryRoot: fixture.root)
    #expect(throws: ScreenshotError.self) { try missing.execute() }
    #expect(fixture.requests.isEmpty)
    fixture.operation = { _ in throw CocoaError(.executableNotLoadable) }
    #expect(throws: CocoaError.self) { try fixture.runner.execute() }
  }

  @Test func explicitSaveCopiesTheCapturedPNGAndRemovesPrivateStaging() throws {
    let fixture = try ScreenshotFixture()
    let png = try screenshotPNG()
    let destination = fixture.root.appending(path: "capture ' $(literal).png")
    fixture.captureFile(png)
    let outcome = try fixture.runner.execute(window: true, saveURL: destination)
    #expect(outcome == ScreenshotOutcome(status: .copied, savedPath: destination.path))
    #expect(try Data(contentsOf: destination) == png)
    #expect(fixture.copied == [png])
    #expect(try fixture.files() == [destination.lastPathComponent])
    let request = try #require(fixture.requests.first)
    #expect(Array(request.arguments.prefix(4)) == ["-i", "-t", "png", "-W"])
    #expect(!request.arguments.contains("-c"))
    #expect(!request.arguments.contains(destination.path))
    #expect(fixture.stagingMode == 0o700)
  }

  @Test func cancelledFileCaptureCreatesNoDestinationAndLeavesClipboardAlone() throws {
    let fixture = try ScreenshotFixture()
    #expect(try fixture.runner.execute(saveURL: fixture.destination) == .cancelled)
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test func redirectedNativeFileCaptureDoesNotReadAnUncorrelatedClipboardImage() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { [unowned fixture] _ in
      fixture.changeCount += 1
      fixture.hasImage = true
      return .init(terminationStatus: 0, output: "")
    }
    #expect(throws: ScreenshotError.self) {
      try fixture.runner.execute(saveURL: fixture.destination)
    }
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test func nativeFileFailureCleansStagingWithoutPublishingIt() throws {
    let fixture = try ScreenshotFixture()
    fixture.operation = { request in
      try Data("partial".utf8).write(to: URL(filePath: try #require(request.arguments.last)))
      return .init(terminationStatus: 1, output: "could not create image from display")
    }
    #expect(throws: ScreenshotError.self) {
      try fixture.runner.execute(saveURL: fixture.destination)
    }
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test func invalidPNGIsNotSavedOrCopied() throws {
    let fixture = try ScreenshotFixture()
    fixture.captureFile(Data("not an image".utf8))
    #expect(throws: ScreenshotError.self) {
      try fixture.runner.execute(saveURL: fixture.destination)
    }
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [])
  }

  @Test(arguments: ["existing", "symlink", "dangling", "directory"])
  func existingDestinationIsNeverReplaced(kind: String) throws {
    let fixture = try ScreenshotFixture()
    switch kind {
    case "symlink", "dangling":
      let target = fixture.root.appending(path: "original")
      if kind == "symlink" { try Data("original".utf8).write(to: target) }
      try FileManager.default.createSymbolicLink(
        at: fixture.destination, withDestinationURL: target)
    case "directory":
      try FileManager.default.createDirectory(
        at: fixture.destination, withIntermediateDirectories: false)
    default: try Data("original".utf8).write(to: fixture.destination)
    }
    #expect(throws: ScreenshotError.self) {
      try fixture.runner.execute(saveURL: fixture.destination)
    }
    #expect(fixture.requests.isEmpty)
    #expect(fixture.copied.isEmpty)
    if kind == "existing" {
      #expect(try Data(contentsOf: fixture.destination) == Data("original".utf8))
    }
  }

  @Test func destinationCreatedDuringSelectionIsPreserved() throws {
    let fixture = try ScreenshotFixture()
    let png = try screenshotPNG()
    fixture.operation = { [unowned fixture] request in
      try Data("new unrelated file".utf8).write(to: fixture.destination)
      try png.write(to: URL(filePath: try #require(request.arguments.last)))
      return .init(terminationStatus: 0, output: "")
    }
    #expect(throws: CocoaError.self) { try fixture.runner.execute(saveURL: fixture.destination) }
    #expect(try Data(contentsOf: fixture.destination) == Data("new unrelated file".utf8))
    #expect(fixture.copied.isEmpty)
    #expect(try fixture.files() == [fixture.destination.lastPathComponent])
  }

  @Test func badDestinationStopsBeforeOpeningThePicker() throws {
    let fixture = try ScreenshotFixture()
    for url in [
      fixture.root.appending(path: "missing/capture.png"), fixture.root.appending(path: "a.jpg"),
    ] {
      #expect(throws: ScreenshotError.self) { try fixture.runner.execute(saveURL: url) }
    }
    #expect(fixture.requests.isEmpty)
  }

  @Test func clipboardFailureReportsTheSavedFileAndPreservesIt() throws {
    let fixture = try ScreenshotFixture()
    let png = try screenshotPNG()
    fixture.captureFile(png)
    fixture.failCopy = true
    do {
      _ = try fixture.runner.execute(saveURL: fixture.destination)
      Issue.record("Clipboard failure was accepted")
    } catch ScreenshotError.savedButNotCopied(let path, _) {
      #expect(path == fixture.destination.path)
    }
    #expect(try Data(contentsOf: fixture.destination) == png)
    #expect(try fixture.files() == [fixture.destination.lastPathComponent])
  }

  @Test func parsingAndReportingDoNotCaptureOrExposeImageData() throws {
    let command = try #require(
      Macarchy.parseAsRoot([
        "capture", "screenshot", "--window", "--save", "/tmp/example.png", "--json",
        "--alert-on-error",
      ]) as? CaptureCommand.Screenshot)
    #expect(command.window && command.json && command.alertOnError)
    #expect(command.save == "/tmp/example.png")
    for path in ["", "/tmp/example.jpg"] {
      #expect(throws: (any Error).self) {
        try Macarchy.parseAsRoot(["capture", "screenshot", "--save", path])
      }
    }
    let cancelled = try ScreenshotOutcome.cancelled.render(json: true)
    let fields = try #require(
      JSONSerialization.jsonObject(with: Data(cancelled.utf8)) as? [String: String])
    #expect(fields == ["status": "cancelled"])
    #expect(
      try ScreenshotOutcome(status: .copied, savedPath: nil).render(json: false)
        == "Screenshot copied to clipboard.")
  }
}

@MainActor
private final class ScreenshotFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-capture-test-\(UUID())")
  var requests: [ProcessRequest] = []
  var changeCount = 11
  var hasImage = false
  var copied: [Data] = []
  var failCopy = false
  var stagingMode: Int?
  var operation: ((ProcessRequest) throws -> ProcessResult)?

  init() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  var destination: URL { root.appending(path: "screenshot.png") }

  var runner: ScreenshotCapture {
    ScreenshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { [self] request in
        requests.append(request)
        return try operation?(request) ?? ProcessResult(terminationStatus: 0, output: "")
      },
      clipboard: ScreenshotClipboard(
        changeCount: { [self] in changeCount }, containsImage: { [self] in hasImage },
        copyPNG: { [self] data in
          if failCopy { throw ScreenshotError.clipboardWrite }
          copied.append(data)
          changeCount += 1
          hasImage = true
        }), temporaryRoot: root)
  }

  func captureFile(_ data: Data) {
    operation = { [unowned self] request in
      let url = URL(filePath: try #require(request.arguments.last))
      let attributes = try FileManager.default.attributesOfItem(
        atPath: url.deletingLastPathComponent().path)
      stagingMode = (attributes[.posixPermissions] as? NSNumber)?.intValue
      try data.write(to: url)
      return .init(terminationStatus: 0, output: "")
    }
  }

  func files() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  }
}

private func screenshotPNG() throws -> Data {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
  for x in 0..<2 {
    for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
  }
  return try #require(bitmap.representation(using: .png, properties: [:]))
}
