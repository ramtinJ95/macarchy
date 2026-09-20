import AppKit
import ArgumentParser
import Foundation

struct CaptureCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture", abstract: "Capture with the native macOS screenshot picker.",
    subcommands: [Screenshot.self])

  struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Select a region or window and copy its image to the clipboard.",
      discussion: "Space switches between region and window selection; Escape cancels.")

    @Flag(help: "Start in window-selection mode.")
    var window = false

    @Option(help: "Also save a PNG at this path. Its parent must exist; never overwrites a file.")
    var save: String?

    @Flag(help: "Emit the outcome as JSON, without image or clipboard contents.")
    var json = false

    @Flag(help: .hidden)
    var alertOnError = false

    mutating func validate() throws {
      if let save, save.isEmpty || URL(filePath: save).pathExtension.lowercased() != "png" {
        throw ValidationError("--save requires a nonempty PNG file path")
      }
    }

    @MainActor
    mutating func run() async throws {
      do {
        let outcome = try ScreenshotCapture.live.execute(
          window: window, saveURL: save.map { URL(filePath: $0).standardizedFileURL })
        print(try outcome.render(json: json))
      } catch {
        if alertOnError { Self.showFailure(error) }
        throw error
      }
    }

    @MainActor
    static func showFailure(_ error: any Error) {
      let app = NSApplication.shared
      _ = app.setActivationPolicy(.accessory)
      app.finishLaunching()
      let alert = NSAlert()
      alert.messageText = "Screenshot not completed"
      alert.informativeText = String(describing: error)
      alert.alertStyle = .critical
      app.activate(ignoringOtherApps: true)
      alert.runModal()
    }
  }
}
