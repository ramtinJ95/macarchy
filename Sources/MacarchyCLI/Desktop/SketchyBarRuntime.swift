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
  let batteryStatePresent: Bool?
  let metricModules: [String]?
  let wifiStatePresent: Bool?
  let mediaStatePresent: Bool?
  let appleStatePresent: Bool?
  let toggleStatePresent: Bool?

  static let wifiItems = [
    "macarchy.wifi", "macarchy.wifi.up", "macarchy.wifi.down",
    "macarchy.wifi.ssid", "macarchy.wifi.hostname", "macarchy.wifi.ip",
    "macarchy.wifi.mask", "macarchy.wifi.router",
  ]

  init(
    status: SketchyBarCoreRuntimeStatus,
    message: String,
    themeGenerationID: String? = nil,
    barColor: String? = nil,
    items: [String] = [],
    spaceIndices: [Int] = [],
    clockLabelPresent: Bool = false,
    volumeLevelPresent: Bool = false,
    batteryStatePresent: Bool = false,
    metricModules: [String] = [],
    wifiStatePresent: Bool = false,
    mediaStatePresent: Bool = false,
    appleStatePresent: Bool = false,
    toggleStatePresent: Bool = false
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
    self.batteryStatePresent = batteryStatePresent
    self.metricModules = metricModules
    self.wifiStatePresent = wifiStatePresent
    self.mediaStatePresent = mediaStatePresent
    self.appleStatePresent = appleStatePresent
    self.toggleStatePresent = toggleStatePresent
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
    let hasBattery = items.contains("macarchy.battery")
    guard hasBattery == (batteryStatePresent ?? false),
      hasBattery == items.contains("macarchy.battery.remaining")
    else { return false }
    var managedItems = [SketchyBarConfigurationComposer.readyItem]
    if hasClock { managedItems.append("macarchy.clock") }
    if items.contains(SketchyBarCalendar.previewItem) {
      guard hasClock else { return false }
      managedItems.append(SketchyBarCalendar.previewItem)
    }
    if hasVolume { managedItems.append("macarchy.volume") }
    if items.contains("macarchy.volume.slider") {
      guard hasVolume else { return false }
      managedItems.append("macarchy.volume.slider")
    }
    let volumeExtras = [
      "macarchy.volume.icon", "macarchy.volume.bracket", "macarchy.volume.padding",
    ]
    if volumeExtras.contains(where: items.contains) {
      guard hasVolume, volumeExtras.allSatisfy(items.contains) else { return false }
      managedItems += volumeExtras
    }
    if hasBattery { managedItems += ["macarchy.battery", "macarchy.battery.remaining"] }
    let metrics = metricModules ?? []
    guard metrics == metrics.sorted(), Set(metrics).count == metrics.count,
      metrics.allSatisfy({ ["cpu", "memory"].contains($0) })
    else { return false }
    for metric in ["cpu", "memory"] {
      guard items.contains("macarchy.\(metric)") == metrics.contains(metric) else { return false }
    }
    managedItems += metrics.map { "macarchy.\($0)" }
    for item in Self.wifiItems {
      guard items.contains(item) == (wifiStatePresent ?? false) else { return false }
    }
    if wifiStatePresent == true { managedItems += Self.wifiItems }
    if items.contains("macarchy.wifi.bracket") {
      guard wifiStatePresent == true else { return false }
      managedItems.append("macarchy.wifi.bracket")
    }
    for module in ["battery", "cpu", "memory"] where items.contains("macarchy.\(module).padding") {
      guard items.contains("macarchy.\(module)") else { return false }
      managedItems.append("macarchy.\(module).padding")
    }
    for item in SketchyBarMedia.items {
      guard items.contains(item) == (mediaStatePresent ?? false) else { return false }
    }
    if mediaStatePresent == true { managedItems += SketchyBarMedia.items }
    guard items.contains("macarchy.apple") == (appleStatePresent ?? false) else { return false }
    if appleStatePresent == true { managedItems.append("macarchy.apple") }
    guard items.contains("macarchy.toggle") == (toggleStatePresent ?? false) else { return false }
    if toggleStatePresent == true { managedItems.append("macarchy.toggle") }
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

  func agreesWithProviderRuntime(_ current: Self) -> Bool {
    status == current.status
      && items == current.items
      && spaceIndices == current.spaceIndices
      && clockLabelPresent == current.clockLabelPresent
      && volumeLevelPresent == current.volumeLevelPresent
      && (batteryStatePresent ?? false) == (current.batteryStatePresent ?? false)
      && (metricModules ?? []) == (current.metricModules ?? [])
      && (wifiStatePresent ?? false) == (current.wifiStatePresent ?? false)
      && (mediaStatePresent ?? false) == (current.mediaStatePresent ?? false)
      && (appleStatePresent ?? false) == (current.appleStatePresent ?? false)
      && (toggleStatePresent ?? false) == (current.toggleStatePresent ?? false)
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
    case batteryStatePresent = "battery_state_present"
    case metricModules = "metric_modules"
    case wifiStatePresent = "wifi_state_present"
    case mediaStatePresent = "media_state_present"
    case appleStatePresent = "apple_state_present"
    case toggleStatePresent = "toggle_state_present"
  }
}

struct SketchyBarCoreRuntimeController: Sendable {
  let inspect: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection
  let settle: @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection
  let settleRestored: @Sendable (SketchyBarCoreRuntimeInspection) -> Bool

  init(
    inspect: @escaping @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection,
    settle: @escaping @Sendable (SketchyBarComposition) -> SketchyBarCoreRuntimeInspection,
    settleRestored: @escaping @Sendable (SketchyBarCoreRuntimeInspection) -> Bool
  ) {
    self.inspect = inspect
    self.settle = settle
    self.settleRestored = settleRestored
  }

  static func live(stateRoot: URL) -> Self {
    let verifier = SketchyBarCoreRuntimeVerifier.live(stateRoot: stateRoot)
    return Self(
      inspect: verifier.inspect,
      settle: verifier.settle,
      settleRestored: verifier.settleRestored
    )
  }
}

struct SketchyBarCoreRuntimeVerifier: Sendable {
  static let controlURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
  static let yabaiURL = URL(filePath: "/opt/homebrew/bin/yabai")

  let stateRoot: URL
  let processRunner: ProcessRunner
  let waitForSettle: @Sendable () -> Void
  let waitForPresentation: @Sendable () -> Void
  let hasExternalDisplay: @Sendable () throws -> Bool
  let toggleProcessMatches: @Sendable (ToggleHeartbeat) -> Bool
  let uptime: @Sendable () -> TimeInterval

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
    waitForPresentation: @escaping @Sendable () -> Void,
    hasExternalDisplay: @escaping @Sendable () throws -> Bool = SketchyBarCalendar
      .externalDisplayPresent,
    toggleProcessMatches: @escaping @Sendable (ToggleHeartbeat) -> Bool = SketchyBarToggle
      .matchesProcess,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.stateRoot = stateRoot.standardizedFileURL
    self.processRunner = processRunner
    self.waitForSettle = waitForSettle
    self.hasExternalDisplay = hasExternalDisplay
    self.toggleProcessMatches = toggleProcessMatches
    self.uptime = uptime
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
    let attemptCount = composition.hookURL == nil ? 41 : 11
    for attempt in 0..<attemptCount {
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
      if attempt < attemptCount - 1 {
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

  func settleRestored(_ expected: SketchyBarCoreRuntimeInspection) -> Bool {
    guard
      expected.isValidEvidence,
      let expectedColor = (try? activePalette())?.color
    else { return false }
    for attempt in 0..<41 {
      do {
        let bar: SketchyBarBarQuery = try query(
          control: Self.controlURL,
          arguments: ["--query", "bar"],
          timeout: 0.1
        )
        let items = try stableItems(bar.items, volumeEnabled: expected.volumeLevelPresent == true)
        let inventoryMatches =
          if expected.status == .partial {
            expected.items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(items.contains)
              && items.filter { $0.hasPrefix("macarchy.") }.allSatisfy(expected.items.contains)
          } else {
            items == expected.items
          }
        var presentationMatches = inventoryMatches
        if expected.clockLabelPresent {
          let clock: SketchyBarItemQuery = try query(
            control: Self.controlURL,
            arguments: ["--query", "macarchy.clock"],
            timeout: 0.1
          )
          presentationMatches =
            presentationMatches && !clock.label.value.isEmpty && clock.label.value != "ERR"
          if expected.items.contains(SketchyBarCalendar.previewItem) {
            presentationMatches = try presentationMatches && validClockPreview()
          }
        }
        if expected.toggleStatePresent == true {
          let toggle: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.toggle"], timeout: 0.1)
          presentationMatches = presentationMatches && validToggleHeartbeat(toggle.label.value)
        }
        if expected.appleStatePresent == true {
          let apple: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.apple"], timeout: 0.1)
          presentationMatches =
            presentationMatches && apple.label.drawing == "off" && apple.label.value.isEmpty
        }
        if expected.mediaStatePresent == true {
          let media: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.media"], timeout: 0.1)
          presentationMatches = presentationMatches && Self.validMediaIdentity(media.label.value)
        }
        if expected.volumeLevelPresent == true {
          let volume: SketchyBarItemQuery = try query(
            control: Self.controlURL,
            arguments: ["--query", "macarchy.volume"],
            timeout: 0.1
          )
          presentationMatches = presentationMatches && !volume.label.value.isEmpty
          if expected.items.contains("macarchy.volume.icon") {
            let icon: SketchyBarItemQuery = try query(
              control: Self.controlURL, arguments: ["--query", "macarchy.volume.icon"], timeout: 0.1
            )
            presentationMatches = presentationMatches && Self.isVolumeIcon(icon.label.value)
          }
          if expected.items.contains("macarchy.volume.slider") {
            let slider: SketchyBarItemQuery = try query(
              control: Self.controlURL, arguments: ["--query", "macarchy.volume.slider"],
              timeout: 0.1)
            presentationMatches =
              presentationMatches && Self.isSliderLevel(slider.slider?.percentage)
          }
        }
        if expected.batteryStatePresent == true {
          let battery: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.battery"], timeout: 0.1)
          let remaining: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.battery.remaining"],
            timeout: 0.1)
          presentationMatches =
            presentationMatches && Self.isBatteryLabel(battery.label.value)
            && Self.isBatteryEstimate(remaining.label.value)
        }
        for metric in expected.metricModules ?? [] {
          let item: SketchyBarItemQuery = try query(
            control: Self.controlURL, arguments: ["--query", "macarchy.\(metric)"], timeout: 0.1)
          presentationMatches =
            presentationMatches && Self.isMetricLabel(item.label.value, metric: metric)
        }
        if expected.wifiStatePresent == true {
          for suffix in ["up", "down", "ssid"] {
            let item: SketchyBarItemQuery = try query(
              control: Self.controlURL,
              arguments: ["--query", "macarchy.wifi.\(suffix)"], timeout: 0.1)
            presentationMatches =
              presentationMatches
              && (suffix == "ssid"
                ? Self.isWiFiSSIDLabel(item.label.value) : Self.isWiFiRate(item.label.value))
          }
        }
        if bar.drawing == "on", bar.color.lowercased() == expectedColor,
          presentationMatches
        {
          waitForPresentation()
          return true
        }
      } catch {
        // Retry only inside the same bounded settle window used for normal reloads.
      }
      if attempt < 40 { waitForSettle() }
    }
    return false
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
    let items = try stableItems(
      bar.items, volumeEnabled: composition.layout.position(of: .volume) != nil)
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
      bar.topmost == "on",
      composition.layout.position(of: .toggle) != nil
        ? ["on", "off"].contains(bar.hidden) && (-50...0).contains(bar.yOffset)
        : bar.hidden == "off" && bar.yOffset == 0,
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
      let actualPosition =
        composition.automaticClock
        ? (try hasExternalDisplay() ? "center" : "right") : clockPosition.rawValue
      let clock: SketchyBarItemQuery = try query(
        control: Self.controlURL,
        arguments: ["--query", "macarchy.clock"],
        timeout: 0.1
      )
      let expectedClockScript = stateRoot.appending(
        path: "desktop/sketchybar/current/plugins/clock.sh"
      ).path
      let clockLabel = clock.label.value
      clockLabelPresent = !clockLabel.isEmpty && clockLabel != "ERR"
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL, arguments: ["--query", "events"], timeout: 0.1)
      let bits = ["mouse.clicked", "display_change", "system_woke"].compactMap { events[$0]?.bit }
      let mask = bits.reduce(0, |)
      guard
        clock.name == "macarchy.clock",
        clock.type == "item",
        clock.geometry.drawing == "on",
        clock.geometry.position == actualPosition,
        clock.label.drawing == "on",
        clockLabelPresent,
        clock.scripting.script == expectedClockScript,
        clock.scripting.updateFrequency == 30,
        bits.count == 3, clock.scripting.updateMask.map({ $0 & mask == mask }) == true,
        try validClockPreview()
      else {
        return drifted(
          "running SketchyBar clock is incomplete: "
            + "name=\(clock.name), type=\(clock.type), drawing=\(clock.geometry.drawing), "
            + "position=\(clock.geometry.position), label_drawing=\(clock.label.drawing), "
            + "label_present=\(clockLabelPresent), script=\(clock.scripting.script), "
            + "update_freq=\(clock.scripting.updateFrequency)",
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
      let interactionBits = ["mouse.clicked", "mouse.scrolled", "mouse.exited.global"].compactMap {
        events[$0]?.bit
      }
      let requiredEventMask = interactionBits.reduce((volumeEventBit ?? 0) | (wakeEventBit ?? 0), |)
      let slider: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.volume.slider"], timeout: 0.1)
      let icon: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.volume.icon"], timeout: 0.1)
      let padding: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.volume.padding"], timeout: 0.1)
      let parent: SketchyBarAudioPicker.Parent = try query(
        control: Self.controlURL, arguments: ["--query", SketchyBarAudioPicker.popupOwner],
        timeout: 0.1)
      volumeLevelPresent = Self.isVolumeLabel(volume.label.value)
      guard
        parent.owns(rows: bar.items.filter { $0.hasPrefix(SketchyBarAudioPicker.prefix) }),
        parent.geometry.position == volumePosition.rawValue, parent.geometry.drawing == "on",
        parent.label.drawing == "off", ["", "(null)"].contains(parent.scripting.script),
        parent.scripting.updateFrequency == 0,
        icon.name == "macarchy.volume.icon", icon.type == "item",
        icon.geometry.position == volumePosition.rawValue,
        icon.geometry.drawing == "on", icon.label.drawing == "on",
        Self.isVolumeIcon(icon.label.value),
        icon.scripting.script == expectedVolumeScript, icon.scripting.updateFrequency == 0,
        icon.scripting.updateMask.map({
          $0 & ((events["mouse.clicked"]?.bit ?? 0) | (events["mouse.scrolled"]?.bit ?? 0))
            == ((events["mouse.clicked"]?.bit ?? 0) | (events["mouse.scrolled"]?.bit ?? 0))
        }) == true,
        padding.name == "macarchy.volume.padding", padding.type == "item",
        padding.geometry.position == volumePosition.rawValue,
        padding.geometry.drawing == "on", padding.geometry.width == 8,
        padding.label.drawing == "off",
        ["", "(null)"].contains(padding.scripting.script), padding.scripting.updateFrequency == 0,
        interactionBits.count == 3, interactionBits.allSatisfy({ $0 > 0 }),
        slider.name == "macarchy.volume.slider", slider.type == "slider",
        slider.geometry.drawing == "on", slider.geometry.position == "popup",
        slider.label.drawing == "off", ["", "(null)"].contains(slider.scripting.script),
        slider.scripting.clickScript
          == SketchyBarConfigurationComposer.pluginClickScript(
            sender: "macarchy.slider", pluginPath: expectedVolumeScript),
        slider.scripting.updateFrequency == 0, Self.isSliderLevel(slider.slider?.percentage),
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

    var batteryStatePresent = false
    if let position = composition.layout.position(of: .battery) {
      let battery: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.battery"], timeout: 0.1)
      let remaining: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.battery.remaining"], timeout: 0.1
      )
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL, arguments: ["--query", "events"], timeout: 0.1)
      let eventBits = [
        "power_source_change", "system_woke", "mouse.clicked", "mouse.exited.global",
      ]
      .compactMap { events[$0]?.bit }.filter { $0 > 0 }
      let mask = eventBits.reduce(UInt64(0), |)
      batteryStatePresent =
        Self.isBatteryLabel(battery.label.value)
        && Self.isBatteryEstimate(remaining.label.value)
      guard eventBits.count == 4,
        battery.name == "macarchy.battery", battery.type == "item",
        battery.geometry.drawing == "on", battery.geometry.position == position.rawValue,
        battery.label.drawing == "on", batteryStatePresent,
        battery.scripting.script
          == stateRoot.appending(path: "desktop/sketchybar/current/plugins/battery.sh").path,
        battery.scripting.updateFrequency == 180,
        battery.scripting.updateMask.map({ $0 & mask == mask }) == true,
        remaining.name == "macarchy.battery.remaining", remaining.type == "item",
        remaining.label.drawing == "on"
      else {
        return drifted(
          "running SketchyBar battery state, popup, or subscriptions are incomplete",
          palette: palette, items: items, spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
      }
    }

    var metricModules: [String] = []
    for module in [SketchyBarModule.cpu, .memory] {
      guard let position = composition.layout.position(of: module) else { continue }
      let name = "macarchy.\(module.rawValue)"
      let metric: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", name], timeout: 0.1)
      guard metric.name == name, metric.type == "item",
        metric.geometry.drawing == "on", metric.geometry.position == position.rawValue,
        metric.label.drawing == "on",
        Self.isMetricLabel(metric.label.value, metric: module.rawValue),
        metric.scripting.script
          == stateRoot.appending(path: "desktop/sketchybar/current/plugins/\(module.rawValue).sh")
          .path,
        metric.scripting.updateFrequency == (module == .cpu ? 2 : 5),
        metric.scripting.clickScript == "/usr/bin/open -a \"Activity Monitor\""
      else {
        return drifted(
          "running SketchyBar \(module.rawValue) metric is incomplete or misplaced",
          palette: palette, items: items, spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
      }
      metricModules.append(module.rawValue)
    }

    for module in [SketchyBarModule.battery, .cpu, .memory]
    where composition.layout.hasTrailingGroupPadding(module) {
      let name = "macarchy.\(module.rawValue).padding"
      let padding: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", name], timeout: 0.1)
      guard padding.name == name, padding.type == "item", padding.geometry.drawing == "on",
        padding.geometry.position == composition.layout.position(of: module)?.rawValue,
        padding.geometry.width == 8, padding.label.drawing == "off",
        ["", "(null)"].contains(padding.scripting.script), padding.scripting.updateFrequency == 0
      else {
        return drifted(
          "running SketchyBar widget group spacing is incomplete", palette: palette, items: items,
          spaceIndices: spaceIndices, clockLabelPresent: clockLabelPresent,
          volumeLevelPresent: volumeLevelPresent)
      }
    }

    var wifiStatePresent = false
    if let position = composition.layout.position(of: .wifi) {
      let group: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.wifi.bracket"], timeout: 0.1)
      guard group.name == "macarchy.wifi.bracket", group.type == "bracket",
        group.geometry.drawing == "on",
        group.geometry.position == position.rawValue, group.label.drawing == "off",
        group.bracket?.sorted() == ["macarchy.wifi", "macarchy.wifi.down", "macarchy.wifi.up"],
        group.popup?.items.sorted() == [
          "macarchy.wifi.hostname", "macarchy.wifi.ip", "macarchy.wifi.mask",
          "macarchy.wifi.router", "macarchy.wifi.ssid",
        ],
        ["", "(null)"].contains(group.scripting.script), group.scripting.updateFrequency == 0
      else {
        return drifted(
          "running SketchyBar Wi-Fi popup group is incomplete", palette: palette, items: items,
          spaceIndices: spaceIndices, clockLabelPresent: clockLabelPresent,
          volumeLevelPresent: volumeLevelPresent)
      }
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL,
        arguments: ["--query", "events"], timeout: 0.1)
      for name in SketchyBarCoreRuntimeInspection.wifiItems {
        let item: SketchyBarItemQuery = try query(
          control: Self.controlURL,
          arguments: ["--query", name], timeout: 0.1)
        let main = name == "macarchy.wifi"
        let rate = name == "macarchy.wifi.up" || name == "macarchy.wifi.down"
        let required =
          main ? ["mouse.clicked", "mouse.exited.global", "system_woke"] : ["mouse.clicked"]
        let bits = required.compactMap { events[$0]?.bit }.filter { $0 > 0 }
        let mask = bits.reduce(UInt64(0), |)
        guard bits.count == required.count, item.name == name, item.type == "item",
          item.geometry.position == (main || rate ? position.rawValue : "popup"),
          (!main && !rate) || item.geometry.drawing == "on",
          item.label.drawing == (main ? "off" : "on"),
          main
            || (rate
              ? Self.isWiFiRate(item.label.value)
              : name == "macarchy.wifi.ssid"
                ? Self.isWiFiSSIDLabel(item.label.value) : !item.label.value.isEmpty),
          item.scripting.script
            == stateRoot.appending(path: "desktop/sketchybar/current/plugins/wifi.sh").path,
          item.scripting.updateFrequency == (main ? 2 : 0),
          item.scripting.updateMask.map({ $0 & mask == mask }) == true
        else {
          return drifted(
            "running SketchyBar Wi-Fi state, popup, or subscriptions are incomplete",
            palette: palette, items: items, spaceIndices: spaceIndices,
            clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
        }
      }
      wifiStatePresent = true
    }

    var toggleStatePresent = false
    if let position = composition.layout.position(of: .toggle) {
      let toggle: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.toggle"], timeout: 0.1)
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL, arguments: ["--query", "events"], timeout: 0.1)
      let bits = ["display_change", "system_woke"].compactMap { events[$0]?.bit }
      let mask = bits.reduce(UInt64(0), |)
      let heartbeat = ToggleHeartbeat.parse(toggle.label.value)
      guard toggle.name == "macarchy.toggle", toggle.type == "item",
        toggle.geometry.drawing == "off",
        toggle.geometry.position == position.rawValue, toggle.label.drawing == "off",
        let heartbeat,
        toggle.scripting.script
          == SketchyBarConfigurationComposer.toggleScript(
            pluginPath: stateRoot.appending(path: "desktop/sketchybar/current/plugins/toggle.sh")
              .path,
            token: heartbeat.token),
        toggle.scripting.updateFrequency == 1, toggle.scripting.updates == "on",
        bits.count == 2, toggle.scripting.updateMask.map({ $0 & mask == mask }) == true,
        validToggleHeartbeat(toggle.label.value)
      else {
        return drifted(
          "running SketchyBar native-menu toggle is not ready, failed, stale, or has lost process ownership",
          palette: palette, items: items, spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
      }
      toggleStatePresent = true
    }
    var appleStatePresent = false
    if let position = composition.layout.position(of: .apple) {
      let apple: SketchyBarItemQuery = try query(
        control: Self.controlURL, arguments: ["--query", "macarchy.apple"], timeout: 0.1)
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL, arguments: ["--query", "events"], timeout: 0.1)
      guard apple.name == "macarchy.apple", apple.type == "item", apple.geometry.drawing == "on",
        apple.geometry.position == position.rawValue, apple.label.drawing == "off",
        apple.label.value.isEmpty,
        apple.scripting.script
          == stateRoot.appending(path: "desktop/sketchybar/current/plugins/apple.sh").path,
        apple.scripting.updateFrequency == 0,
        let bit = events["mouse.clicked"]?.bit,
        apple.scripting.updateMask.map({ $0 & bit == bit }) == true
      else {
        return drifted(
          "running SketchyBar Apple-menu helper failed or its script/subscription is incomplete",
          palette: palette, items: items, spaceIndices: spaceIndices,
          clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
      }
      appleStatePresent = true
    }
    var mediaStatePresent = false
    if let position = composition.layout.position(of: .media) {
      let script = stateRoot.appending(path: "desktop/sketchybar/current/plugins/media.sh").path
      let events: [String: SketchyBarEventQuery] = try query(
        control: Self.controlURL, arguments: ["--query", "events"], timeout: 0.1)
      var observed: [String: SketchyBarItemQuery] = [:]
      for name in SketchyBarMedia.items {
        let item: SketchyBarItemQuery = try query(
          control: Self.controlURL, arguments: ["--query", name], timeout: 0.1)
        observed[name] = item
        let main = name == "macarchy.media"
        let detail = ["macarchy.media.artist", "macarchy.media.title"].contains(name)
        let preview = name == "macarchy.media.preview"
        let required =
          main
          ? [
            "mouse.entered", "mouse.exited", "mouse.clicked", "mouse.exited.global", "system_woke",
          ]
          : detail ? ["mouse.entered", "mouse.exited", "mouse.exited.global"] : []
        let bits = required.compactMap { events[$0]?.bit }
        let mask = bits.reduce(0, |)
        guard item.name == name, item.type == "item",
          item.geometry.position
            == (preview ? "right" : (main || detail ? position.rawValue : "popup")),
          item.scripting.updateFrequency == (main ? 2 : 0),
          main || detail
            ? item.scripting.script == script : ["", "(null)"].contains(item.scripting.script),
          main || detail
            ? bits.count == required.count
              && item.scripting.updateMask.map({ $0 & mask == mask }) == true : true,
          main || detail || preview
            ? true
            : item.scripting.clickScript
              == SketchyBarConfigurationComposer.pluginClickScript(sender: name, pluginPath: script),
          preview
            ? item.geometry.drawing == "off"
              && (item.label.value == "hover"
                || UInt64(item.label.value).map { String($0) == item.label.value } == true)
            : true
        else {
          return drifted(
            "running SketchyBar media scripts, controls, preview, or subscriptions are incomplete",
            palette: palette, items: items, spaceIndices: spaceIndices,
            clockLabelPresent: clockLabelPresent, volumeLevelPresent: volumeLevelPresent)
        }
      }
      let main = observed["macarchy.media"]!
      let playing = main.label.value != "inactive"
      guard Self.validMediaIdentity(main.label.value), main.label.drawing == "off",
        ["macarchy.media", "macarchy.media.artist", "macarchy.media.title"].allSatisfy({
          observed[$0]?.geometry.drawing == (playing ? "on" : "off")
        }),
        !playing || observed["macarchy.media.title"]?.label.value.isEmpty == false
      else {
        return drifted(
          "running SketchyBar media presentation is incomplete or failed", palette: palette,
          items: items, spaceIndices: spaceIndices, clockLabelPresent: clockLabelPresent,
          volumeLevelPresent: volumeLevelPresent)
      }
      mediaStatePresent = true
    }

    let finalBar: SketchyBarBarQuery = try query(
      control: Self.controlURL,
      arguments: ["--query", "bar"],
      timeout: 0.1
    )
    guard finalBar.items.sorted() == bar.items.sorted() else {
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
      volumeLevelPresent: volumeLevelPresent,
      batteryStatePresent: batteryStatePresent,
      metricModules: metricModules,
      wifiStatePresent: wifiStatePresent,
      mediaStatePresent: mediaStatePresent,
      appleStatePresent: appleStatePresent,
      toggleStatePresent: toggleStatePresent
    )
  }

  private func validToggleHeartbeat(_ value: String) -> Bool {
    guard let heartbeat = ToggleHeartbeat.parse(value) else { return false }
    return heartbeat.fresh(at: uptime()) && toggleProcessMatches(heartbeat)
  }

  private static func validMediaIdentity(_ value: String) -> Bool {
    value == "inactive" || value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }

  private func validClockPreview() throws -> Bool {
    let item: SketchyBarItemQuery = try query(
      control: Self.controlURL, arguments: ["--query", SketchyBarCalendar.previewItem], timeout: 0.1
    )
    return item.name == SketchyBarCalendar.previewItem && item.type == "item"
      && item.geometry.drawing == "off" && item.geometry.position == "right"
      && UInt64(item.label.value).map { String($0) == item.label.value } == true
      && (item.scripting.script.isEmpty || item.scripting.script == "(null)")
      && item.scripting.updateFrequency == 0
  }

  private func stableItems(_ items: [String], volumeEnabled: Bool) throws -> [String] {
    guard volumeEnabled, Set(items).count == items.count else { return items.sorted() }
    let rows = items.filter { $0.hasPrefix(SketchyBarAudioPicker.prefix) }
    if !rows.isEmpty {
      let parent: SketchyBarAudioPicker.Parent = try query(
        control: Self.controlURL, arguments: ["--query", SketchyBarAudioPicker.popupOwner],
        timeout: 0.1)
      guard parent.owns(rows: rows) else { return items.sorted() }
    }
    let pluginPath = stateRoot.appending(path: "desktop/sketchybar/current/plugins/volume.sh").path
    for name in rows {
      guard SketchyBarAudioPicker.selector(name) != nil else { return items.sorted() }
      let row: SketchyBarAudioPicker.Row = try query(
        control: Self.controlURL, arguments: ["--query", name], timeout: 0.1)
      guard row.valid(name: name, pluginPath: pluginPath) else { return items.sorted() }
    }
    return items.filter { !rows.contains($0) }.sorted()
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
      names.append(SketchyBarCalendar.previewItem)
    }
    if layout.position(of: .media) != nil { names += SketchyBarMedia.items }
    if layout.position(of: .apple) != nil { names.append("macarchy.apple") }
    if layout.position(of: .toggle) != nil { names.append("macarchy.toggle") }
    if layout.position(of: .volume) != nil {
      names += [
        "macarchy.volume", "macarchy.volume.slider", "macarchy.volume.icon",
        "macarchy.volume.bracket", "macarchy.volume.padding",
      ]
    }
    if layout.position(of: .battery) != nil {
      names += ["macarchy.battery", "macarchy.battery.remaining"]
    }
    for module in [SketchyBarModule.battery, .cpu, .memory]
    where layout.hasTrailingGroupPadding(module) {
      names.append("macarchy.\(module.rawValue).padding")
    }
    for module in [SketchyBarModule.cpu, .memory] where layout.position(of: module) != nil {
      names.append("macarchy.\(module.rawValue)")
    }
    if layout.position(of: .wifi) != nil {
      names += SketchyBarCoreRuntimeInspection.wifiItems + ["macarchy.wifi.bracket"]
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

  private static func isVolumeIcon(_ value: String) -> Bool {
    ["􀊣", "􀊡", "􀊥", "􀊧", "􀊩"].contains(value)
  }

  private static func isWiFiRate(_ value: String) -> Bool {
    value == "Unavailable"
      || value.range(
        of: #"^[0-9]{3}( Bps|KBps|MBps|GBps)$"#,
        options: .regularExpression) != nil
  }

  private static func isWiFiSSIDLabel(_ value: String) -> Bool {
    ["No Wi-Fi interface", "Disconnected / no IPv4", "Privacy restricted", "􀉄"].contains(value)
  }

  private static func isMetricLabel(_ value: String, metric: String) -> Bool {
    let prefix = metric == "cpu" ? "cpu " : "mem "
    guard value.hasPrefix(prefix), value.hasSuffix("%"),
      let level = Int(value.dropFirst(prefix.count).dropLast()), (0...100).contains(level)
    else { return false }
    return value == prefix + String(format: "%02d%%", level)
  }

  private static func isBatteryLabel(_ value: String) -> Bool {
    if value == "No battery" { return true }
    guard value.hasSuffix("%"), let level = Int(value.dropLast()), (0...100).contains(level)
    else { return false }
    return value == String(format: "%02d%%", level)
  }

  private static func isBatteryEstimate(_ value: String) -> Bool {
    if value == "No estimate" || value == "No battery" { return true }
    return value.range(of: #"^[0-9]+:[0-5][0-9]h$"#, options: .regularExpression) != nil
  }

  private static func isVolumeLabel(_ value: String) -> Bool {
    guard value.hasSuffix("%"), let level = Int(value.dropLast()), (0...100).contains(level)
    else { return false }
    return value == String(format: "%02d%%", level)
  }

  private static func isSliderLevel(_ value: String?) -> Bool {
    guard let value, let level = Int(value), (0...100).contains(level) else { return false }
    return value == String(level)
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
  let hidden: String
  let yOffset: Int
  let topmost: String
  let items: [String]

  enum CodingKeys: String, CodingKey {
    case position, drawing, color, height, margin, items, hidden, topmost
    case yOffset = "y_offset"
    case cornerRadius = "corner_radius"
  }
}

private struct SketchyBarItemQuery: Decodable {
  struct Popup: Decodable {
    let drawing: String
    let items: [String]
  }
  struct Slider: Decodable { let percentage: String }
  struct Geometry: Decodable {
    let drawing: String
    let position: String
    let associatedSpaceMask: UInt32
    let width: Int?

    enum CodingKeys: String, CodingKey {
      case drawing, position, width
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
    let updates: String?

    enum CodingKeys: String, CodingKey {
      case script
      case clickScript = "click_script"
      case updateFrequency = "update_freq"
      case updateMask = "update_mask"
      case updates
    }
  }

  let name: String
  let type: String
  let geometry: Geometry
  let label: Label
  let scripting: Scripting
  let slider: Slider?
  let bracket: [String]?
  let popup: Popup?
}

private struct SketchyBarEventQuery: Decodable {
  let bit: UInt64
}

private struct YabaiSpaceQuery: Decodable {
  let index: Int
}
