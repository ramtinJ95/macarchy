import CoreGraphics

/// One helper decision. Observations are not pixel evidence and carry no window titles.
struct FocusRingObservation: Encodable, Equatable, Sendable {
  struct Frame: Encodable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
      x = rect.minX
      y = rect.minY
      width = rect.width
      height = rect.height
    }
  }

  /// Monotonic seconds since the helper started.
  var uptime: Double
  var visible: Bool
  var reason: String
  var targetWindowID: UInt32?
  var frame: Frame?
  var generationID: String
  var accent: String

  enum CodingKeys: String, CodingKey {
    case uptime, visible, reason, frame, accent
    case targetWindowID = "target_window_id"
    case generationID = "generation_id"
  }

  func hasSameState(as other: Self) -> Bool {
    var aligned = other
    aligned.uptime = uptime
    return aligned == self
  }
}

/// Records state changes only, capped so a long run cannot grow without bound.
struct FocusRingDiagnostics: Sendable {
  static let capacity = 1024

  private(set) var observations: [FocusRingObservation] = []
  private(set) var dropped = 0
  private var latest: FocusRingObservation?

  mutating func record(_ observation: FocusRingObservation) {
    if let latest, latest.hasSameState(as: observation) { return }
    latest = observation
    if observations.count < Self.capacity {
      observations.append(observation)
    } else {
      dropped += 1
    }
  }
}

struct FocusRingReport: Encodable {
  let selection = FocusTargetPolicy.selectionLabel
  let updateDriver = "window-server-events"
  let outcome: String
  let stopReason: String
  let error: String?
  let seconds: Double
  let observations: [FocusRingObservation]
  let droppedObservations: Int
  let eventCount: Int
  let fullRefreshCount: Int
  let geometryRefreshCount: Int
  let watchdogRefreshCount: Int
  let movementDriver = "appkit-plus-own-window-transaction"
  let directMoveCount: Int
  let notice =
    "Helper decisions recorded after cleanup; not pixel, exact-focus or performance evidence. Memory is not measured by the helper."

  enum CodingKeys: String, CodingKey {
    case selection, outcome, error, seconds, observations, notice
    case stopReason = "stop_reason"
    case droppedObservations = "dropped_observations"
    case updateDriver = "update_driver"
    case eventCount = "event_count"
    case fullRefreshCount = "full_refresh_count"
    case geometryRefreshCount = "geometry_refresh_count"
    case watchdogRefreshCount = "watchdog_refresh_count"
    case movementDriver = "movement_driver"
    case directMoveCount = "direct_move_count"
  }
}
