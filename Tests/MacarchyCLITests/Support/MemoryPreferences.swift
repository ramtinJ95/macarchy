import Foundation
import Synchronization

@testable import MacarchyCLI
@testable import ThemeCore

/// In-memory macOS preferences that record reads and writes and can inject write failures.
final class MemoryPreferences: Sendable {
  struct State {
    var values: [MacOSPreference: Bool] = [.dockAutohide: false, .finderShowExtensions: false]
    var reads: [MacOSPreference] = []
    var writes: [MacOSPreference] = []
    var rejectWrite: Int?
    var uncertainWrite: Int?
    var crash = false
  }
  let state = Mutex(State())
  var native: NativeMacOSPreferences {
    .init(
      read: { key in
        self.state.withLock {
          $0.reads.append(key)
          return $0.values[key]!
        }
      },
      write: { key, value in
        try self.state.withLock { state in
          state.writes.append(key)
          if state.rejectWrite == state.writes.count {
            throw PreferencesError.unavailable("injected rejection")
          }
          state.values[key] = value
          if state.uncertainWrite == state.writes.count {
            if state.crash { throw PreferencesInterruption.injected }
            throw PreferencesError.uncertain("injected missing reply")
          }
        }
      })
  }
}
