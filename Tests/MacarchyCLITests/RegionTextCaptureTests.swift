import AppKit
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

@MainActor
struct RegionTextCaptureTests {
  @Test func unicodeIsCopiedButNeverReported() throws {
    let payload = "Café 日本語 👋\nمرحبا"
    var copied: [String] = []
    let capture = RegionTextCapture(
      capture: { Data() }, recognize: { _ in ["", "Café 日本語 👋", "مرحبا", "  "] },
      copyText: { copied.append($0) })
    let result = try capture.execute()
    #expect(result == .copied)
    #expect(copied == [payload])
    #expect(try result.render(json: false) == "Recognized text copied to clipboard.")
    let json = try JSONSerialization.jsonObject(with: Data(result.render(json: true).utf8))
    #expect(json as? [String: String] == ["status": "copied"])
  }

  @Test(arguments: [true, false])
  func cancellationAndNoTextDoNotPublish(cancelled: Bool) throws {
    let capture = RegionTextCapture(
      capture: { cancelled ? nil : Data() },
      recognize: { _ in
        #expect(!cancelled)
        return ["", " \n"]
      }, copyText: { _ in Issue.record("Non-success replaced clipboard") })
    let result = try capture.execute()
    #expect(result == (cancelled ? .cancelled : .noText))
    let json = try JSONSerialization.jsonObject(with: Data(result.render(json: true).utf8))
    #expect(json as? [String: String] == ["status": cancelled ? "cancelled" : "noText"])
  }

  @Test(arguments: ["capture", "recognize", "copy"])
  func failuresAreExplicitWithoutLeakingRecognitionPayload(stage: String) throws {
    struct PayloadError: Error, CustomStringConvertible {
      var description: String { "private recognition payload" }
    }
    var copies = 0
    let capture = RegionTextCapture(
      capture: {
        if stage == "capture" { throw ScreenshotError.invalidImage }
        return Data()
      },
      recognize: { _ in
        if stage == "recognize" { throw PayloadError() }
        return ["private recognition payload"]
      },
      copyText: { _ in
        copies += 1
        throw PayloadError()
      })
    do {
      _ = try capture.execute()
      Issue.record("Failure accepted")
    } catch {
      #expect(!String(describing: error).contains("private recognition payload"))
      #expect(copies == (stage == "copy" ? 1 : 0))
    }
  }

  @Test func nativeStagingIsGoneBeforeRecognitionAndDoesNotCopyAnImage() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "macarchy-ocr-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = try fixturePNG(text: "Macarchy OCR 12345")
    let native = ScreenshotCapture(
      executableURL: URL(filePath: "/usr/bin/true"),
      run: { request in
        #expect(Array(request.arguments.prefix(3)) == ["-i", "-t", "png"])
        #expect(request.arguments.count == 4)
        #expect(request.timeout == nil)
        let path = URL(filePath: try #require(request.arguments.last))
        let attrs = try FileManager.default.attributesOfItem(
          atPath: path.deletingLastPathComponent().path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try png.write(to: path)
        return ProcessResult(terminationStatus: 0, output: "")
      },
      clipboard: ScreenshotClipboard(
        changeCount: { 1 }, containsImage: { false },
        copyPNG: { _ in Issue.record("OCR copied image") }), temporaryRoot: root)
    var copied: String?
    let capture = RegionTextCapture(
      capture: { try native.capturedPNG() },
      recognize: { data in
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        return try RegionTextCapture.recognizeEnglish(data)
      }, copyText: { copied = $0 })
    #expect(try capture.execute() == .copied)
    #expect(copied == "Macarchy OCR 12345")
  }

  @Test func realVisionBlankImageHasNoText() throws {
    #expect(try RegionTextCapture.recognizeEnglish(fixturePNG(text: "")).isEmpty)
  }

  private func fixturePNG(text: String) throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 140, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 900, height: 140).fill()
    (text as NSString).draw(
      at: NSPoint(x: 30, y: 45),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black,
      ])
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
