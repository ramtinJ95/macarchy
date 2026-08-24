import AppKit
import Foundation

enum WallpaperAdapterError: Error, CustomStringConvertible, Equatable, Sendable {
  case duplicateDisplayID(UInt32)
  case missingDisplayID(String)
  case noDisplays
  case unreadableOptions(String)
  case unreadableWallpaper(String)
  case unavailableDisplay(UInt32)

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
  let set: @Sendable (URL, UInt32) throws -> Void

  static let live = Self(
    inspect: {
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
    },
    set: { wallpaperURL, displayID in
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
      guard let options = NSWorkspace.shared.desktopImageOptions(for: screen) else {
        throw WallpaperAdapterError.unreadableOptions(screen.localizedName)
      }
      try NSWorkspace.shared.setDesktopImageURL(
        wallpaperURL,
        for: screen,
        options: options
      )
    }
  )
}

struct WallpaperAdapter: Sendable {
  static let id = "wallpaper"
  static let outputPath = "generated/wallpaper.png"
  static let rendererVersion = 1

  private let activationLock: ActivationLock
  private let control: WallpaperControl
  private let waitForSettle: @Sendable () -> Void

  init(
    root: URL,
    control: WallpaperControl,
    waitForSettle: @escaping @Sendable () -> Void = {
      Thread.sleep(forTimeInterval: 0.25)
    }
  ) {
    activationLock = ActivationLock(root: root)
    self.control = control
    self.waitForSettle = waitForSettle
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
          adapterID: Self.id,
          requirement: .required,
          status: .drifted,
          message:
            "One or more current displays differ from the active wallpaper; reconciliation will update them through NSWorkspace"
        )
      }
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        message:
          "Wallpaper and presentation options are readable for \(displays.count) current display(s); inactive Spaces require lazy reconciliation"
      )
    } catch {
      return AdapterInspection(
        adapterID: Self.id,
        requirement: .required,
        status: .failed,
        message: String(describing: error)
      )
    }
  }

  func reconciliation(
    desiredWallpaperURL: @escaping @Sendable () throws -> URL
  ) -> AdapterReconciliation {
    AdapterReconciliation(id: Self.id, requirement: .required) {
      let preparation: (URL, [WallpaperDisplay], AdapterOutcome?) = try activationLock.withLock {
        let desiredWallpaperURL = try desiredWallpaperURL()
        let before = try preflight()
        for display in before
        where !Self.sameFile(display.wallpaperURL, desiredWallpaperURL) {
          do {
            try control.set(desiredWallpaperURL, display.id)
          } catch {
            return (
              desiredWallpaperURL,
              before,
              AdapterOutcome(
                status: .failed,
                message: "Cannot set wallpaper for display '\(display.name)': \(error)"
              )
            )
          }
        }
        return (desiredWallpaperURL, before, nil)
      }
      let (desiredWallpaperURL, before, failure) = preparation
      if let failure { return failure }

      // Settling only observes state; release the lock so it cannot delay other live adapters.
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
  }

  private static func sameFile(_ first: URL, _ second: URL) -> Bool {
    first.standardizedFileURL.path == second.standardizedFileURL.path
  }
}
