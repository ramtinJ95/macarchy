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
  let compatibleMacarchyExecutableURLs: [URL]

  init(
    configurationURL: URL,
    macarchyExecutableURL: URL,
    yabaiExecutableURL: URL,
    compatibleMacarchyExecutableURLs: [URL] = []
  ) {
    self.configurationURL = configurationURL.standardizedFileURL
    self.macarchyExecutableURL = macarchyExecutableURL.standardizedFileURL
    self.yabaiExecutableURL = yabaiExecutableURL.standardizedFileURL
    self.compatibleMacarchyExecutableURLs = compatibleMacarchyExecutableURLs.map {
      $0.standardizedFileURL
    }
  }

  static func personal(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    macarchyExecutableURL: URL = URL(filePath: "/opt/homebrew/bin/macarchy")
  ) -> Self {
    Self(
      configurationURL: homeDirectory.appending(path: ".config/yabai/yabairc"),
      macarchyExecutableURL: macarchyExecutableURL,
      yabaiExecutableURL: URL(filePath: "/opt/homebrew/bin/yabai"),
      compatibleMacarchyExecutableURLs: [
        URL(filePath: "/opt/homebrew/bin/macarchy"),
        homeDirectory.appending(path: ".local/bin/macarchy"),
      ]
    )
  }

  var directive: String {
    directive(for: macarchyExecutableURL)
  }

  var readyMessage: String {
    "yabai space_changed is configured to reconcile each Space lazily through \(macarchyExecutableURL.path)"
  }

  func preflight() throws {
    guard FileManager.default.isExecutableFile(atPath: yabaiExecutableURL.path) else {
      throw YabaiWallpaperSignalError.executableUnavailable(yabaiExecutableURL)
    }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: configurationURL.resolvingSymlinksInPath()
      ).data
    } catch {
      throw YabaiWallpaperSignalError.cannotReadConfiguration(configurationURL)
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw YabaiWallpaperSignalError.cannotReadConfiguration(configurationURL)
    }
    guard
      let executable = executableURLs.first(where: {
        containsExactLine(directive(for: $0), in: configuration)
          || containsExactLine(managedDirective(for: $0), in: configuration)
      })
    else {
      throw YabaiWallpaperSignalError.missingDirective(directive)
    }
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw YabaiWallpaperSignalError.executableUnavailable(executable)
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
          && executableURLs.contains {
            signal["action"] as? String == "\($0.path) reconcile wallpaper"
          }
      })
    else {
      throw YabaiWallpaperSignalError.runtimeSignalMissing
    }
  }

  private var executableURLs: [URL] {
    var seen = Set<String>()
    return ([macarchyExecutableURL] + compatibleMacarchyExecutableURLs).filter {
      seen.insert($0.path).inserted
    }
  }

  private func directive(for executable: URL) -> String {
    "yabai -m signal --add event=space_changed label=macarchy-wallpaper action=\"\(executable.path) reconcile wallpaper\""
  }

  private func managedDirective(for executable: URL) -> String {
    "\"$YABAI\" -m signal --add event=space_changed label=macarchy-wallpaper action='\(executable.path) reconcile wallpaper'"
  }
}
