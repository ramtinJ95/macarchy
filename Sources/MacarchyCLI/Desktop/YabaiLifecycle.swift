import Darwin
import Foundation
import ThemeCore

enum YabaiRuntimeStatus: String, Codable, Sendable {
  case disabled
  case converged
  case partial
  case stopped
  case drifted
  case blocked
}

struct YabaiRuntimeInspection: Codable, Equatable, Sendable {
  let status: YabaiRuntimeStatus
  let message: String
  let verifiedSettings: [String]
  let verifiedRuleLabels: [String]
  let wallpaperSignalVerified: Bool
  let processID: Int32?
  let executablePath: String?

  enum CodingKeys: String, CodingKey {
    case status, message
    case verifiedSettings = "verified_settings"
    case verifiedRuleLabels = "verified_rule_labels"
    case wallpaperSignalVerified = "wallpaper_signal_verified"
    case processID = "process_id"
    case executablePath = "executable_path"
  }

  static let stopped = Self(
    status: .stopped,
    message: "yabai is not running",
    verifiedSettings: [],
    verifiedRuleLabels: [],
    wallpaperSignalVerified: false,
    processID: nil,
    executablePath: nil
  )

  static let disabled = Self(
    status: .disabled,
    message: "desktop role is disabled; yabai runtime was not inspected",
    verifiedSettings: [],
    verifiedRuleLabels: [],
    wallpaperSignalVerified: false,
    processID: nil,
    executablePath: nil
  )

  func agreesWithCurrentProcess(_ current: Self) -> Bool {
    status == current.status
      && message == current.message
      && verifiedSettings == current.verifiedSettings
      && verifiedRuleLabels == current.verifiedRuleLabels
      && wallpaperSignalVerified == current.wallpaperSignalVerified
      && executablePath == current.executablePath
  }
}

enum YabaiAccessibilityEvidence: Equatable, Sendable {
  case available
  case unavailable
  case unobservable
}

struct YabaiLifecycleController: Sendable {
  let preflight: @Sendable () throws -> Bool
  let restart: @Sendable () throws -> Void
  let stop: @Sendable () throws -> Void
  let inspect: @Sendable (YabaiComposition) -> YabaiRuntimeInspection
  let waitBetweenInspections: @Sendable () -> Void

  static let live = YabaiLifecycleController(
    preflight: {
      let executable = URL(filePath: "/opt/homebrew/bin/yabai")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw YabaiDesktopError.lifecycle("supported yabai is unavailable at \(executable.path)")
      }
      let version = try run(arguments: ["--version"])
      guard version.terminationStatus == 0, version.output.hasPrefix("yabai-v7.") else {
        throw YabaiDesktopError.lifecycle(
          "unsupported yabai version: \(version.output.isEmpty ? "no version reported" : version.output)"
        )
      }
      guard try processEvidence() != nil else { return false }
      guard runtimeReady() else {
        throw YabaiDesktopError.lifecycle(
          "the running yabai process cannot query Spaces; grant the documented Accessibility prerequisite before apply"
        )
      }
      try requireAccessibilityEvidence()
      return true
    },
    restart: {
      try requireSuccess(arguments: ["--restart-service"], operation: "restart service")
      guard runtimeReady() else {
        throw YabaiDesktopError.lifecycle("yabai did not become queryable after restart")
      }
      guard accessibilityReady() else {
        throw YabaiDesktopError.lifecycle(
          "yabai has no Accessibility references after restart; grant the documented Accessibility prerequisite before apply"
        )
      }
    },
    stop: { try requireSuccess(arguments: ["--stop-service"], operation: "stop service") },
    inspect: inspectLive,
    waitBetweenInspections: { Thread.sleep(forTimeInterval: 0.1) }
  )

  func inspectAfterRestart(_ composition: YabaiComposition) -> YabaiRuntimeInspection {
    var result = inspect(composition)
    for _ in 1..<20 where result.status != .converged && result.status != .partial {
      waitBetweenInspections()
      result = inspect(composition)
    }
    return result
  }

  func restoreService(wasRunning: Bool) throws {
    if wasRunning { try restart() } else { try stop() }
  }

  private static func inspectLive(_ composition: YabaiComposition) -> YabaiRuntimeInspection {
    var expected: [(String, String)] = [
      ("layout", composition.settings.layout),
      ("window_placement", composition.settings.windowPlacement),
      ("window_insertion_point", composition.settings.windowInsertionPoint),
      ("auto_balance", composition.settings.autoBalance ? "on" : "off"),
      ("split_ratio", String(composition.settings.splitRatio)),
      ("top_padding", String(composition.settings.topPadding)),
      ("bottom_padding", String(composition.settings.bottomPadding)),
      ("left_padding", String(composition.settings.leftPadding)),
      ("right_padding", String(composition.settings.rightPadding)),
      ("window_gap", String(composition.settings.windowGap)),
      ("mouse_follows_focus", composition.settings.mouseFollowsFocus ? "on" : "off"),
      ("mouse_modifier", composition.settings.mouseModifier),
      ("mouse_action1", composition.settings.mouseAction1),
      ("mouse_action2", composition.settings.mouseAction2),
    ]
    if composition.externalBarEnabled {
      expected.append(
        ("external_bar", "all:\(composition.settings.externalBarHeight):0")
      )
    }
    var verified: [String] = []
    do {
      guard let process = try settledProcessEvidence() else { return .stopped }
      try requireAccessibilityEvidence()
      for (name, value) in expected {
        let result = try run(arguments: ["-m", "config", name])
        guard result.terminationStatus == 0 else {
          if verified.isEmpty { return .stopped }
          return drifted("cannot query yabai setting \(name)", verified: verified)
        }
        guard settingValue(result.output, matches: value, name: name) else {
          return drifted(
            "yabai setting \(name) is \(result.output), expected \(value)",
            verified: verified
          )
        }
        verified.append(name)
      }

      let rules = try run(arguments: ["-m", "rule", "--list"])
      guard rules.terminationStatus == 0 else {
        return drifted("cannot query yabai rules", verified: verified)
      }
      guard
        let observedRules = try JSONSerialization.jsonObject(with: Data(rules.output.utf8))
          as? [[String: Any]]
      else {
        return drifted("yabai returned invalid rule evidence", verified: verified)
      }
      let missingRules = composition.settings.rules.filter { expected in
        !observedRules.contains { observed in
          ruleField(expected.label, key: "label", observed: observed)
            && ruleField(expected.app, key: "app", observed: observed)
            && ruleField(expected.title, key: "title", observed: observed)
            && ruleField(expected.role, key: "role", observed: observed)
            && ruleField(expected.subrole, key: "subrole", observed: observed)
        }
      }
      guard missingRules.isEmpty else {
        return drifted(
          "one or more packaged yabai rules are missing",
          verified: verified
        )
      }
      let requiredLabels = composition.settings.rules.compactMap { $0.label ?? $0.app }.sorted()

      let signals = try run(arguments: ["-m", "signal", "--list"])
      guard
        signals.terminationStatus == 0,
        signals.output.contains("macarchy-wallpaper"),
        signals.output.contains("space_changed")
      else {
        return drifted(
          "the canonical wallpaper space_changed signal is missing", verified: verified)
      }
      let partial = composition.hookURL != nil
      return YabaiRuntimeInspection(
        status: partial ? .partial : .converged,
        message: partial
          ? "packaged settings, rules, and wallpaper signal are verified; the trusted hook may add behavior Macarchy cannot fully inspect"
          : "packaged settings, rules, and wallpaper signal are verified",
        verifiedSettings: verified,
        verifiedRuleLabels: requiredLabels,
        wallpaperSignalVerified: true,
        processID: process.processID,
        executablePath: process.executablePath
      )
    } catch {
      return YabaiRuntimeInspection(
        status: .blocked,
        message: "cannot inspect yabai runtime: \(error)",
        verifiedSettings: verified,
        verifiedRuleLabels: [],
        wallpaperSignalVerified: false,
        processID: nil,
        executablePath: nil
      )
    }
  }

  private static func run(
    arguments: [String],
    timeout: TimeInterval = 5
  ) throws -> ProcessResult {
    try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/opt/homebrew/bin/yabai"),
        arguments: arguments,
        timeout: timeout
      )
    )
  }

  private static func requireSuccess(arguments: [String], operation: String) throws {
    let result = try run(arguments: arguments, timeout: 15)
    guard result.terminationStatus == 0 else {
      throw YabaiDesktopError.lifecycle(
        "\(operation) exited with status \(result.terminationStatus): \(result.output.isEmpty ? "no output" : result.output)"
      )
    }
  }

  private static func processEvidence() throws -> (processID: Int32, executablePath: String)? {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-u", String(getuid()), "-x", "yabai"],
        timeout: 2
      )
    )
    if result.terminationStatus == 1 { return nil }
    guard result.terminationStatus == 0 else {
      throw YabaiDesktopError.lifecycle("cannot inspect the yabai process identity")
    }
    let processIDs = result.output.split(whereSeparator: \.isNewline).compactMap {
      Int32($0.trimmingCharacters(in: .whitespaces))
    }
    guard processIDs.count == 1, let processID = processIDs.first else {
      throw YabaiDesktopError.lifecycle(
        "expected one UID-scoped yabai process; found \(processIDs.count)"
      )
    }
    var pathBuffer = [CChar](repeating: 0, count: 4_096)
    guard proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
      throw YabaiDesktopError.lifecycle("cannot resolve yabai PID \(processID)")
    }
    let path = String(
      decoding: pathBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )
    let supportedPath = URL(filePath: "/opt/homebrew/bin/yabai")
      .resolvingSymlinksInPath().path
    guard path == supportedPath else {
      throw YabaiDesktopError.lifecycle(
        "yabai PID \(processID) uses unsupported executable \(path)"
      )
    }
    return (processID, path)
  }

  private static func runtimeReady() -> Bool {
    for _ in 0..<100 {
      if (try? processEvidence()) != nil {
        if let query = try? run(arguments: ["-m", "query", "--spaces"], timeout: 0.5),
          query.terminationStatus == 0
        {
          return true
        }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return false
  }

  static func accessibilityEvidence(from output: String) throws -> YabaiAccessibilityEvidence {
    guard
      let windows = try JSONSerialization.jsonObject(with: Data(output.utf8))
        as? [[String: Any]]
    else {
      throw YabaiDesktopError.lifecycle("yabai returned invalid Accessibility evidence")
    }
    guard !windows.isEmpty else { return .unobservable }
    return windows.contains { $0["has-ax-reference"] as? Bool == true }
      ? .available : .unavailable
  }

  private static func accessibilityReady() -> Bool {
    for attempt in 0..<100 {
      if let result = try? run(arguments: ["-m", "query", "--windows"], timeout: 0.5),
        result.terminationStatus == 0,
        let evidence = try? accessibilityEvidence(from: result.output),
        evidence == .available
      {
        return true
      }
      if attempt < 99 { Thread.sleep(forTimeInterval: 0.1) }
    }
    return false
  }

  private static func requireAccessibilityEvidence() throws {
    let result = try run(arguments: ["-m", "query", "--windows"])
    guard result.terminationStatus == 0 else {
      throw YabaiDesktopError.lifecycle("cannot inspect yabai Accessibility evidence")
    }
    switch try accessibilityEvidence(from: result.output) {
    case .available:
      return
    case .unavailable:
      throw YabaiDesktopError.lifecycle(
        "yabai has no Accessibility references; grant the documented Accessibility prerequisite before apply"
      )
    case .unobservable:
      throw YabaiDesktopError.lifecycle(
        "yabai Accessibility cannot be verified without an ordinary application window"
      )
    }
  }

  private static func settledProcessEvidence() throws -> (
    processID: Int32, executablePath: String
  )? {
    var lastError: (any Error)?
    for attempt in 0..<20 {
      do {
        return try processEvidence()
      } catch {
        lastError = error
      }
      if attempt < 19 { Thread.sleep(forTimeInterval: 0.1) }
    }
    throw lastError!
  }

  private static func ruleField(
    _ expected: String?,
    key: String,
    observed: [String: Any]
  ) -> Bool {
    expected.map { observed[key] as? String == $0 } ?? true
  }

  private static func settingValue(
    _ observed: String,
    matches expected: String,
    name: String
  ) -> Bool {
    if name == "split_ratio", let observedValue = Double(observed),
      let expectedValue = Double(expected)
    {
      return abs(observedValue - expectedValue) < 0.000_001
    }
    return observed == expected
  }

  private static func drifted(
    _ message: String,
    verified: [String]
  ) -> YabaiRuntimeInspection {
    YabaiRuntimeInspection(
      status: .drifted,
      message: message,
      verifiedSettings: verified,
      verifiedRuleLabels: [],
      wallpaperSignalVerified: false,
      processID: nil,
      executablePath: nil
    )
  }

}

struct YabaiLifecycleEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let generationID: String
  let runtime: YabaiRuntimeInspection

  init(generationID: String, runtime: YabaiRuntimeInspection) {
    schemaVersion = 1
    self.generationID = generationID
    self.runtime = runtime
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generationID = "generation_id"
    case runtime
  }
}

struct YabaiLifecycleEvidenceStore: Sendable {
  let stateRoot: URL

  private var directory: URL {
    stateRoot.appending(path: "desktop/yabai", directoryHint: .isDirectory)
  }

  private var file: URL { directory.appending(path: "lifecycle.json") }

  func read() throws -> YabaiLifecycleEvidence? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let data = try BoundedRegularFile.read(at: file, maximumSize: 32_768).data
    let evidence = try JSONDecoder().decode(YabaiLifecycleEvidence.self, from: data)
    guard
      evidence.schemaVersion == 1,
      YabaiGenerationInspector.isGenerationID(evidence.generationID)
    else {
      throw YabaiDesktopError.invalidState("yabai lifecycle evidence is invalid")
    }
    return evidence
  }

  func write(_ evidence: YabaiLifecycleEvidence) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: file, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
