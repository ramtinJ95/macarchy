import Darwin
import Foundation

/// A macOS accent color preset, as the system stores it in `AppleAccentColor`.
package enum MacOSAccent: Int, CaseIterable, Codable, Sendable {
  /// The color matched to the Mac's enclosure on some models. Reported, never set.
  case hardware = -3
  case multicolor = -2
  case graphite = -1
  case red = 0
  case orange = 1
  case yellow = 2
  case green = 3
  case blue = 4
  case purple = 5
  case pink = 6

  package var name: String {
    switch self {
    case .hardware: "hardware-matched"
    case .multicolor: "multicolor"
    case .graphite: "graphite"
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .blue: "blue"
    case .purple: "purple"
    case .pink: "pink"
    }
  }

  /// Whether the helper may set this preset.
  package var isSettable: Bool { self != .hardware }

  /// The preset nearest `color` by hue; washed-out, near-black and near-white colors map to
  /// graphite. The buckets follow Scene (MIT, Copyright (c) 2026 InsaneArts).
  package static func nearest(to color: SRGBColor) -> Self {
    let (hue, saturation, lightness) = hsl(color)
    if saturation < 0.15 || lightness < 0.08 || lightness > 0.95 { return .graphite }
    switch hue {
    case 15..<40: return .orange
    case 40..<65: return .yellow
    case 65..<165: return .green
    case 165..<255: return .blue
    case 255..<290: return .purple
    case 290..<345: return .pink
    default: return .red
    }
  }

  /// Hue in degrees 0..<360, saturation and lightness in 0...1.
  static func hsl(_ color: SRGBColor) -> (Double, Double, Double) {
    let (red, green, blue) = color.components
    let maximum = max(red, green, blue)
    let minimum = min(red, green, blue)
    let lightness = (maximum + minimum) / 2
    let delta = maximum - minimum
    guard delta > 0 else { return (0, 0, lightness) }
    let saturation = delta / (1 - abs(2 * lightness - 1))
    var hue: Double
    switch maximum {
    case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
    case green: hue = (blue - red) / delta + 2
    default: hue = (red - green) / delta + 4
    }
    hue *= 60
    if hue < 0 { hue += 360 }
    return (hue, saturation, lightness)
  }
}

/// The macOS builds on which each look control was observed to set, read back and repaint.
/// Every other build reports the control unsupported; there is no override.
package enum MacOSLookSupport {
  package static let testedIconStyleBuilds: Set<String> = ["25G83"]
  package static let testedAccentBuilds: Set<String> = ["25G83"]
}

package enum MacOSLookError: Error, CustomStringConvertible, Equatable, Sendable {
  case helperMissing(String)
  case untestedBuild(String)
  case unavailable(String)
  case helperFailed(String)
  case unreadableReply(String)

  package var description: String {
    switch self {
    case .helperMissing(let path):
      "the macOS look helper is missing or not executable at \(path); install a Macarchy release containing macarchy-look beside macarchy; source builds must also build macarchy-look"
    case .untestedBuild(let build):
      "macOS build \(build) is not one Macarchy has tested this look control on; it is left unchanged"
    case .unavailable(let reason): reason
    case .helperFailed(let reason): "the macOS look helper failed: \(reason)"
    case .unreadableReply(let output):
      "the macOS look helper gave an unreadable reply: \(output.isEmpty ? "no output" : output)"
    }
  }
}

/// Runs the sibling `macarchy-look` helper, the only code that touches the private accent API.
/// Each call is a separate short process with a time limit, so the helper failing, hanging or
/// crashing becomes an error here and nothing more.
package struct MacOSLookHelper: Sendable {
  package static let executableName = "macarchy-look"
  package static let timeout: TimeInterval = 20

  package struct Capabilities: Equatable, Sendable {
    package let build: String
    package let accent: Bool
    package var iconStyle: Bool = false
  }

  let executableURL: URL
  let processRunner: ProcessRunner

  package init(executableURL: URL, processRunner: ProcessRunner = .live) {
    self.executableURL = executableURL
    self.processRunner = processRunner
  }

  /// The helper beside the running `macarchy` executable.
  package static func sibling(processRunner: ProcessRunner = .live) -> Self {
    let executable = MacarchyCommandPath.currentExecutableURL.resolvingSymlinksInPath()
    return Self(
      executableURL: executable.deletingLastPathComponent().appending(path: executableName),
      processRunner: processRunner)
  }

  package func check() throws -> Capabilities {
    let value = try call(["check"])
    guard let object = value as? [String: Any], let build = object["build"] as? String,
      let accent = object["accent"] as? Bool
    else { throw MacOSLookError.unreadableReply(String(describing: value)) }
    return Capabilities(
      build: build, accent: accent, iconStyle: object["iconStyle"] as? Bool ?? false)
  }

  /// The accent the system stores now.
  package func accent() throws -> MacOSAccent {
    try accent(from: call(["get", "accent"]))
  }

  /// Sets `accent`; the helper reads it back and reverts on a mismatch.
  package func setAccent(_ accent: MacOSAccent) throws -> MacOSAccent {
    try self.accent(from: call(["set", "accent", String(accent.rawValue)]))
  }

  /// Fails unless the helper exists, this build is tested and the accent functions resolve.
  package func requireAccentSupport(testedBuilds: Set<String> = MacOSLookSupport.testedAccentBuilds)
    throws
  {
    let capabilities = try check()
    guard testedBuilds.contains(capabilities.build) else {
      throw MacOSLookError.untestedBuild(capabilities.build)
    }
    guard capabilities.accent else {
      throw MacOSLookError.unavailable(
        "the accent color functions are unavailable on macOS build \(capabilities.build)")
    }
  }

  package func requireIconStyleSupport(
    testedBuilds: Set<String> = MacOSLookSupport.testedIconStyleBuilds
  ) throws {
    let capabilities = try check()
    guard testedBuilds.contains(capabilities.build) else {
      throw MacOSLookError.untestedBuild(capabilities.build)
    }
    guard capabilities.iconStyle else {
      throw MacOSLookError.unavailable(
        "the icon & widget style functions are unavailable on macOS build \(capabilities.build)")
    }
  }

  package func iconStyle() throws -> MacOSIconStyle {
    try iconStyle(from: call(["get", "icon-style"]))
  }

  package func setIconStyle(_ value: MacOSIconStyle) throws -> MacOSIconStyle {
    try iconStyle(
      from: call(
        ["set", "icon-style", value.style, value.tint] + (value.custom.map { [$0] } ?? [])))
  }

  private func iconStyle(from value: Any) throws -> MacOSIconStyle {
    guard let object = value as? [String: Any],
      let style = object["style"] as? String, let tint = object["tint"] as? String,
      object["custom"] is NSNull || object["custom"] is String
    else { throw MacOSLookError.unreadableReply(String(describing: value)) }
    let state = MacOSIconStyle(
      style: style, tint: tint, custom: (object["custom"] as? String)?.lowercased())
    guard state.isValidStoredValue else {
      throw MacOSLookError.unreadableReply(String(describing: value))
    }
    return state
  }

  private func accent(from value: Any) throws -> MacOSAccent {
    guard let raw = value as? Int, let accent = MacOSAccent(rawValue: raw) else {
      throw MacOSLookError.unreadableReply(String(describing: value))
    }
    return accent
  }

  private func call(_ arguments: [String]) throws -> Any {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw MacOSLookError.helperMissing(executableURL.path)
    }
    let result = try processRunner.run(
      ProcessRequest(executableURL: executableURL, arguments: arguments, timeout: Self.timeout))
    // Standard error shares the output; the reply is the last line.
    let line = result.output.split(separator: "\n").last.map(String.init) ?? ""
    guard
      let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let ok = reply["ok"] as? Bool
    else {
      throw result.terminationStatus == 0
        ? MacOSLookError.unreadableReply(result.output)
        : MacOSLookError.helperFailed(
          "exited with status \(result.terminationStatus)"
            + (result.output.isEmpty ? "" : ": \(result.output.prefix(200))"))
    }
    guard ok, result.terminationStatus == 0, let value = reply["value"] else {
      throw MacOSLookError.helperFailed(
        reply["error"] as? String ?? "exited with status \(result.terminationStatus)")
    }
    return value
  }
}

package struct MacOSLookRestore: Sendable {
  package let message: String?
  package let mutated: Bool
  package let consumesRecord: Bool
}
