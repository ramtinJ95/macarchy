import Dispatch

/// Runs jobs on a concurrent utility queue so synchronous process and framework calls do not block
/// Swift's cooperative thread pool.
final class BlockingTaskExecutor: TaskExecutor {
  private let queue: DispatchQueue

  init(label: String) {
    queue = DispatchQueue(
      label: label,
      qos: .utility,
      attributes: .concurrent
    )
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    queue.async {
      job.runSynchronously(on: executor)
    }
  }
}
