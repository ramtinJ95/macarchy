import CoreGraphics
import Foundation

/// Moves only Macarchy's own outline window through a committed SkyLight transaction.
/// The connection and window are bound at creation; `move(to:)` cannot target any
/// other window, and ownership is rechecked before every mutation.
@MainActor
final class SkyLightOutlineMover {
  private typealias GetWindowOwner =
    @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
  private typealias TransactionCreate = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
  // Move and Commit are bound as Void. Read-only disassembly of the 25G83 guest
  // (macOS 26.6.2) shows Move returns the last internal helper's x0 with no CGError
  // set before the epilogue, and Commit returns an internal cleanup result rather
  // than the MIG status; a runtime Move "status" of 1121830592 was this residue.
  // Neither has a trustworthy CGError contract here. Bind without a return value
  // and use an explicit committed-position postcondition instead.
  private typealias TransactionMoveWindow = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
  private typealias TransactionCommit = @convention(c) (CFTypeRef, Int32) -> Void
  private typealias GetWindowBounds =
    @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

  let windowID: UInt32
  private let connection: Int32
  /// Retained so the dlopen handle outlives the resolved function pointers.
  private let library: SkyLightLibrary
  private let windowOwner: GetWindowOwner
  private let createTransaction: TransactionCreate
  private let moveWindow: TransactionMoveWindow
  private let commitTransaction: TransactionCommit
  private let windowBounds: GetWindowBounds

  init(library: SkyLightLibrary, connection: Int32, windowID: UInt32) throws {
    self.library = library
    self.connection = connection
    self.windowID = windowID
    windowOwner = try library.symbol("SLSGetWindowOwner")
    createTransaction = try library.symbol("SLSTransactionCreate")
    moveWindow = try library.symbol("SLSTransactionMoveWindowWithGroup")
    commitTransaction = try library.symbol("SLSTransactionCommit")
    windowBounds = try library.symbol("SLSGetWindowBounds")
    try verifyOwnership()
  }

  /// `origin` is the window's top-left in window-server global coordinates (y down).
  func move(to origin: CGPoint) throws {
    guard origin.x.isFinite, origin.y.isFinite else {
      throw FocusRingError("outline origin \(origin) is not finite")
    }
    try verifyOwnership()
    guard let transaction = createTransaction(connection)?.takeRetainedValue() else {
      throw FocusRingError("SLSTransactionCreate returned no transaction")
    }
    moveWindow(transaction, windowID, origin)
    commitTransaction(transaction, 0)
    // Single query, no polling: the committed frame must already be at `origin`.
    try verifyCommittedOrigin(origin)
  }

  private func verifyCommittedOrigin(_ requested: CGPoint) throws {
    var bounds = CGRect.zero
    let status = windowBounds(connection, windowID, &bounds)
    guard status == 0 else {
      throw FocusRingError("SLSGetWindowBounds failed for window \(windowID) (\(status))")
    }
    try Self.validateCommittedBounds(actual: bounds, requestedOrigin: requested)
  }

  nonisolated static let originTolerance: CGFloat = 0.5

  /// Direct transactions are only for pure position changes of an already
  /// visible panel. AppKit owns the first show and every resize.
  nonisolated static func shouldMoveDirectly(previous: CGRect, next: CGRect, isVisible: Bool)
    -> Bool
  {
    isVisible && previous.size == next.size && previous.origin != next.origin
  }

  /// The committed frame must have a finite origin within `originTolerance` of the
  /// request on each axis and a finite, positive size.
  nonisolated static func validateCommittedBounds(
    actual: CGRect, requestedOrigin: CGPoint
  ) throws {
    let origin = actual.origin
    let size = actual.size
    guard origin.x.isFinite, origin.y.isFinite else {
      throw FocusRingError("committed outline origin \(origin) is not finite")
    }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw FocusRingError("committed outline size \(size) is invalid")
    }
    guard abs(origin.x - requestedOrigin.x) <= originTolerance,
      abs(origin.y - requestedOrigin.y) <= originTolerance
    else {
      throw FocusRingError(
        "committed outline origin \(origin) does not match requested \(requestedOrigin)")
    }
  }

  private func verifyOwnership() throws {
    var owner: Int32 = 0
    let status = windowOwner(connection, windowID, &owner)
    try Self.validateOwnership(
      connection: connection, windowID: windowID, status: status, owner: owner)
  }

  /// Movement is allowed only for a positive window owned by this process's positive connection.
  nonisolated static func validateOwnership(
    connection: Int32, windowID: UInt32, status: Int32, owner: Int32
  ) throws {
    guard connection > 0 else {
      throw FocusRingError("own connection \(connection) is invalid")
    }
    guard windowID > 0 else { throw FocusRingError("outline window ID 0 is invalid") }
    guard status == 0 else {
      throw FocusRingError("SLSGetWindowOwner failed for window \(windowID) (\(status))")
    }
    guard owner == connection else {
      throw FocusRingError(
        "window \(windowID) is owned by connection \(owner), not \(connection)")
    }
  }
}
