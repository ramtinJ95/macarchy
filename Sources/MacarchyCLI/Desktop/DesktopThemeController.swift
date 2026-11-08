import Foundation
import ThemeCore

struct DesktopThemeAdapterStatus: Encodable, Equatable, Sendable {
  let adapterID: String
  let requirement: String
  let status: String
  let message: String?
}

struct DesktopThemeReconciliation: Encodable, Equatable, Sendable {
  let generationID: String
  let results: [DesktopThemeAdapterStatus]
  let succeeded: Bool
}

struct DesktopThemeController: Sendable {
  let reconcile:
    @Sendable (_ adapterIDs: [String], _ stateRoot: URL, _ consumerPaths: ThemeConsumerPaths)
      async throws -> DesktopThemeReconciliation
  let inspect:
    @Sendable (_ adapterIDs: [String], _ stateRoot: URL, _ consumerPaths: ThemeConsumerPaths)
      throws -> [DesktopThemeAdapterStatus]

  static let live = makeLive(enabledAdapterIDs: nil)

  static func live(enabling enabledAdapterIDs: Set<String>) -> Self {
    makeLive(enabledAdapterIDs: enabledAdapterIDs)
  }

  private static func makeLive(enabledAdapterIDs: Set<String>?) -> Self {
    Self(
      reconcile: { adapterIDs, stateRoot, consumerPaths in
        let result = try await ThemeRuntimeSelection.activationCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          enabledAdapterIDs: enabledAdapterIDs
        ).reconcile(
          adapterIDs: adapterIDs,
          excludingAdapterIDs: Set([HerdrAdapter.id, BordersAdapter.id, BordersAdapter.leanID])
            .subtracting(adapterIDs)
        )
        let selected = Set(adapterIDs)
        let results = result.record.results.filter { selected.contains($0.adapterID) }
        return DesktopThemeReconciliation(
          generationID: result.manifest.generationID,
          results: results.map {
            DesktopThemeAdapterStatus(
              adapterID: $0.adapterID,
              requirement: $0.requirement.rawValue,
              status: $0.status.rawValue,
              message: $0.message
            )
          },
          succeeded: !hasRequiredReconciliationFailure(results)
        )
      },
      inspect: { adapterIDs, stateRoot, consumerPaths in
        return try ThemeRuntimeSelection.activationCoordinator(
          stateRoot: stateRoot,
          consumerPaths: consumerPaths,
          enabledAdapterIDs: enabledAdapterIDs
        ).inspectAdapters(adapterIDs, includeRuntimeChecks: true).map {
          DesktopThemeAdapterStatus(
            adapterID: $0.adapterID,
            requirement: $0.requirement.rawValue,
            status: $0.status.rawValue,
            message: $0.message
          )
        }
      }
    )
  }
}
