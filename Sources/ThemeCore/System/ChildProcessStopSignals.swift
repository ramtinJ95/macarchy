import Darwin
import Foundation
import Synchronization

// Signal dispositions are process-wide. A second owner must not restore handlers while
// the first still owns children; scope the lock to this synchronous lifetime, never an await.
private let childSignalLock = NSLock()

/// Reuses the preview's scoped signal pattern: delay termination until the child owner has
/// cleaned up. A script invocation re-raises the received signal with its default action;
/// previews instead restore their prior handlers and return their lifecycle report.
package func withChildProcessStopSignals<T>(
  reraise: Bool = false,
  _ body: (_ received: () -> Int32?) throws -> T
) rethrows -> T {
  childSignalLock.lock()
  defer { childSignalLock.unlock() }
  let received = Mutex<Int32?>(nil)
  let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
  let priorHandlers = handledSignals.map { Darwin.signal($0, SIG_IGN) }
  let queue = DispatchQueue(label: "macarchy.child-stop-signals")
  let cancelled = DispatchGroup()
  let signals = handledSignals.map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
    cancelled.enter()
    source.setCancelHandler { cancelled.leave() }
    source.setEventHandler { received.withLock { $0 = $0 ?? number } }
    source.resume()
    return source
  }
  defer {
    for source in signals { source.cancel() }
    cancelled.wait()
    for (number, handler) in zip(handledSignals, priorHandlers) {
      Darwin.signal(number, handler)
    }
    if reraise, let number = received.withLock({ $0 }) {
      Darwin.signal(number, SIG_DFL)
      // raise is thread-directed: a worker can have this signal blocked even though
      // the process-directed original reached DispatchSource. Unblock this thread
      // before re-raising so returning cannot swallow the termination request.
      var unblocked: sigset_t = 0
      sigemptyset(&unblocked)
      sigaddset(&unblocked, number)
      pthread_sigmask(SIG_UNBLOCK, &unblocked, nil)
      Darwin.raise(number)
    }
  }
  return try body { received.withLock { $0 } }
}
