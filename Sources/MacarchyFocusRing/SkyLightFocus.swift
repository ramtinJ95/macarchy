import Carbon
import CoreGraphics
import Darwin
import Foundation

struct FocusRingError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

/// The front process's connection and the active menu-bar display's current Space.
struct FrontContext: Equatable, Sendable {
  var ownConnection: Int32
  var frontConnection: Int32
  var displayIdentifier: String
  var spaceID: UInt64
}

// SkyLight publishes no headers; signatures are source-derived from JankyBorders
// 1.9.0. `Copy*` results and the query/iterator handles are owned (+1).
private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias FrontProcessFn =
  @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private typealias ConnectionForPSNFn =
  @convention(c) (
    Int32, UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>
  ) -> Int32
private typealias CopyMenuBarDisplayFn = @convention(c) (Int32) -> Unmanaged<CFString>?
private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CopyWindowsFn =
  @convention(c) (
    Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
  ) -> Unmanaged<CFArray>?
private typealias QueryWindowsFn = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
private typealias QueryCopyWindowsFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
private typealias IteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
private typealias IteratorU32Fn = @convention(c) (CFTypeRef) -> UInt32
private typealias IteratorU64Fn = @convention(c) (CFTypeRef) -> UInt64
private typealias IteratorI32Fn = @convention(c) (CFTypeRef) -> Int32
/// Owned (+1) despite Get: JankyBorders 1.9.0 releases the returned array.
private typealias IteratorCornerRadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
private typealias WindowBoundsFn =
  @convention(c) (
    Int32, UInt32, UnsafeMutablePointer<CGRect>
  ) -> Int32

/// Owns the SkyLight handle so every exit path, including a partially failed
/// `SkyLightFocus.init`, balances `dlopen` with `dlclose`.
final class SkyLightLibrary {
  let handle: UnsafeMutableRawPointer

  init(path: String) throws {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
      throw FocusRingError("cannot load SkyLight: \(reason)")
    }
    self.handle = handle
  }

  deinit { dlclose(handle) }

  /// Only instantiated with the `@convention(c)` aliases above.
  func symbol<T>(_ name: String) throws -> T {
    precondition(MemoryLayout<T>.size == MemoryLayout<UnsafeRawPointer>.size)
    guard let address = dlsym(handle, name) else {
      throw FocusRingError("SkyLight does not export \(name)")
    }
    return unsafeBitCast(address, to: T.self)
  }

  /// Only for symbols whose absence has a documented fallback.
  func optionalSymbol<T>(_ name: String) -> T? {
    precondition(MemoryLayout<T>.size == MemoryLayout<UnsafeRawPointer>.size)
    guard let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }
}

/// Read-only window-server queries for the focus ring. Requests no TCC
/// permission and mutates no window-server state. Failed or empty queries throw;
/// only an empty window list is a normal "no target" result.
final class SkyLightFocus {
  static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

  private let library: SkyLightLibrary
  private(set) var observedWindowIDs: [UInt32] = []
  private let mainConnection: MainConnectionFn
  private let frontProcess: FrontProcessFn
  private let connectionForPSN: ConnectionForPSNFn
  private let copyMenuBarDisplay: CopyMenuBarDisplayFn
  private let currentSpace: CurrentSpaceFn
  private let copyDisplaySpaces: CopyDisplaySpacesFn
  private let copyWindows: CopyWindowsFn
  private let queryWindows: QueryWindowsFn
  private let queryCopyWindows: QueryCopyWindowsFn
  private let iteratorAdvance: IteratorAdvanceFn
  private let iteratorParentID: IteratorU32Fn
  private let iteratorWindowID: IteratorU32Fn
  private let iteratorTags: IteratorU64Fn
  private let iteratorAttributes: IteratorU64Fn
  private let iteratorLevel: IteratorI32Fn
  private let windowBounds: WindowBoundsFn
  private let iteratorCornerRadii: IteratorCornerRadiiFn?

  init(path: String = SkyLightFocus.frameworkPath) throws {
    let library = try SkyLightLibrary(path: path)
    self.library = library
    mainConnection = try library.symbol("SLSMainConnectionID")
    frontProcess = try library.symbol("_SLPSGetFrontProcess")
    connectionForPSN = try library.symbol("SLSGetConnectionIDForPSN")
    copyMenuBarDisplay = try library.symbol("SLSCopyActiveMenuBarDisplayIdentifier")
    currentSpace = try library.symbol("SLSManagedDisplayGetCurrentSpace")
    copyDisplaySpaces = try library.symbol("SLSCopyManagedDisplaySpaces")
    copyWindows = try library.symbol("SLSCopyWindowsWithOptionsAndTags")
    queryWindows = try library.symbol("SLSWindowQueryWindows")
    queryCopyWindows = try library.symbol("SLSWindowQueryResultCopyWindows")
    iteratorAdvance = try library.symbol("SLSWindowIteratorAdvance")
    iteratorParentID = try library.symbol("SLSWindowIteratorGetParentID")
    iteratorWindowID = try library.symbol("SLSWindowIteratorGetWindowID")
    iteratorTags = try library.symbol("SLSWindowIteratorGetTags")
    iteratorAttributes = try library.symbol("SLSWindowIteratorGetAttributes")
    iteratorLevel = try library.symbol("SLSWindowIteratorGetLevel")
    windowBounds = try library.symbol("SLSGetWindowBounds")
    iteratorCornerRadii = library.optionalSymbol("SLSWindowIteratorGetCornerRadii")
  }

  @MainActor
  func newNotifications(
    deliver: @escaping @MainActor @Sendable (FocusEventBatch) -> Void
  ) throws -> SkyLightNotifications {
    try SkyLightNotifications(library: library, connection: mainConnection(), deliver: deliver)
  }

  @MainActor
  func newOutlineMover(windowID: UInt32) throws -> SkyLightOutlineMover {
    try SkyLightOutlineMover(library: library, connection: mainConnection(), windowID: windowID)
  }

  func frontContext() throws -> FrontContext {
    let own = mainConnection()
    guard own != 0 else { throw FocusRingError("SLSMainConnectionID returned no connection") }
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    let status = frontProcess(&psn)
    guard status == 0 else { throw FocusRingError("_SLPSGetFrontProcess failed (\(status))") }
    // kNoProcess may be transient during app switches; report it rather than guess.
    guard psn.highLongOfPSN != 0 || psn.lowLongOfPSN != 0 else {
      throw FocusRingError("no front process")
    }
    var front: Int32 = 0
    let lookup = connectionForPSN(own, &psn, &front)
    guard lookup == 0, front != 0 else {
      throw FocusRingError("SLSGetConnectionIDForPSN failed (\(lookup))")
    }
    guard let display = copyMenuBarDisplay(own)?.takeRetainedValue() else {
      throw FocusRingError("no active menu-bar display")
    }
    let space = currentSpace(own, display)
    guard space != 0 else { throw FocusRingError("display \(display) reports no current Space") }
    return FrontContext(
      ownConnection: own, frontConnection: front,
      displayIdentifier: display as String, spaceID: space)
  }

  func spaceKind(in context: FrontContext) throws -> SpaceKind {
    guard let displays = copyDisplaySpaces(context.ownConnection)?.takeRetainedValue() else {
      throw FocusRingError("SLSCopyManagedDisplaySpaces returned nothing")
    }
    return try SpaceClassifier.classify(
      displays: Array(displays as NSArray),
      displayIdentifier: context.displayIdentifier, spaceID: context.spaceID)
  }

  /// Copy options 0x2, tags set 1 / clear 0 and query options 0 match JankyBorders 1.9.0
  /// (`src/misc/extern.h` declares the third query argument as options; `window.h` passes 0).
  func firstSuitableWindow(
    in context: FrontContext, excluding outlineWindowID: UInt32?
  ) throws -> WindowCandidate? {
    var setTags: UInt64 = 1
    var clearTags: UInt64 = 0
    let spaces = [NSNumber(value: context.spaceID)] as CFArray
    let owner = UInt32(bitPattern: context.frontConnection)
    guard
      let windows = copyWindows(
        context.ownConnection, owner, spaces, 0x2, &setTags, &clearTags
      )?.takeRetainedValue()
    else { throw FocusRingError("SLSCopyWindowsWithOptionsAndTags returned no list") }
    let count = CFArrayGetCount(windows)
    // Every front-connection window is exposed for subscription; an unknown shape fails.
    let numbers = (windows as NSArray).compactMap { $0 as? NSNumber }
    let ids = numbers.compactMap { UInt32(exactly: $0.doubleValue) }
    guard numbers.count == count, ids.count == count, !ids.contains(0) else {
      throw FocusRingError("front connection window list has an unexpected shape")
    }
    observedWindowIDs = ids
    guard count > 0 else { return nil }
    guard
      let query = queryWindows(context.ownConnection, windows, 0)?
        .takeRetainedValue()
    else { throw FocusRingError("SLSWindowQueryWindows returned no query") }
    return try withExtendedLifetime(query) {
      guard let iterator = queryCopyWindows(query)?.takeRetainedValue() else {
        throw FocusRingError("SLSWindowQueryResultCopyWindows returned no iterator")
      }
      while iteratorAdvance(iterator) {
        var candidate = WindowCandidate(
          windowID: iteratorWindowID(iterator), parentID: iteratorParentID(iterator),
          tags: iteratorTags(iterator), attributes: iteratorAttributes(iterator),
          level: iteratorLevel(iterator))
        if FocusTargetPolicy.isSuitable(candidate, excluding: outlineWindowID) {
          candidate.cornerRadius = cornerRadius(at: iterator)
          return candidate
        }
      }
      return nil
    }
  }

  /// First integer radius, or the incumbent's documented 9-point fallback when
  /// the optional symbol or a usable radius is absent.
  private func cornerRadius(at iterator: CFTypeRef) -> CGFloat {
    guard let radii = iteratorCornerRadii?(iterator)?.takeRetainedValue() else {
      return OutlineGeometry.resolvedCornerRadius(nil)
    }
    let first = (radii as NSArray).firstObject as? NSNumber
    return OutlineGeometry.resolvedCornerRadius(first.map { CGFloat($0.intValue) })
  }

  func bounds(of windowID: UInt32, connection: Int32) throws -> CGRect {
    var rect = CGRect.zero
    let status = windowBounds(connection, windowID, &rect)
    guard status == 0 else {
      throw FocusRingError("SLSGetWindowBounds failed for window \(windowID) (\(status))")
    }
    let finite = [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    guard finite, rect.width > 0, rect.height > 0 else {
      throw FocusRingError("window \(windowID) has unusable bounds \(rect)")
    }
    return rect
  }
}
