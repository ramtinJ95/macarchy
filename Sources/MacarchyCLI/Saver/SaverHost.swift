import Foundation
import ThemeCore

/// Which displays one start covers.
enum SaverCoverage: Equatable, Sendable {
  /// One panel per named output, in Kitty's order.
  case outputs([String])
  /// One panel on Kitty's default display, and why Kitty named none.
  case mainOnly(reason: String)

  var displays: [SaverDisplay] {
    switch self {
    case .outputs(let names): names.map(SaverDisplay.output)
    case .mainOnly: [.main]
    }
  }
}

/// Kitty panels that host the saver, one per display. LaunchServices starts each as its own
/// Kitty instance, so it is never a child of the CLI and never joins the user's Kitty.
enum SaverHost {
  static let opener = URL(filePath: "/usr/bin/open")
  static let kitten = SaverKitty.application.appending(path: "Contents/MacOS/kitten")

  /// The `open` arguments for one panel of the launch with `token`. The saver text is never an
  /// argument; the runner feeds it to ttfx through a pipe.
  static func panelArguments(
    for display: SaverDisplay, token: String, palette: SaverPalette, stateRoot: URL, command: URL
  ) -> [String] {
    let cache = SaverRecords(stateRoot: stateRoot).kittyCache
    var arguments = [
      "-n", "-a", SaverKitty.application.path, "--env", "KITTY_CACHE_DIRECTORY=\(cache.path)",
      "--args", "+kitten", "panel", "--edge=center", "--layer=overlay", "--focus-policy=exclusive",
    ]
    if let name = display.outputName { arguments.append("--output-name=\(name)") }
    arguments += [
      "-o", "macos_use_physical_screen_frame=yes", "-o", "background=\(palette.background)",
      "-o", "foreground=\(palette.foreground)", "-o", "font_size=18",
      "-o", "window_padding_width=0", "-o", "mouse_hide_wait=0.25",
      "-o", "macos_quit_when_last_window_closed=yes", "--config", "NONE",
      command.path, "saver", "_run", "--state-root", stateRoot.path, "--launch", token,
    ]
    if let name = display.outputName { arguments += ["--display", name] }
    return arguments
  }

  /// The displays named by `kitten panel --output-name=listjson`: a JSON array of names or of
  /// objects with a `name`.
  static func coverage(listJSON output: String) -> SaverCoverage {
    guard let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [Any]
    else { return .mainOnly(reason: "Kitty did not list its displays as a JSON array") }
    var names: [String] = []
    for entry in entries {
      let name = (entry as? String) ?? ((entry as? [String: Any])?["name"] as? String)
      guard let name, !name.isEmpty, !names.contains(name),
        !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else { continue }
      names.append(name)
    }
    return names.isEmpty ? .mainOnly(reason: "Kitty reported no display names") : .outputs(names)
  }

  static func coverage(processRunner: ProcessRunner) -> SaverCoverage {
    let request = ProcessRequest(
      executableURL: kitten, arguments: ["panel", "--output-name=listjson"], timeout: 10)
    do {
      let result = try processRunner.run(request)
      guard result.terminationStatus == 0 else {
        return .mainOnly(reason: "kitten panel exited with status \(result.terminationStatus)")
      }
      return coverage(listJSON: result.output)
    } catch {
      return .mainOnly(reason: "kitten panel failed: \(error)")
    }
  }
}
