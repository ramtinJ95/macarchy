import Foundation
import ThemeCore

enum SketchyBarCoreRuntimeStatus: String, Codable, Sendable {
  case converged
  case drifted
  case failed
}

struct SketchyBarCoreRuntimeInspection: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let status: SketchyBarCoreRuntimeStatus
  let message: String
  let themeGenerationID: String?
  let barColor: String?
  let items: [String]
  let spaceIndices: [Int]
  let clockLabelPresent: Bool

  init(
    status: SketchyBarCoreRuntimeStatus,
    message: String,
    themeGenerationID: String? = nil,
    barColor: String? = nil,
    items: [String] = [],
    spaceIndices: [Int] = [],
    clockLabelPresent: Bool = false
  ) {
    schemaVersion = 1
    self.status = status
    self.message = message
    self.themeGenerationID = themeGenerationID
    self.barColor = barColor
    self.items = items
    self.spaceIndices = spaceIndices
    self.clockLabelPresent = clockLabelPresent
  }

  var isValidEvidence: Bool {
    guard
      schemaVersion == 1,
      status == .converged,
      themeGenerationID.map(Self.isThemeGenerationID) == true,
      barColor.map(Self.isARGBColor) == true,
      items == items.sorted(),
      Set(items).count == items.count,
      items.count <= 66,
      spaceIndices == spaceIndices.sorted(),
      Set(spaceIndices).count == spaceIndices.count,
      spaceIndices.allSatisfy({ (1...64).contains($0) }),
      clockLabelPresent
    else { return false }
    let expectedCore = ["macarchy.clock", SketchyBarConfigurationComposer.readyItem]
    if items.contains("macarchy.spaces.unavailable") {
      return spaceIndices.isEmpty
        && items == (expectedCore + ["macarchy.spaces.unavailable"]).sorted()
    }
    return !spaceIndices.isEmpty
      && items == (expectedCore + spaceIndices.map { "macarchy.space.\($0)" }).sorted()
  }

  private static func isThemeGenerationID(_ value: String) -> Bool {
    value.hasPrefix("g-")
      && value == value.lowercased()
      && UUID(uuidString: String(value.dropFirst(2))) != nil
  }

  private static func isARGBColor(_ value: String) -> Bool {
    value == value.lowercased() && value.count == 10 && value.hasPrefix("0x")
      && value.dropFirst(2).allSatisfy { $0.isHexDigit }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case status, message
    case themeGenerationID = "theme_generation_id"
    case barColor = "bar_color"
    case items
    case spaceIndices = "space_indices"
    case clockLabelPresent = "clock_label_present"
  }
}

struct SketchyBarCoreRuntimeController: Sendable {
  let inspect: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection
  let settle: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection

  static func live(stateRoot: URL) -> Self {
    let verifier = SketchyBarCoreRuntimeVerifier.live(stateRoot: stateRoot)
    return Self(inspect: verifier.inspect, settle: verifier.settle)
  }
}

struct SketchyBarCoreRuntimeVerifier: Sendable {
  static let controlURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
  static let yabaiURL = URL(filePath: "/opt/homebrew/bin/yabai")

  let stateRoot: URL
  let processRunner: ProcessRunner
  let waitForSettle: @Sendable () -> Void
  let waitForPresentation: @Sendable () -> Void

  static func live(stateRoot: URL) -> Self {
    Self(
      stateRoot: stateRoot,
      processRunner: .live,
      waitForSettle: { Thread.sleep(forTimeInterval: 0.05) },
      waitForPresentation: { Thread.sleep(forTimeInterval: 0.25) }
    )
  }

  init(
    stateRoot: URL,
    processRunner: ProcessRunner,
    waitForSettle: @escaping @Sendable () -> Void,
    waitForPresentation: @escaping @Sendable () -> Void
  ) {
    self.stateRoot = stateRoot.standardizedFileURL
    self.processRunner = processRunner
    self.waitForSettle = waitForSettle
    self.waitForPresentation = waitForPresentation
  }

  func inspect(_ composition: SketchyBarComposition) -> SketchyBarCoreRuntimeInspection {
    do {
      return try probe(composition)
    } catch {
      return failed(error)
    }
  }

  func settle(_ composition: SketchyBarComposition) -> SketchyBarCoreRuntimeInspection {
    var lastDrift: SketchyBarCoreRuntimeInspection?
    var lastTimeout: ProcessRunnerError?
    for attempt in 0..<11 {
      do {
        let inspection = try probe(composition)
        if inspection.status == .converged {
          waitForPresentation()
          return inspection
        }
        lastDrift = inspection
      } catch let error as ProcessRunnerError {
        guard
          case .timedOut(let executableURL, _) = error,
          executableURL == Self.controlURL
        else {
          return failed(error)
        }
        lastTimeout = error
      } catch {
        return failed(error)
      }
      if attempt < 10 { waitForSettle() }
    }
    if let lastDrift { return lastDrift }
    return SketchyBarCoreRuntimeInspection(
      status: .failed,
      message:
        "SketchyBar queries timed out through the bounded settle window: \(String(describing: lastTimeout))"
    )
  }

  private func probe(
    _ composition: SketchyBarComposition
  ) throws -> SketchyBarCoreRuntimeInspection {
    let palette = try activePalette()
    let spaceIndices = try expectedSpaceIndices(composition.spaceModule)
    let expectedItems = expectedItemNames(
      spaceModule: composition.spaceModule,
      spaceIndices: spaceIndices
    )
    let bar: SketchyBarBarQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", "bar"],
      timeout: 0.1
    )
    let items = bar.items.sorted()
    guard
      bar.drawing == "on",
      bar.color.lowercased() == palette.color,
      bar.position == composition.settings.position,
      bar.height == composition.settings.height,
      bar.margin == composition.settings.margin,
      bar.cornerRadius == composition.settings.cornerRadius,
      items == expectedItems
    else {
      return drifted(
        "running SketchyBar bar state does not match the selected managed generation",
        palette: palette,
        items: items,
        spaceIndices: spaceIndices
      )
    }

    let clock: SketchyBarItemQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", "macarchy.clock"],
      timeout: 0.1
    )
    let expectedClockScript = stateRoot.appending(
      path: "desktop/sketchybar/current/plugins/clock.sh"
    ).path
    let clockLabel = clock.label.value
    guard
      clock.name == "macarchy.clock",
      clock.type == "item",
      clock.geometry.drawing == "on",
      clock.geometry.position == "right",
      clock.label.drawing == "on",
      !clockLabel.isEmpty,
      clock.scripting.script == expectedClockScript,
      clock.scripting.updateFrequency == 30
    else {
      return drifted(
        "running SketchyBar clock is incomplete or uses an unexpected script",
        palette: palette,
        items: items,
        spaceIndices: spaceIndices,
        clockLabelPresent: !clockLabel.isEmpty
      )
    }

    let ready: SketchyBarItemQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", SketchyBarConfigurationComposer.readyItem],
      timeout: 0.1
    )
    guard
      ready.name == SketchyBarConfigurationComposer.readyItem,
      ready.type == "item",
      ready.geometry.drawing == "off",
      ready.geometry.position == "right"
    else {
      return drifted(
        "running SketchyBar ready marker is missing or visible",
        palette: palette,
        items: items,
        spaceIndices: spaceIndices,
        clockLabelPresent: true
      )
    }

    if composition.spaceModule == .disabledWithoutDesktop {
      let fallback: SketchyBarItemQuery = try query(
        control: Self.controlURL,
        arguments: ["--query", "macarchy.spaces.unavailable"],
        timeout: 0.1
      )
      guard
        fallback.name == "macarchy.spaces.unavailable",
        fallback.type == "item",
        fallback.geometry.drawing == "on",
        fallback.geometry.position == "left",
        fallback.label.drawing == "on",
        fallback.label.value == "Spaces unavailable"
      else {
        return drifted(
          "running SketchyBar does not expose the disabled desktop Space state",
          palette: palette,
          items: items,
          spaceIndices: spaceIndices,
          clockLabelPresent: true
        )
      }
    }

    return SketchyBarCoreRuntimeInspection(
      status: .converged,
      message: "running SketchyBar matches the selected provider and canonical theme generations",
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: true
    )
  }

  private func activePalette() throws -> (generationID: String, color: String) {
    let manifest = try ReconciliationStatusStore(root: stateRoot).activeManifest()
    guard
      manifest.rendererVersions[SketchyBarConfigurationComposer.providerID, default: 0] >= 2,
      manifest.artifacts[SketchyBarConfigurationComposer.paletteArtifactPath] != nil
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the active theme does not contain the managed SketchyBar shell palette"
      )
    }
    let paletteURL = stateRoot.appending(
      path: "current/\(SketchyBarConfigurationComposer.paletteArtifactPath)"
    )
    let text = try BoundedRegularFile.readUTF8(at: paletteURL, maximumSize: 65_536)
    let values = text.split(separator: "\n").compactMap { line -> String? in
      let prefix = "MACARCHY_BAR_COLOR="
      return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }
    guard
      values.count == 1,
      values[0].count == 10,
      values[0].hasPrefix("0x"),
      values[0].dropFirst(2).allSatisfy({ $0.isHexDigit })
    else {
      throw SketchyBarDesktopError.lifecycle(
        "the active SketchyBar shell palette has an invalid bar color"
      )
    }
    return (manifest.generationID, values[0].lowercased())
  }

  private func expectedSpaceIndices(_ module: SketchyBarSpaceModule) throws -> [Int] {
    guard module == .dynamicYabai else { return [] }
    let spaces: [YabaiSpaceQuery] = try query(
      control: Self.yabaiURL,
      arguments: ["-m", "query", "--spaces"],
      timeout: 0.5
    )
    let indices = spaces.map(\.index).sorted()
    guard
      !indices.isEmpty,
      indices.count <= 64,
      Set(indices).count == indices.count,
      indices.allSatisfy({ (1...64).contains($0) })
    else {
      throw SketchyBarDesktopError.lifecycle("yabai returned an invalid Space inventory")
    }
    return indices
  }

  private func expectedItemNames(
    spaceModule: SketchyBarSpaceModule,
    spaceIndices: [Int]
  ) -> [String] {
    var names = ["macarchy.clock", SketchyBarConfigurationComposer.readyItem]
    switch spaceModule {
    case .dynamicYabai:
      names += spaceIndices.map { "macarchy.space.\($0)" }
    case .disabledWithoutDesktop:
      names.append("macarchy.spaces.unavailable")
    }
    return names.sorted()
  }

  private func query<Value: Decodable>(
    control: URL,
    arguments: [String],
    timeout: TimeInterval
  ) throws -> Value {
    let result = try processRunner.run(
      ProcessRequest(executableURL: control, arguments: arguments, timeout: timeout)
    )
    guard result.terminationStatus == 0 else {
      throw SketchyBarDesktopError.lifecycle(
        result.output.isEmpty
          ? "\(control.lastPathComponent) rejected \(arguments.joined(separator: " "))"
          : result.output
      )
    }
    do {
      return try JSONDecoder().decode(Value.self, from: Data(result.output.utf8))
    } catch {
      throw SketchyBarDesktopError.lifecycle(
        "cannot decode \(control.lastPathComponent) runtime state: \(error)"
      )
    }
  }

  private func drifted(
    _ message: String,
    palette: (generationID: String, color: String),
    items: [String],
    spaceIndices: [Int],
    clockLabelPresent: Bool = false
  ) -> SketchyBarCoreRuntimeInspection {
    SketchyBarCoreRuntimeInspection(
      status: .drifted,
      message: message,
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: clockLabelPresent
    )
  }

  private func failed(_ error: any Error) -> SketchyBarCoreRuntimeInspection {
    SketchyBarCoreRuntimeInspection(status: .failed, message: String(describing: error))
  }
}

private struct SketchyBarBarQuery: Decodable {
  let position: String
  let drawing: String
  let color: String
  let height: Int
  let margin: Int
  let cornerRadius: Int
  let items: [String]

  enum CodingKeys: String, CodingKey {
    case position, drawing, color, height, margin, items
    case cornerRadius = "corner_radius"
  }
}

private struct SketchyBarItemQuery: Decodable {
  struct Geometry: Decodable {
    let drawing: String
    let position: String
  }

  struct Label: Decodable {
    let value: String
    let drawing: String
  }

  struct Scripting: Decodable {
    let script: String
    let updateFrequency: Int

    enum CodingKeys: String, CodingKey {
      case script
      case updateFrequency = "update_freq"
    }
  }

  let name: String
  let type: String
  let geometry: Geometry
  let label: Label
  let scripting: Scripting
}

private struct YabaiSpaceQuery: Decodable {
  let index: Int
}
