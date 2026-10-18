import Darwin
import Foundation

/// Why the bundled ttfx engine cannot run.
enum SaverEngineDefect: String, Equatable, Sendable {
  case absent
  case notRegularFile = "not_regular_file"
  case notExecutable = "not_executable"

  var summary: String {
    switch self {
    case .absent: "not found"
    case .notRegularFile: "not a regular file"
    case .notExecutable: "not executable"
    }
  }
}

/// The ttfx engine that Macarchy's release archive installs at `libexec/ttfx`, beside `bin/`.
struct SaverEngine: Equatable, Sendable {
  static let remedy =
    "Reinstall Macarchy from its release with `brew reinstall ramtinj95/tap/macarchy`;"
    + " source builds do not include ttfx."

  let url: URL
  /// nil when the engine can run.
  let defect: SaverEngineDefect?

  /// `../libexec/ttfx` from the physical macarchy executable. There is deliberately no PATH or
  /// environment lookup, so the saver only ever runs the engine its own release shipped.
  static func locate(
    executable: URL, resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() }
  ) -> Self {
    let url = resolve(executable).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "libexec/ttfx").standardizedFileURL
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return Self(url: url, defect: .absent) }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      return Self(url: url, defect: .notRegularFile)
    }
    return Self(url: url, defect: metadata.st_mode & 0o111 == 0 ? .notExecutable : nil)
  }
}

/// The Kitty application that hosts the saver's panels.
enum SaverKitty: Equatable, Sendable {
  case missing
  /// `version` is nil when the application does not name one.
  case present(version: String?)

  static let application = URL(filePath: "/Applications/kitty.app", directoryHint: .isDirectory)
  static let remedy = "Install Kitty with `brew install --cask kitty`."

  static func inspect(application: URL = application) -> Self {
    let contents = application.appending(path: "Contents", directoryHint: .isDirectory)
    guard FileManager.default.isExecutableFile(atPath: contents.appending(path: "MacOS/kitty").path)
    else { return .missing }
    let info = (try? Data(contentsOf: contents.appending(path: "Info.plist"))).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
    return .present(version: info?["CFBundleShortVersionString"] as? String)
  }
}

/// What `macarchy saver status` reports.
struct SaverStatus: Equatable, Sendable {
  let engine: SaverEngine
  let kitty: SaverKitty

  static func inspect(executable: URL) -> Self {
    Self(engine: .locate(executable: executable), kitty: .inspect())
  }

  var message: String {
    let engineLine =
      if let defect = engine.defect {
        "ttfx engine: missing at \(engine.url.path) (\(defect.summary)). \(SaverEngine.remedy)"
      } else {
        "ttfx engine: present at \(engine.url.path)"
      }
    let kittyLine =
      switch kitty {
      case .missing: "Kitty: missing at \(SaverKitty.application.path). \(SaverKitty.remedy)"
      case .present(let version):
        "Kitty: \(version.map { "\($0) " } ?? "")at \(SaverKitty.application.path)"
      }
    return [engineLine, kittyLine, "Screensaver: not running"].joined(separator: "\n")
  }

  func renderJSON() throws -> String {
    var engineDocument: [String: Any] = [
      "path": engine.url.path, "state": "present", "reason": NSNull(), "remedy": NSNull(),
    ]
    if let defect = engine.defect {
      engineDocument["state"] = "missing"
      engineDocument["reason"] = defect.rawValue
      engineDocument["remedy"] = SaverEngine.remedy
    }
    var kittyDocument: [String: Any] = [
      "path": SaverKitty.application.path, "state": "missing", "version": NSNull(),
      "remedy": SaverKitty.remedy,
    ]
    if case .present(let version) = kitty {
      kittyDocument["state"] = "present"
      kittyDocument["remedy"] = NSNull()
      if let version { kittyDocument["version"] = version }
    }
    let document: [String: Any] = [
      "engine": engineDocument, "kitty": kittyDocument, "running": false,
      "sessions": [Any](),
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }
}
