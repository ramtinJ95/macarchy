import Foundation

enum YabaiWallpaperSignalError: Error, CustomStringConvertible, Equatable, Sendable {
  case cannotReadConfiguration(URL)
  case executableUnavailable(URL)
  case invalidRuntimeState
  case missingDirective(String)
  case runtimeCommandFailed(String)
  case runtimeSignalMissing

  var description: String {
    switch self {
    case .cannotReadConfiguration(let url):
      "Cannot read yabai configuration at \(url.path)"
    case .executableUnavailable(let url):
      "Required wallpaper signal executable is unavailable at \(url.path)"
    case .invalidRuntimeState:
      "yabai returned invalid signal state"
    case .missingDirective(let directive):
      "yabai configuration must contain '\(directive)'"
    case .runtimeCommandFailed(let output):
      output.isEmpty
        ? "Cannot inspect loaded yabai signals" : "Cannot inspect loaded yabai signals: \(output)"
    case .runtimeSignalMissing:
      "The macarchy-wallpaper signal is configured but not loaded in yabai"
    }
  }
}

struct YabaiWallpaperSignal: Sendable {
  let configurationURL: URL
  let macarchyExecutableURL: URL
  let yabaiExecutableURL: URL

  static func personal(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Self {
    Self(
      configurationURL: homeDirectory.appending(path: ".config/yabai/yabairc"),
      macarchyExecutableURL: homeDirectory.appending(path: ".local/bin/macarchy"),
      yabaiExecutableURL: URL(filePath: "/opt/homebrew/bin/yabai")
    )
  }

  var directive: String {
    "yabai -m signal --add event=space_changed label=macarchy-wallpaper action=\"\(macarchyExecutableURL.path) reconcile wallpaper\""
  }

  var readyMessage: String {
    "yabai space_changed is configured to reconcile each Space lazily through \(macarchyExecutableURL.path)"
  }

  func preflight() throws {
    guard FileManager.default.isExecutableFile(atPath: yabaiExecutableURL.path) else {
      throw YabaiWallpaperSignalError.executableUnavailable(yabaiExecutableURL)
    }
    guard FileManager.default.isExecutableFile(atPath: macarchyExecutableURL.path) else {
      throw YabaiWallpaperSignalError.executableUnavailable(macarchyExecutableURL)
    }
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: configurationURL).data
    } catch {
      throw YabaiWallpaperSignalError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw YabaiWallpaperSignalError.cannotReadConfiguration(configurationURL)
    }
    guard containsExactLine(directive, in: configuration) else {
      throw YabaiWallpaperSignalError.missingDirective(directive)
    }
  }

  func runtimePreflight(processRunner: ProcessRunner) throws {
    let result = try processRunner.run(
      ProcessRequest(
        executableURL: yabaiExecutableURL,
        arguments: ["-m", "signal", "--list"],
        timeout: 2
      )
    )
    guard result.terminationStatus == 0 else {
      throw YabaiWallpaperSignalError.runtimeCommandFailed(result.output)
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
    } catch {
      throw YabaiWallpaperSignalError.invalidRuntimeState
    }
    guard let signals = object as? [[String: Any]] else {
      throw YabaiWallpaperSignalError.invalidRuntimeState
    }
    guard
      signals.contains(where: { signal in
        signal["label"] as? String == "macarchy-wallpaper"
          && signal["event"] as? String == "space_changed"
          && signal["action"] as? String
            == "\(macarchyExecutableURL.path) reconcile wallpaper"
      })
    else {
      throw YabaiWallpaperSignalError.runtimeSignalMissing
    }
  }
}
