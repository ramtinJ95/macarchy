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
      reraiseDefaultStopSignal(number)
    }
  }
  return try body { received.withLock { $0 } }
}

/// Darwin's thread-directed raise can return successfully on a Swift worker without
/// terminating, even with SIG_DFL and an unblocked signal (guest regression evidence).
/// Re-send to the process and never return to application work after a stop request.
private func reraiseDefaultStopSignal(_ number: Int32) -> Never {
  var action = sigaction()
  action.__sigaction_u.__sa_handler = SIG_DFL
  sigemptyset(&action.sa_mask)
  guard sigaction(number, &action, nil) == 0 else {
    fatalError("Cannot restore stop signal \(number) (errno \(errno))")
  }
  var waitMask: sigset_t = 0
  let maskCode = pthread_sigmask(SIG_BLOCK, nil, &waitMask)
  guard maskCode == 0 else {
    fatalError("Cannot inspect stop signal mask (errno \(maskCode))")
  }
  sigdelset(&waitMask, number)
  guard kill(getpid(), number) == 0 else {
    fatalError("Cannot re-send stop signal \(number) (errno \(errno))")
  }
  // Delivery can select another thread or remain pending if all threads block it.
  // Atomically unblock this signal while waiting. Never turn interruption into a
  // normal return/exit, even if an unrelated handled signal wakes sigsuspend.
  while true { sigsuspend(&waitMask) }
}
