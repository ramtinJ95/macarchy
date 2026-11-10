import AppKit
import Darwin
import Foundation

/// How macOS presents a display's wallpaper: the options `NSWorkspace` reads and writes beside the
/// image. A missing value was absent from the options macOS reported and stays absent on restore.
package struct WallpaperPresentation: Codable, Equatable, Sendable {
  /// The raw `NSImageScaling` value.
  package let imageScaling: UInt?
  package let allowClipping: Bool?
  /// sRGB red, green, blue and alpha, each from 0 to 1.
  package let fillColor: [Double]?

  package init(imageScaling: UInt? = nil, allowClipping: Bool? = nil, fillColor: [Double]? = nil) {
    self.imageScaling = imageScaling
    self.allowClipping = allowClipping
    self.fillColor = fillColor
  }

  init(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) {
    imageScaling = (options[.imageScaling] as? NSNumber)?.uintValue
    allowClipping = (options[.allowClipping] as? NSNumber)?.boolValue
    fillColor = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB).map { color in
      [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        .map(Double.init)
    }
  }

  var options: [NSWorkspace.DesktopImageOptionKey: Any] {
    var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
    if let imageScaling { options[.imageScaling] = NSNumber(value: imageScaling) }
    if let allowClipping { options[.allowClipping] = NSNumber(value: allowClipping) }
    if let fillColor, fillColor.count == 4 {
      options[.fillColor] = NSColor(
        srgbRed: fillColor[0], green: fillColor[1], blue: fillColor[2], alpha: fillColor[3])
    }
    return options
  }

  var isValid: Bool {
    guard let fillColor else { return true }
    return fillColor.count == 4 && fillColor.allSatisfy { (0...1).contains($0) }
  }

  enum CodingKeys: String, CodingKey {
    case imageScaling = "image_scaling"
    case allowClipping = "allow_clipping"
    case fillColor = "fill_color"
  }
}

/// A display's wallpaper from before Macarchy first changed it, keyed by the display's persistent
/// UUID so it survives reconnection and display-number changes.
package struct WallpaperOriginal: Codable, Equatable, Sendable {
  package let displayUUID: String
  package let displayName: String
  package let imagePath: String
  package let presentation: WallpaperPresentation
  package let recordedAt: String

  package init(
    displayUUID: String,
    displayName: String,
    imagePath: String,
    presentation: WallpaperPresentation,
    recordedAt: String
  ) {
    self.displayUUID = displayUUID
    self.displayName = displayName
    self.imagePath = imagePath
    self.presentation = presentation
    self.recordedAt = recordedAt
  }

  enum CodingKeys: String, CodingKey {
    case displayUUID = "display_uuid"
    case displayName = "display_name"
    case imagePath = "image_path"
    case presentation
    case recordedAt = "recorded_at"
  }
}

/// A connected display as teardown sees it.
package struct WallpaperConnectedDisplay: Equatable, Sendable {
  package let id: UInt32
  package let uuid: String
  package let name: String
  package let wallpaperURL: URL

  package init(id: UInt32, uuid: String, name: String, wallpaperURL: URL) {
    self.id = id
    self.uuid = uuid
    self.name = name
    self.wallpaperURL = wallpaperURL
  }
}

/// What teardown does for one display: the three-way rule plus the cases it cannot decide.
package enum WallpaperRestoreStep: Equatable, Sendable {
  /// The display still shows Macarchy's wallpaper, so the original goes back.
  case restore(WallpaperOriginal, displayID: UInt32)
  /// The display already shows its original wallpaper.
  case alreadyOriginal(WallpaperOriginal)
  /// The user chose another wallpaper after Macarchy set one; it stays.
  case keepUserChange(WallpaperOriginal)
  /// The display shows Macarchy's wallpaper, but the original image is gone.
  case originalMissing(WallpaperOriginal)
  /// The display is not connected now, so nothing can be restored on it.
  case disconnected(WallpaperOriginal)
  /// The display shows Macarchy's wallpaper and no original was recorded for it.
  case unrecorded(displayName: String)

  /// Whether teardown should tell the user about this display.
  var isReported: Bool {
    if case .alreadyOriginal = self { return false }
    return true
  }

  /// Whether the step comes from a recorded original.
  var recorded: Bool {
    if case .unrecorded = self { return false }
    return true
  }
}

/// The original-wallpaper rules, kept free of I/O so they can be tested directly.
package enum WallpaperOriginals {
  /// Displays recorded at most; the oldest records go first.
  package static let maximumDisplays = 32

  /// `originals` plus a record for each display Macarchy is about to change for the first time.
  /// A display already showing Macarchy's wallpaper has no knowable original and is skipped.
  static func capturing(
    _ originals: [WallpaperOriginal],
    displays: [WallpaperDisplay],
    isMacarchyWallpaper: (URL) -> Bool,
    describe: (WallpaperDisplay) throws -> (uuid: String, presentation: WallpaperPresentation),
    now: String
  ) rethrows -> [WallpaperOriginal] {
    var result = originals
    for display in displays where !isMacarchyWallpaper(display.wallpaperURL) {
      let description = try describe(display)
      guard !result.contains(where: { $0.displayUUID == description.uuid }) else { continue }
      result.append(
        WallpaperOriginal(
          displayUUID: description.uuid,
          displayName: display.name,
          imagePath: display.wallpaperURL.standardizedFileURL.path,
          presentation: description.presentation,
          recordedAt: now
        ))
    }
    return Array(result.suffix(maximumDisplays))
  }

  /// One step per recorded display, then one for each connected display that shows Macarchy's
  /// wallpaper without a record.
  package static func restorationPlan(
    originals: [WallpaperOriginal],
    displays: [WallpaperConnectedDisplay],
    isMacarchyWallpaper: (URL) -> Bool,
    originalExists: (String) -> Bool
  ) -> [WallpaperRestoreStep] {
    var steps = originals.map { original -> WallpaperRestoreStep in
      guard let display = displays.first(where: { $0.uuid == original.displayUUID }) else {
        return .disconnected(original)
      }
      if display.wallpaperURL.standardizedFileURL.path == original.imagePath {
        return .alreadyOriginal(original)
      }
      guard isMacarchyWallpaper(display.wallpaperURL) else { return .keepUserChange(original) }
      guard originalExists(original.imagePath) else { return .originalMissing(original) }
      return .restore(original, displayID: display.id)
    }
    let recorded = Set(originals.map(\.displayUUID))
    for display in displays
    where !recorded.contains(display.uuid) && isMacarchyWallpaper(display.wallpaperURL) {
      steps.append(.unrecorded(displayName: display.name))
    }
    return steps
  }
}

package enum WallpaperOriginalStoreError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL)
  case cannotReplace(Int32)
  case cannotRemove(String)
  case invalid(String)

  package var description: String {
    switch self {
    case .cannotRead(let url):
      "Cannot read the original wallpapers at \(url.path)"
    case .cannotReplace(let code):
      "Cannot atomically replace the original wallpapers (errno \(code)): "
        + String(cString: strerror(code))
    case .cannotRemove(let reason):
      "Cannot remove the original wallpapers: \(reason)"
    case .invalid(let reason):
      "Invalid original wallpapers: \(reason)"
    }
  }
}

private struct WallpaperOriginalDocument: Codable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let displays: [WallpaperOriginal]

  init(displays: [WallpaperOriginal]) {
    schemaVersion = Self.schemaVersion
    self.displays = displays
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case displays
  }
}

/// `state/wallpaper-originals.json`: each display's wallpaper before Macarchy first changed it.
/// Setup teardown consumes and removes it.
package struct WallpaperOriginalStore: Sendable {
  private let url: URL

  package init(root: URL) {
    url = root.standardizedFileURL.appending(path: "state/wallpaper-originals.json")
  }

  package func load() throws -> [WallpaperOriginal] {
    let file: BoundedRegularFile?
    do {
      file = try BoundedRegularFile.readIfPresent(at: url)
    } catch {
      throw WallpaperOriginalStoreError.cannotRead(url)
    }
    guard let data = file?.data else { return [] }

    do {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard
        let object,
        Set(object.keys) == Set(WallpaperOriginalDocument.CodingKeys.allCases.map(\.stringValue))
      else {
        throw WallpaperOriginalStoreError.invalid("contains unknown or missing fields")
      }
      let document = try JSONDecoder().decode(WallpaperOriginalDocument.self, from: data)
      guard document.schemaVersion == WallpaperOriginalDocument.schemaVersion else {
        throw WallpaperOriginalStoreError.invalid(
          "unsupported schema version \(document.schemaVersion)")
      }
      try validate(document.displays)
      return document.displays
    } catch let error as WallpaperOriginalStoreError {
      throw error
    } catch {
      throw WallpaperOriginalStoreError.invalid(String(describing: error))
    }
  }

  package func persist(_ originals: [WallpaperOriginal]) throws {
    try validate(originals)
    try StateFile.replaceByRename(
      at: url,
      temporaryName: ".wallpaper-originals-\(UUID().uuidString.lowercased()).json",
      temporaryWriteOptions: [],
      encode: { try prettyJSONDocument(WallpaperOriginalDocument(displays: originals)) },
      tooLargeError: WallpaperOriginalStoreError.invalid("exceeds the 1 MiB file limit"),
      renameError: WallpaperOriginalStoreError.cannotReplace
    )
  }

  package func remove() throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw WallpaperOriginalStoreError.cannotRemove(String(describing: error))
    }
  }

  private func validate(_ originals: [WallpaperOriginal]) throws {
    guard originals.count <= WallpaperOriginals.maximumDisplays else {
      throw WallpaperOriginalStoreError.invalid(
        "records more than \(WallpaperOriginals.maximumDisplays) displays")
    }
    guard Set(originals.map(\.displayUUID)).count == originals.count else {
      throw WallpaperOriginalStoreError.invalid("records a display more than once")
    }
    for original in originals {
      guard
        !original.displayUUID.isEmpty, original.displayUUID.count <= 64,
        original.displayName.count <= 256,
        original.imagePath.hasPrefix("/"), original.imagePath.utf8.count <= 4096,
        original.presentation.isValid
      else {
        throw WallpaperOriginalStoreError.invalid(
          "each display needs a UUID, a name, an absolute image path and valid options")
      }
    }
  }
}

/// What teardown did with wallpaper: one line per display worth reporting, in record order.
package struct WallpaperRestoreReport: Equatable, Sendable {
  package var lines: [String]
  package var mutated: Bool
  /// The record was read and holds originals, so teardown removes it once it commits.
  package var consumesRecord: Bool
}

/// Puts each display's original wallpaper back at setup teardown. Restoration runs while the
/// caller holds the activation lock, just before the theme is retired, so no reconciliation can
/// record or change wallpaper between the two; the record is removed only after that commits.
package struct WallpaperOriginalRestorer: Sendable {
  private let root: URL
  private let control: WallpaperControl
  private let activationLock: ActivationLock
  private let originalExists: @Sendable (String) -> Bool
  private let waitForSettle: @Sendable () -> Void

  init(
    root: URL,
    control: WallpaperControl,
    originalExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    waitForSettle: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.25) }
  ) {
    self.root = root
    self.control = control
    activationLock = ActivationLock(root: root)
    self.originalExists = originalExists
    self.waitForSettle = waitForSettle
  }

  package static func live(root: URL) -> Self {
    Self(root: root, control: .live)
  }

  /// What a teardown would do, without changing anything.
  package func plan() -> WallpaperRestoreReport {
    do {
      return try activationLock.withLock { () -> WallpaperRestoreReport in
        switch steps() {
        case .unreadable(let report): report
        case .planned(let steps):
          WallpaperRestoreReport(
            lines: steps.filter(\.isReported).map { Self.line($0, dryRun: true) },
            mutated: false,
            consumesRecord: false
          )
        }
      }
    } catch {
      return Self.unchanged("Original wallpapers were left unchanged: \(error).")
    }
  }

  /// Restores every display that still shows Macarchy's wallpaper and reads each one back.
  /// The caller must hold the activation lock (`ThemeActivator.deactivate`'s
  /// `beforeRetiringLocked`); a failed or unsettled restore is reported, never thrown.
  package func restoreHoldingActivationLock() -> WallpaperRestoreReport {
    let steps: [WallpaperRestoreStep]
    switch self.steps() {
    case .unreadable(let report): return report
    case .planned(let planned): steps = planned
    }
    var failures: [Int: String] = [:]
    var requested: [Int: (original: WallpaperOriginal, displayID: UInt32)] = [:]
    for (index, step) in steps.enumerated() {
      guard case .restore(let original, let displayID) = step else { continue }
      do {
        try control.restore(URL(filePath: original.imagePath), original.presentation, displayID)
        requested[index] = (original, displayID)
      } catch {
        failures[index] =
          "Could not restore the original wallpaper on '\(original.displayName)' "
          + "(\(original.imagePath)): \(error)."
      }
    }
    let unsettled = settle(requested)
    for index in unsettled {
      guard let original = requested[index]?.original else { continue }
      failures[index] =
        "macOS did not show the original wallpaper on '\(original.displayName)' "
        + "(\(original.imagePath)) after it was restored."
    }
    let lines = steps.enumerated().compactMap { index, step -> String? in
      guard step.isReported else { return nil }
      return failures[index] ?? Self.line(step, dryRun: false)
    }
    return WallpaperRestoreReport(
      lines: lines,
      mutated: !requested.isEmpty,
      consumesRecord: steps.contains { $0.recorded }
    )
  }

  /// Removes the record a committed teardown consumed. A record that could not be read stays,
  /// since it is still the only evidence of the originals.
  package func removeRecord(after report: WallpaperRestoreReport) -> WallpaperRestoreReport {
    guard report.consumesRecord else { return report }
    var result = report
    do {
      try WallpaperOriginalStore(root: root).remove()
      result.mutated = true
    } catch {
      result.lines.append("\(error).")
    }
    return result
  }

  private enum Planning {
    case planned([WallpaperRestoreStep])
    case unreadable(WallpaperRestoreReport)
  }

  private func steps() -> Planning {
    do {
      let originals = try WallpaperOriginalStore(root: root).load()
      func inspectPlan() throws -> [WallpaperRestoreStep] {
        let displays = try control.inspect().map { display in
          WallpaperConnectedDisplay(
            id: display.id,
            uuid: try control.displayUUID(display.id),
            name: display.name,
            wallpaperURL: display.wallpaperURL
          )
        }
        return WallpaperOriginals.restorationPlan(
          originals: originals,
          displays: displays,
          isMacarchyWallpaper: WallpaperOwnership(root: root).isMacarchyWallpaper,
          originalExists: originalExists
        )
      }
      var steps = try inspectPlan()
      // NSWorkspace can briefly return DefaultDesktop rather than the displayed image after
      // native look restoration. Give an owned/original image the same bounded readback budget
      // as a set before treating an external path as a user change. A persistent user choice,
      // including the system default, is still kept; no fallback path is claimed as owned.
      for _ in 0..<8 {
        guard
          steps.contains(where: {
            if case .keepUserChange = $0 { return true }
            return false
          })
        else { break }
        waitForSettle()
        steps = try inspectPlan()
      }
      return .planned(steps)
    } catch {
      return .unreadable(
        Self.unchanged(
          "Original wallpapers could not be read, so wallpaper was left unchanged: \(error)."))
    }
  }

  /// The step indexes whose display still does not show its original after a bounded wait.
  private func settle(_ requested: [Int: (original: WallpaperOriginal, displayID: UInt32)])
    -> Set<Int>
  {
    var pending = Set(requested.keys)
    for attempt in 0..<9 where !pending.isEmpty {
      if attempt > 0 { waitForSettle() }
      guard let shown = try? control.inspect() else { continue }
      pending = pending.filter { index in
        guard let request = requested[index],
          let display = shown.first(where: { $0.id == request.displayID })
        else { return true }
        return display.wallpaperURL.standardizedFileURL.path != request.original.imagePath
      }
    }
    return pending
  }

  private static func unchanged(_ line: String) -> WallpaperRestoreReport {
    WallpaperRestoreReport(lines: [line], mutated: false, consumesRecord: false)
  }

  private static func line(_ step: WallpaperRestoreStep, dryRun: Bool) -> String {
    switch step {
    case .restore(let original, _):
      dryRun
        ? "Would restore the original wallpaper on '\(original.displayName)'."
        : "Restored the original wallpaper on '\(original.displayName)'."
    case .alreadyOriginal(let original):
      "'\(original.displayName)' already shows its original wallpaper."
    case .keepUserChange(let original):
      "Kept the wallpaper on '\(original.displayName)', which was changed after Macarchy set it."
    case .originalMissing(let original):
      "The original wallpaper for '\(original.displayName)' no longer exists at "
        + "\(original.imagePath); choose another in System Settings."
    case .disconnected(let original):
      "Display '\(original.displayName)' is not connected; its original wallpaper was "
        + "\(original.imagePath)."
    case .unrecorded(let displayName):
      "No original wallpaper was recorded for '\(displayName)'; choose one in System Settings."
    }
  }
}

/// Whether a wallpaper is one Macarchy rendered: any image inside this state root's generations.
struct WallpaperOwnership: Sendable {
  private let prefixes: [String]

  init(root: URL) {
    let generations = root.standardizedFileURL.appending(
      path: "generations", directoryHint: .isDirectory)
    prefixes = Set([generations.path, generations.resolvingSymlinksInPath().path]).map {
      $0.hasSuffix("/") ? $0 : $0 + "/"
    }
  }

  func isMacarchyWallpaper(_ url: URL) -> Bool {
    let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
    return paths.contains { path in prefixes.contains { path.hasPrefix($0) } }
  }
}
