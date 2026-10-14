import Foundation

/// Coalesced window-server notifications awaiting one main-queue delivery.
/// `settle` asks the session for one follow-up refresh shortly afterwards.
struct FocusEventBatch: Equatable, Sendable {
  var geometryIDs: Set<UInt32> = []
  var requiresFullRefresh = false
  var settle = false
  var count = 0

  static let windowEvents: Set<UInt32> = [804, 806, 807, 808, 811, 815, 816, 1322]
  static let globalEvents: Set<UInt32> = [723, 1325, 1326, 1401, 1508]
  static let geometryEvents: Set<UInt32> = [806, 807]
  static let settleEvents: Set<UInt32> = [723, 808, 1322, 1401, 1508]

  /// Merges one callback; returns false when the event is filtered out.
  mutating func merge(event: UInt32, windowID: UInt32?, observed: Set<UInt32>, own: UInt32?) -> Bool
  {
    if Self.globalEvents.contains(event) {
      requiresFullRefresh = true
    } else if Self.windowEvents.contains(event) {
      guard let windowID, windowID != own, observed.contains(windowID) else { return false }
      if Self.geometryEvents.contains(event) {
        geometryIDs.insert(windowID)
      } else {
        requiresFullRefresh = true
      }
    } else {
      return false
    }
    if Self.settleEvents.contains(event) { settle = true }
    if count < .max { count += 1 }
    return true
  }
}

/// Window-server notifications on the helper's own SkyLight connection. Delivery
/// relies on the AppKit run loop draining that connection; there is no polling
/// fallback.
final class SkyLightNotifications: @unchecked Sendable {
  typealias NotifyFn =
    @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
  typealias RegisterFn = @convention(c) (NotifyFn, UInt32, UnsafeMutableRawPointer?) -> Int32
  typealias RequestFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32
  typealias Deliver = @MainActor @Sendable (FocusEventBatch) -> Void

  static let events = FocusEventBatch.globalEvents.union(FocusEventBatch.windowEvents).sorted()

  // Retained so registrations leaked by a failed removal keep SkyLight loaded.
  private let library: SkyLightLibrary
  private let connection: Int32
  private let register: RegisterFn
  private let remove: RegisterFn
  private let request: RequestFn
  private let deliver: Deliver

  // Main-actor state.
  private var context: Unmanaged<SkyLightNotifications>?
  private var registered: [UInt32] = []
  private var running = false
  private var requestedIDs: [UInt32]?

  // Callback state, guarded by `lock`.
  private let lock = NSLock()
  private var handler: Deliver?
  private var observed: Set<UInt32> = []
  private var ownID: UInt32?
  private var pending = FocusEventBatch()
  private var scheduled = false

  @MainActor
  init(library: SkyLightLibrary, connection: Int32, deliver: @escaping Deliver) throws {
    self.library = library
    self.connection = connection
    self.deliver = deliver
    register = try library.symbol("SLSRegisterNotifyProc")
    remove = try library.symbol("SLSRemoveNotifyProc")
    request = try library.symbol("SLSRequestNotificationsForWindows")
  }

  @MainActor
  func start() throws {
    guard !running else { return }
    if context != nil {
      throw FocusRingError(
        "SkyLight notification source cannot be restarted; remaining registrations: \(registered)")
    }
    let context = Unmanaged.passRetained(self)
    self.context = context
    running = true
    locked { handler = deliver }
    for event in Self.events {
      let code = register(Self.callback, event, context.toOpaque())
      guard code == 0 else {
        let failure = "SLSRegisterNotifyProc(\(event)) failed: \(code)"
        do { try stop() } catch { throw FocusRingError("\(failure); cleanup: \(error)") }
        throw FocusRingError(failure)
      }
      registered.append(event)
    }
  }

  /// Unregisters callbacks and disables delivery. This bounded, single-session
  /// executable keeps its one callback context alive until process exit, even after
  /// successful removal: the private API supplies no in-flight callback lifetime
  /// guarantee. This is constant process-lifetime state, not per-window retention.
  /// Failed removals are explicit and a later call retries them.
  @MainActor
  func stop() throws {
    running = false
    locked {
      handler = nil
      pending = FocusEventBatch()
    }
    guard let context else { return }
    var failures: [String] = []
    registered = registered.filter { event in
      let code = remove(Self.callback, event, context.toOpaque())
      if code != 0 { failures.append("\(event): \(code)") }
      return code != 0
    }
    guard failures.isEmpty else {
      throw FocusRingError("SLSRemoveNotifyProc failed for \(failures.joined(separator: ", "))")
    }
    // Keep the callback context alive until this bounded helper process exits.
  }

  /// Subscribes the helper connection to window-specific events. Only the
  /// subscription changes; target windows are never mutated.
  @MainActor
  func observe(windowIDs: [UInt32], excluding own: UInt32?) throws {
    let observed = Set(windowIDs.filter { $0 != own })
    var ids = observed.sorted()
    guard ids.count <= Int(Int32.max) else {
      throw FocusRingError("Too many windows to observe: \(ids.count)")
    }
    if ids != requestedIDs {
      let code = ids.withUnsafeMutableBufferPointer {
        request(connection, $0.isEmpty ? nil : $0.baseAddress, Int32($0.count))
      }
      guard code == 0 else {
        throw FocusRingError(
          "SLSRequestNotificationsForWindows(\(ids.count) windows) failed: \(code)")
      }
      requestedIDs = ids
    }
    locked {
      self.observed = observed
      ownID = own
    }
  }

  // Runs on an arbitrary thread: copy the payload before returning and never
  // query SkyLight or AppKit here.
  nonisolated(unsafe) private static let callback: NotifyFn = { event, data, length, context in
    guard let context else { return }
    let windowID =
      FocusEventBatch.windowEvents.contains(event)
      ? data.flatMap { length >= 4 ? $0.loadUnaligned(as: UInt32.self) : nil } : nil
    Unmanaged<SkyLightNotifications>.fromOpaque(context).takeUnretainedValue()
      .receive(event: event, windowID: windowID)
  }

  private func receive(event: UInt32, windowID: UInt32?) {
    let schedule = locked { () -> Bool in
      guard handler != nil,
        pending.merge(event: event, windowID: windowID, observed: observed, own: ownID),
        !scheduled
      else { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated { flush() }
    }
  }

  @MainActor
  private func flush() {
    let (batch, target) = locked { () -> (FocusEventBatch, Deliver?) in
      defer {
        pending = FocusEventBatch()
        scheduled = false
      }
      return (pending, self.handler)
    }
    guard let target, batch.count > 0 else { return }
    target(batch)
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
