import Foundation

/// Durable work an interrupted setup command left behind. Each caller names exactly the work that
/// must be absent before it proceeds, in the order it checks it, and the refusal it reports for a
/// pending unified transaction. Unreadable state fails with the owning store's error.
enum SetupPendingWork {
  /// An interrupted `setup install-packages` attempt.
  case packageAttempt
  /// An interrupted `setup add-packages` input publication.
  case inputPublication
  /// An interrupted unified apply or teardown.
  case unifiedTransaction(refusal: any Error)

  static func requireNone(_ work: SetupPendingWork..., context: UnifiedSetupPlanContext) throws {
    for item in work {
      switch item {
      case .packageAttempt:
        try SetupPackageInstallationStore(context: context).requireResolved()
      case .inputPublication:
        try SetupPackageInputPublicationStore(context: context).requireResolved()
      case .unifiedTransaction(let refusal):
        guard try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil else {
          throw refusal
        }
      }
    }
  }
}
