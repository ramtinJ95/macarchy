import Foundation
import ThemeCore

typealias UnifiedSetupThemeInspection =
  @Sendable (UnifiedSetupDesiredModel, SetupCoreOwnership?, URL)
  -> UnifiedSetupThemeLifecycleStatus

struct UnifiedSetupThemeLifecycleStatus: Encodable, Sendable {
  let succeeded: Bool
  let status: String
  let generationID: String?
  let message: String

  static func inspect(
    model: UnifiedSetupDesiredModel,
    ownership: SetupCoreOwnership?,
    stateRoot: URL
  ) -> Self {
    guard let active = model.theme.currentGenerationID else {
      guard ownership == nil else {
        return Self(
          succeeded: false,
          status: "missing",
          generationID: nil,
          message: "Setup theme ownership exists without an active canonical generation."
        )
      }
      return Self(
        succeeded: true,
        status: "absent",
        generationID: nil,
        message: "No setup-owned canonical theme exists."
      )
    }
    guard let ownership else {
      return Self(
        succeeded: true,
        status: "external",
        generationID: active,
        message: "The active canonical theme predates unified setup and is not setup-owned."
      )
    }
    guard ownership.themeGenerationID == active else {
      return Self(
        succeeded: false,
        status: "drifted",
        generationID: active,
        message:
          "Setup owns theme generation '\(ownership.themeGenerationID)', but '\(active)' is active."
      )
    }

    do {
      guard case .current(let record) = try ReconciliationStatusStore(root: stateRoot).read()
      else {
        return drifted(active, "Theme reconciliation does not describe the active generation.")
      }
      guard
        let recorded = record.results.first(where: {
          $0.adapterID == MacOSAppearanceAdapter.id
        }),
        recorded.requirement == .required,
        recorded.status == .applied
      else {
        return drifted(active, "macOS appearance reconciliation is incomplete.")
      }
      let appearance = MacOSAppearanceAdapter.live(root: stateRoot).inspection(
        desiredAppearance: model.themePackage.appearance
      )
      guard appearance.status == .ready else {
        return drifted(
          active,
          appearance.message ?? "macOS appearance differs from the active theme."
        )
      }
      return Self(
        succeeded: true,
        status: "managed",
        generationID: active,
        message: "The setup-owned canonical theme and macOS appearance are current."
      )
    } catch {
      return Self(
        succeeded: false,
        status: "invalid",
        generationID: active,
        message: "Cannot inspect setup-owned theme reconciliation: \(error)"
      )
    }
  }

  private static func drifted(_ generationID: String, _ message: String) -> Self {
    Self(
      succeeded: false,
      status: "drifted",
      generationID: generationID,
      message: message
    )
  }

  enum CodingKeys: String, CodingKey {
    case succeeded, status, message
    case generationID = "generation_id"
  }
}
