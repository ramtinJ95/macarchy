import AppKit
import Foundation
import Vision

enum RegionTextOutcome: String, Encodable {
  case copied, noText, cancelled

  func render(json: Bool) throws -> String {
    if json { return try renderJSON(["status": rawValue]) }
    switch self {
    case .copied: return "Recognized text copied to clipboard."
    case .noText: return "No text recognized. Clipboard unchanged."
    case .cancelled: return "Text capture cancelled."
    }
  }
}

@MainActor
struct RegionTextCapture {
  let capture: () throws -> Data?
  let recognize: (Data) throws -> [String]
  let copyText: (String) throws -> Void

  static var live: Self {
    Self(
      capture: { try ScreenshotCapture.live.capturedPNG() },
      recognize: recognizeEnglish,
      copyText: { text in
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { throw RegionTextError.clipboard }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([item]) else { throw RegionTextError.clipboard }
      })
  }

  func execute() throws -> RegionTextOutcome {
    guard let png = try capture() else { return .cancelled }
    let lines: [String]
    do { lines = try recognize(png) } catch {
      // Framework diagnostics are not a public payload channel.
      throw RegionTextError.recognition
    }
    let text = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n")
    guard !text.isEmpty else { return .noText }
    do { try copyText(text) } catch { throw RegionTextError.clipboard }
    return .copied
  }

  static func recognizeEnglish(_ png: Data) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = false
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(data: png).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  }
}

enum RegionTextError: Error, CustomStringConvertible {
  case recognition, clipboard

  var description: String {
    switch self {
    case .recognition: "On-device text recognition failed. Clipboard unchanged."
    case .clipboard: "Could not copy recognized text to the clipboard."
    }
  }
}
