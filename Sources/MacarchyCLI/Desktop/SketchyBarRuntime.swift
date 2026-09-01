import Foundation
import ThemeCore

enum SketchyBarCoreRuntimeStatus: String, Codable, Sendable {
  case converged
  case partial
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
  let volumeLevelPresent: Bool?

  init(
    status: SketchyBarCoreRuntimeStatus,
    message: String,
    themeGenerationID: String? = nil,
    barColor: String? = nil,
    items: [String] = [],
    spaceIndices: [Int] = [],
    clockLabelPresent: Bool = false,
    volumeLevelPresent: Bool = false
  ) {
    schemaVersion = 1
    self.status = status
    self.message = message
    self.themeGenerationID = themeGenerationID
    self.barColor = barColor
    self.items = items
    self.spaceIndices = spaceIndices
    self.clockLabelPresent = clockLabelPresent
    self.volumeLevelPresent = volumeLevelPresent
  }

  var isValidEvidence: Bool {
    guard
      schemaVersion == 1,
      status == .converged || status == .partial,
      themeGenerationID.map(Self.isThemeGenerationID) == true,
      barColor.map(Self.isARGBColor) == true,
      items == items.sorted(),
      Set(items).count == items.count,
      items.count <= 64,
      items.allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 128
          && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }),
      spaceIndices == spaceIndices.sorted(),
      Set(spaceIndices).count == spaceIndices.count,
      spaceIndices.allSatisfy({ (1..<UInt32.bitWidth).contains($0) })
    else { return false }
    let hasClock = items.contains("macarchy.clock")
    guard hasClock == clockLabelPresent else { return false }
    let hasVolume = items.contains("macarchy.volume")
    guard hasVolume == (volumeLevelPresent ?? false) else { return false }
    var managedItems = [SketchyBarConfigurationComposer.readyItem]
    if hasClock { managedItems.append("macarchy.clock") }
    if hasVolume { managedItems.append("macarchy.volume") }
    if items.contains("macarchy.spaces.unavailable") {
      guard spaceIndices.isEmpty else { return false }
      managedItems.append("macarchy.spaces.unavailable")
    } else {
      managedItems += spaceIndices.map { "macarchy.space.\($0)" }
    }
    managedItems.sort()
    if status == .converged { return items == managedItems }
    return Set(managedItems).isSubset(of: items)
      && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(managedItems.contains)
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
    case volumeLevelPresent = "volume_level_present"
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
    var lastFailure: (any Error)?
    for attempt in 0..<11 {
      do {
        let inspection = try probe(composition)
        if inspection.status == .converged || inspection.status == .partial {
          waitForPresentation()
          return inspection
        }
        lastDrift = inspection
      } catch let error as ProcessRunnerError {
        if composition.hookURL != nil {
          lastFailure = error
        } else {
          guard
            case .timedOut(let executableURL, _) = error,
            executableURL == Self.controlURL
          else {
            return failed(error)
          }
          lastTimeout = error
        }
      } catch {
        guard composition.hookURL != nil else { return failed(error) }
        lastFailure = error
      }
      if attempt < 10 {
        // The hook runner exits within three seconds; do not roll back while it can still mutate.
        for _ in 0..<(composition.hookURL == nil ? 1 : 10) {
          waitForSettle()
        }
      }
    }
    if let lastFailure { return failed(lastFailure) }
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
      layout: composition.layout,
      spaceModule: composition.spaceModule,
      spaceIndices: spaceIndices
    )
    let bar: SketchyBarBarQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", "bar"],
      timeout: 0.1
    )
    let items = bar.items.sorted()
    let inventoryMatches =
      if composition.hookURL == nil {
        items == expectedItems
      } else {
        Set(items).count == items.count
          && expectedItems.allSatisfy(items.contains)
          && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(expectedItems.contains)
      }
    guard
      bar.drawing == "on",
      bar.color.lowercased() == palette.color,
      bar.position == composition.settings.position,
      bar.height == composition.settings.height,
      bar.margin == composition.settings.margin,
      bar.cornerRadius == composition.settings.cornerRadius,
      inventoryMatches
    else {
      return drifted(
        "running SketchyBar bar state does not match the selected managed generation",
        palette: palette,
        items: items,
        spaceIndices: spaceIndices
      )
    }

    var clockLabelPresent = false
    if let clockPosition = composition.layout.position(of: .clock) {
      let clock: SketchyBarItemQuery = try query(
        control: Self.controlURL,
        arguments: ["--query", "macarchy.clock"],
        timeout: 0.1
      )
      let expectedClockScript = stateRoot.appending(
        path: "desktop/sketchybar/current/plugins/clock.sh"
      ).path
      let clockLabel = clock.label.value
      clockLabelPresent = !clockLabel.isEmpty
      guard
        clock.name == "macarchy.clock",
        clock.type == "item",
        clock.geometry.drawing == "on",
        clock.geometry.position == clockPosition.rawValue,
        clock.label.drawing == "on",
        clockLabelPresent,
        clock.scripting.script == expectedClockScript,
        clock.scripting.updateFrequency == 30
      else {
        return drifted(
          "running SketchyBar clock is incomplete, misplaced, or uses an unexpected script",
          palette: palette,
          items: items,
          spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent
        )
      }
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
        clockLabelPresent: clockLabelPresent
      )
    }

    if composition.spaceModule == .disabledWithoutDesktop {
      let expectedPosition = composition.layout.position(of: .spaces)!
      let fallback: SketchyBarItemQuery = try query(
        control: Self.controlURL,
        arguments: ["--query", "macarchy.spaces.unavailable"],
        timeout: 0.1
      )
      guard
        fallback.name == "macarchy.spaces.unavailable",
        fallback.type == "item",
        fallback.geometry.drawing == "on",
        fallback.geometry.position == expectedPosition.rawValue,
        fallback.label.drawing == "on",
        fallback.label.value == "Spaces unavailable"
      else {
        return drifted(
          "running SketchyBar does not expose the disabled desktop Space state",
          palette: palette,
          items: items,
          spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent
        )
      }
    } else if composition.spaceModule == .dynamicYabai {
      let expectedPosition = composition.layout.position(of: .spaces)!
      for index in spaceIndices {
        let name = "macarchy.space.\(index)"
        let space: SketchyBarItemQuery
        do {
          space = try query(
            control: Self.controlURL,
            arguments: ["--query", name],
            timeout: 0.1
          )
        } catch SketchyBarDesktopError.lifecycle(let message) {
          let missing = "[!] Query: Invalid query, or item '\(name)' not found"
          guard message.trimmingCharacters(in: .whitespacesAndNewlines) == missing else {
            throw SketchyBarDesktopError.lifecycle(message)
          }
          return drifted(
            "running SketchyBar Space inventory changed during verification",
            palette: palette,
            items: items,
            spaceIndices: spaceIndices,
            clockLabelPresent: clockLabelPresent
          )
        }
        let expectedAssociation = UInt32(1) << UInt32(index)
        let expectedClickScript = "\(Self.yabaiURL.path) -m space --focus \(index)"
        guard
          space.name == name,
          space.type == "space",
          space.geometry.drawing == "on",
          space.geometry.position == expectedPosition.rawValue,
          space.geometry.associatedSpaceMask == expectedAssociation,
          space.scripting.clickScript == expectedClickScript
        else {
          return drifted(
            "running SketchyBar Spaces are incomplete or misplaced",
            palette: palette,
            items: items,
            spaceIndices: spaceIndices,
            clockLabelPresent: clockLabelPresent
          )
        }
      }
      let finalSpaceIndices = try expectedSpaceIndices(.dynamicYabai)
      guard finalSpaceIndices == spaceIndices else {
        return drifted(
          "running SketchyBar Space inventory changed during verification",
          palette: palette,
          items: items,
          spaceIndices: finalSpaceIndices,
          clockLabelPresent: clockLabelPresent
        )
      }
    }

    var volumeLevelPresent = false
    if let volumePosition = composition.layout.position(of: .volume) {
      let volume: SketchyBarItemQuery = try query(
        control: Self.controlURL,
        arguments: ["--query", "macarchy.volume"],
        timeout: 0.1
      )
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL,
        arguments: ["--query", "events"],
        timeout: 0.1
      )
      let expectedVolumeScript = stateRoot.appending(
        path: "desktop/sketchybar/current/plugins/volume.sh"
      ).path
      let volumeEventBit = events["volume_change"]?.bit
      let wakeEventBit = events["system_woke"]?.bit
      let requiredEventMask = (volumeEventBit ?? 0) | (wakeEventBit ?? 0)
      volumeLevelPresent = Self.isVolumeLabel(volume.label.value)
      guard
        volumeEventBit.map({ $0 > 0 }) == true,
        wakeEventBit.map({ $0 > 0 }) == true,
        volume.name == "macarchy.volume",
        volume.type == "item",
        volume.geometry.drawing == "on",
        volume.geometry.position == volumePosition.rawValue,
        volume.label.drawing == "on",
        volumeLevelPresent,
        volume.scripting.script == expectedVolumeScript,
        volume.scripting.updateFrequency == 0,
        volume.scripting.updateMask.map({ $0 & requiredEventMask == requiredEventMask }) == true
      else {
        return drifted(
          "running SketchyBar volume module is incomplete, misplaced, or unsubscribed",
          palette: palette,
          items: items,
          spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent,
          volumeLevelPresent: volumeLevelPresent
        )
      }
    }

    let finalBar: SketchyBarBarQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", "bar"],
      timeout: 0.1
    )
    guard finalBar.items.sorted() == items else {
      return drifted(
        "running SketchyBar item inventory changed during verification",
        palette: palette,
        items: finalBar.items.sorted(),
        spaceIndices: spaceIndices,
        clockLabelPresent: clockLabelPresent,
        volumeLevelPresent: volumeLevelPresent
      )
    }

    let partial = composition.hookURL != nil
    return SketchyBarCoreRuntimeInspection(
      status: partial ? .partial : .converged,
      message: partial
        ? "managed SketchyBar core is verified; the trusted hook may add behavior Macarchy cannot inspect"
        : "running SketchyBar matches the selected provider and canonical theme generations",
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: clockLabelPresent,
      volumeLevelPresent: volumeLevelPresent
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
      indices.allSatisfy({ (1..<UInt32.bitWidth).contains($0) })
    else {
      throw SketchyBarDesktopError.lifecycle("yabai returned an invalid Space inventory")
    }
    return indices
  }

  private func expectedItemNames(
    layout: SketchyBarLayout,
    spaceModule: SketchyBarSpaceModule,
    spaceIndices: [Int]
  ) -> [String] {
    var names = [SketchyBarConfigurationComposer.readyItem]
    if layout.position(of: .clock) != nil {
      names.append("macarchy.clock")
    }
    if layout.position(of: .volume) != nil {
      names.append("macarchy.volume")
    }
    switch spaceModule {
    case .dynamicYabai:
      names += spaceIndices.map { "macarchy.space.\($0)" }
    case .disabledWithoutDesktop:
      names.append("macarchy.spaces.unavailable")
    case .hidden:
      break
    }
    return names.sorted()
  }

  private static func isVolumeLabel(_ value: String) -> Bool {
    guard value.hasSuffix("%") else { return false }
    let digits = value.dropLast()
    return !digits.isEmpty && digits.count <= 3
      && digits.allSatisfy(\.isNumber)
      && digits.allSatisfy(\.isASCII)
      && (digits.first != "0" || digits.count == 1)
      && Int(digits).map({ (0...100).contains($0) }) == true
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
    clockLabelPresent: Bool = false,
    volumeLevelPresent: Bool = false
  ) -> SketchyBarCoreRuntimeInspection {
    SketchyBarCoreRuntimeInspection(
      status: .drifted,
      message: message,
      themeGenerationID: palette.generationID,
      barColor: palette.color,
      items: items,
      spaceIndices: spaceIndices,
      clockLabelPresent: clockLabelPresent,
      volumeLevelPresent: volumeLevelPresent
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
    let associatedSpaceMask: UInt32

    enum CodingKeys: String, CodingKey {
      case drawing, position
      case associatedSpaceMask = "associated_space_mask"
    }
  }

  struct Label: Decodable {
    let value: String
    let drawing: String
  }

  struct Scripting: Decodable {
    let script: String
    let clickScript: String
    let updateFrequency: Int
    let updateMask: UInt64?

    enum CodingKeys: String, CodingKey {
      case script
      case clickScript = "click_script"
      case updateFrequency = "update_freq"
      case updateMask = "update_mask"
    }
  }

  let name: String
  let type: String
  let geometry: Geometry
  let label: Label
  let scripting: Scripting
}

private struct SketchyBarEventQuery: Decodable {
  let bit: UInt64
}

private struct YabaiSpaceQuery: Decodable {
  let index: Int
}
