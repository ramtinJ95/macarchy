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

  static func preflightApply(
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
    let bootstrapActive = ownership.themeGenerationID == active
    return Self(
      succeeded: true,
      status: bootstrapActive ? "managed" : "preserved",
      generationID: active,
      message: bootstrapActive
        ? "The setup bootstrap is active; apply will reconcile its consumers."
        : "Preserving the user-selected canonical theme; bootstrap ownership is unchanged."
    )
  }

  static func inspect(
    model: UnifiedSetupDesiredModel,
    ownership: SetupCoreOwnership?,
    stateRoot: URL
  ) -> Self {
    let preflight = preflightApply(model: model, ownership: ownership, stateRoot: stateRoot)
    guard preflight.succeeded, ownership != nil,
      let active = model.theme.currentGenerationID
    else { return preflight }

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
        status: preflight.status,
        generationID: active,
        message:
          "The active canonical theme and macOS appearance are current; bootstrap ownership is unchanged."
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
