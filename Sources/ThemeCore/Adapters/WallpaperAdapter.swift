import AppKit
import Foundation

enum WallpaperAdapterError: Error, CustomStringConvertible, Equatable, Sendable {
  case duplicateDisplayID(UInt32)
  case missingDisplayID(String)
  case noDisplays
  case unreadableOptions(String)
  case unreadableWallpaper(String)
  case unavailableDisplay(UInt32)
  case unidentifiableDisplay(UInt32)

  var description: String {
    switch self {
    case .duplicateDisplayID(let id):
      "NSWorkspace returned duplicate display identifier \(id)"
    case .missingDisplayID(let name):
      "Cannot identify display '\(name)'"
    case .noDisplays:
      "NSWorkspace did not return any current displays"
    case .unreadableOptions(let name):
      "Cannot read wallpaper presentation options for display '\(name)'"
    case .unreadableWallpaper(let name):
      "Cannot read the current wallpaper for display '\(name)'"
    case .unavailableDisplay(let id):
      "Display \(id) is no longer available"
    case .unidentifiableDisplay(let id):
      "Cannot read the persistent identity of display \(id)"
    }
  }
}

struct WallpaperDisplay: Equatable, Sendable {
  let id: UInt32
  let name: String
  let wallpaperURL: URL
}

struct WallpaperControl: Sendable {
  let inspect: @Sendable () throws -> [WallpaperDisplay]
  /// Changes a display's image and keeps its presentation options.
  let set: @Sendable (URL, UInt32) throws -> Void
  /// A display's persistent UUID, which outlives its display number.
  let displayUUID: @Sendable (UInt32) throws -> String
  let presentation: @Sendable (UInt32) throws -> WallpaperPresentation
  /// Puts back an original image together with its recorded presentation options.
  let restore: @Sendable (URL, WallpaperPresentation, UInt32) throws -> Void

  /// Test doubles may omit the identity and presentation seams; `restore` then falls back to
  /// `set`, which keeps the current options.
  init(
    inspect: @escaping @Sendable () throws -> [WallpaperDisplay],
    set: @escaping @Sendable (URL, UInt32) throws -> Void,
    displayUUID: @escaping @Sendable (UInt32) throws -> String = { "display-\($0)" },
    presentation: @escaping @Sendable (UInt32) throws -> WallpaperPresentation = { _ in
      WallpaperPresentation()
    },
    restore: (@Sendable (URL, WallpaperPresentation, UInt32) throws -> Void)? = nil
  ) {
    self.inspect = inspect
    self.set = set
    self.displayUUID = displayUUID
    self.presentation = presentation
    self.restore = restore ?? { url, _, displayID in try set(url, displayID) }
  }

  static let live = Self(
    inspect: {
      try onMainThread {
        try NSScreen.screens.map { screen in
          let name = screen.localizedName
          guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
              as? NSNumber
          else {
            throw WallpaperAdapterError.missingDisplayID(name)
          }
          guard let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            throw WallpaperAdapterError.unreadableWallpaper(name)
          }
          guard NSWorkspace.shared.desktopImageOptions(for: screen) != nil else {
            throw WallpaperAdapterError.unreadableOptions(name)
          }
          return WallpaperDisplay(
            id: number.uint32Value,
            name: name,
            wallpaperURL: wallpaperURL
          )
        }
      }
    },
    set: { wallpaperURL, displayID in
      try onMainThread {
        let screen = try screen(displayID)
        guard let options = NSWorkspace.shared.desktopImageOptions(for: screen) else {
          throw WallpaperAdapterError.unreadableOptions(screen.localizedName)
        }
        try NSWorkspace.shared.setDesktopImageURL(
          wallpaperURL,
          for: screen,
          options: options
        )
      }
    },
    displayUUID: { displayID in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
        let string = CFUUIDCreateString(nil, uuid).map({ $0 as String })
      else {
        throw WallpaperAdapterError.unidentifiableDisplay(displayID)
      }
      return string
    },
    presentation: { displayID in
      try onMainThread {
        let screen = try screen(displayID)
        guard let options = NSWorkspace.shared.desktopImageOptions(for: screen) else {
          throw WallpaperAdapterError.unreadableOptions(screen.localizedName)
        }
        return WallpaperPresentation(options)
      }
    },
    restore: { wallpaperURL, presentation, displayID in
      try onMainThread {
        try NSWorkspace.shared.setDesktopImageURL(
          wallpaperURL,
          for: try screen(displayID),
          options: presentation.options
        )
      }
    }
  )

  private static func screen(_ displayID: UInt32) throws -> NSScreen {
    guard
      let screen = NSScreen.screens.first(where: { screen in
        let number =
          screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
        return number?.uint32Value == displayID
      })
    else {
      throw WallpaperAdapterError.unavailableDisplay(displayID)
    }
    return screen
  }

  private static func onMainThread<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) throws -> Value {
    if Thread.isMainThread { return try operation() }
    return try DispatchQueue.main.sync(execute: operation)
  }
}

struct WallpaperAdapter: Sendable {
  static let id = "wallpaper"
  static let outputPath = "generated/wallpaper.png"
  static let rendererVersion = 1

  private let activationLock: ActivationLock
  private let control: WallpaperControl
  private let originals: WallpaperOriginalStore
  private let ownership: WallpaperOwnership
  private let waitForSettle: @Sendable () -> Void
  private let now: @Sendable () -> String

  init(
    root: URL,
    control: WallpaperControl,
    waitForSettle: @escaping @Sendable () -> Void = {
      Thread.sleep(forTimeInterval: 0.25)
    },
    now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
  ) {
    activationLock = ActivationLock(root: root)
    self.control = control
    originals = WallpaperOriginalStore(root: root)
    ownership = WallpaperOwnership(root: root)
    self.waitForSettle = waitForSettle
    self.now = now
  }

  func preflight() throws -> [WallpaperDisplay] {
    let displays = try control.inspect()
    guard !displays.isEmpty else { throw WallpaperAdapterError.noDisplays }
    var ids = Set<UInt32>()
    for display in displays {
      guard ids.insert(display.id).inserted else {
        throw WallpaperAdapterError.duplicateDisplayID(display.id)
      }
    }
    return displays
  }

  func inspection(desiredWallpaperURL: URL?) -> AdapterInspection {
    do {
      let displays = try preflight()
      if let desiredWallpaperURL,
        displays.contains(where: { !Self.sameFile($0.wallpaperURL, desiredWallpaperURL) })
      {
        return AdapterInspection(
          .wallpaper,
          status: .drifted,
          message:
            "One or more current displays differ from the active wallpaper; reconciliation will update them through NSWorkspace"
        )
      }
      return AdapterInspection(
        .wallpaper,
        message:
          "Wallpaper and presentation options are readable for \(displays.count) current display(s); inactive Spaces require lazy reconciliation"
      )
    } catch {
      return AdapterInspection(
        .wallpaper,
        status: .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation(
    desiredWallpaperURL: @escaping @Sendable () throws -> URL?
  ) -> AdapterReconciliation {
    AdapterReconciliation(.wallpaper) {
      let preparation: Preparation = try activationLock.withLock {
        guard let desiredWallpaperURL = try desiredWallpaperURL() else {
          return .finished(
            AdapterOutcome(
              status: .disabled,
              message: "This theme has no backgrounds; macOS wallpaper is intentionally unmanaged"
            )
          )
        }
        let before = try preflight()
        let changing = before.filter { !Self.sameFile($0.wallpaperURL, desiredWallpaperURL) }
        let notice: String?
        do {
          notice = try recordOriginals(of: changing)
        } catch {
          return .finished(
            AdapterOutcome(
              status: .failed,
              message:
                "Cannot record the original wallpaper, so it was left unchanged: \(error)"
            )
          )
        }
        for display in changing {
          do {
            try control.set(desiredWallpaperURL, display.id)
          } catch {
            return .finished(
              AdapterOutcome(
                status: .failed,
                message: "Cannot set wallpaper for display '\(display.name)': \(error)"
              )
            )
          }
        }
        return .applied(desiredWallpaperURL, before, notice)
      }
      let desiredWallpaperURL: URL
      let before: [WallpaperDisplay]
      let notice: String?
      switch preparation {
      case .finished(let outcome):
        return outcome
      case .applied(let url, let displays, let originalsNotice):
        desiredWallpaperURL = url
        before = displays
        notice = originalsNotice
      }

      // Settling only observes state; release the lock so it cannot delay other live adapters.
      let outcome = try settle(on: desiredWallpaperURL, displays: before)
      guard let notice else { return outcome }
      return AdapterOutcome(
        status: outcome.status,
        message: [outcome.message, notice].compactMap { $0 }.joined(separator: "; ")
      )
    }
  }

  private func settle(on desiredWallpaperURL: URL, displays before: [WallpaperDisplay]) throws
    -> AdapterOutcome
  {
    var drifted = [WallpaperDisplay]()
    for attempt in 0..<9 {
      let after = try preflight()
      guard Set(after.map(\.id)) == Set(before.map(\.id)) else {
        return AdapterOutcome(
          status: .drifted,
          message: "The current display inventory changed while wallpaper was applied"
        )
      }
      drifted = after.filter { !Self.sameFile($0.wallpaperURL, desiredWallpaperURL) }
      if drifted.isEmpty {
        return AdapterOutcome(status: .applied)
      }
      if attempt < 8 { waitForSettle() }
    }
    return AdapterOutcome(
      status: .drifted,
      message:
        "NSWorkspace did not settle on the requested wallpaper for: "
        + drifted.map(\.name).joined(separator: ", ")
    )
  }

  /// Records the wallpaper of each display Macarchy is about to change for the first time, so
  /// setup teardown can put it back. An unreadable record is kept as it is and only noticed: it
  /// may still hold originals, and replacing it would lose them. A record that cannot be written
  /// throws, so the wallpaper is not changed without one.
  private func recordOriginals(of displays: [WallpaperDisplay]) throws -> String? {
    guard !displays.isEmpty else { return nil }
    let existing: [WallpaperOriginal]
    do {
      existing = try originals.load()
    } catch {
      return "original wallpapers could not be read, so teardown cannot restore them: \(error)"
    }
    let updated = try WallpaperOriginals.capturing(
      existing,
      displays: displays,
      isMacarchyWallpaper: ownership.isMacarchyWallpaper,
      describe: { display in
        (try control.displayUUID(display.id), try control.presentation(display.id))
      },
      now: now()
    )
    if updated != existing { try originals.persist(updated) }
    return nil
  }

  private enum Preparation {
    case finished(AdapterOutcome)
    case applied(URL, [WallpaperDisplay], String?)
  }

  private static func sameFile(_ first: URL, _ second: URL) -> Bool {
    first.standardizedFileURL.path == second.standardizedFileURL.path
  }
}

// The wallpaper consumer is the desktop wallpaper, its Photos-source projection and the yabai
// signal that converges inactive Spaces; these merge the three into its one status.
extension WallpaperAdapter {
  func consumerInspection(
    photos: ScreenSaverImageStore,
    signal wallpaperSignal: YabaiWallpaperSignal,
    processRunner: ProcessRunner,
    desiredWallpaperURL: URL?,
    intentionallyUnmanaged: Bool,
    includeRuntimeChecks: Bool
  ) -> AdapterInspection {
    guard !intentionallyUnmanaged else {
      return AdapterInspection(
        .wallpaper,
        message:
          "The active theme has no backgrounds; desktop wallpaper and the Photos source retain their previous images"
      )
    }
    let desktopInspection = inspection(
      desiredWallpaperURL: desiredWallpaperURL
    )
    let photosInspection = photos.inspection()
    let wallpaperInspection = AdapterInspection(
      .wallpaper,
      status: Self.mostSevere(desktopInspection.status, photosInspection.status),
      message: [desktopInspection.message, photosInspection.message].compactMap { $0 }.joined(
        separator: "; ")
    )
    do {
      try wallpaperSignal.preflight()
      if includeRuntimeChecks {
        try wallpaperSignal.runtimePreflight(processRunner: processRunner)
      }
      var messages = [wallpaperInspection.message, wallpaperSignal.readyMessage].compactMap { $0 }
      if includeRuntimeChecks {
        messages.append("the yabai signal is loaded")
      }
      return AdapterInspection(
        .wallpaper,
        status: wallpaperInspection.status,
        message: messages.joined(separator: "; ")
      )
    } catch {
      return AdapterInspection(
        .wallpaper,
        status: Self.mostSevere(
          wallpaperInspection.status, Self.isSignalDrift(error) ? .drifted : .failed),
        message: [wallpaperInspection.message, String(describing: error)]
          .compactMap { $0 }
          .joined(separator: "; ")
      )
    }
  }

  func consumerReconciliation(
    photos: ScreenSaverImageStore,
    signal wallpaperSignal: YabaiWallpaperSignal,
    desiredWallpaperURL: @escaping @Sendable () throws -> URL?
  ) -> AdapterReconciliation {
    AdapterReconciliation(.wallpaper) {
      let wallpaperOutcome = try await reconciliation(
        desiredWallpaperURL: desiredWallpaperURL
      ).run()
      // The Photos folder is a projection of this same wallpaper consumer,
      // not another environment role or a native screensaver settings owner.
      // Prepare it only after the native desktop repaint path has finished.
      var messages = [wallpaperOutcome.message].compactMap { $0 }
      do {
        messages.append(try photos.reconcile())
      } catch {
        messages.append("Photos source failed: \(error)")
        return AdapterOutcome(
          status: .failed,
          message: "Desktop wallpaper: \(wallpaperOutcome.status.rawValue); "
            + messages.joined(separator: "; ")
        )
      }
      guard wallpaperOutcome.status == .applied else {
        return AdapterOutcome(
          status: wallpaperOutcome.status, message: messages.joined(separator: "; "))
      }
      do {
        try wallpaperSignal.preflight()
        return AdapterOutcome(status: .applied, message: messages.joined(separator: "; "))
      } catch {
        let status: AdapterStatus = Self.isSignalDrift(error) ? .drifted : .failed
        messages.append(String(describing: error))
        return AdapterOutcome(status: status, message: messages.joined(separator: "; "))
      }
    }
  }

  /// A missing directive or unloaded signal is repairable drift, not a failure.
  private static func isSignalDrift(_ error: any Error) -> Bool {
    switch error {
    case YabaiWallpaperSignalError.missingDirective, YabaiWallpaperSignalError.runtimeSignalMissing:
      true
    default:
      false
    }
  }

  private static func mostSevere(
    _ first: AdapterInspectionStatus,
    _ second: AdapterInspectionStatus
  ) -> AdapterInspectionStatus {
    if first == .failed || second == .failed { return .failed }
    if first == .drifted || second == .drifted { return .drifted }
    return .ready
  }
}
