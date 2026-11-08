import Foundation
import ThemeCore

func renderAdapterResult(_ result: AdapterResult) -> String {
  let message = result.message.map { ": \($0)" } ?? ""
  let carried = result.carriedForwardFromGenerationID.map { " (carried from \($0))" } ?? ""
  return
    "- \(result.adapterID) [\(result.requirement.rawValue)]: "
    + "\(result.status.rawValue)\(carried)\(message)"
}

func hasRequiredReconciliationFailure(_ results: [AdapterResult]) -> Bool {
  results.contains { result in
    result.requirement == .required && !isAcceptedReconciliationResult(result)
  }
}

func hasRequiredInspectionFailure(_ inspections: [AdapterInspection]) -> Bool {
  inspections.contains { inspection in
    inspection.requirement == .required && !isAcceptedInspection(inspection)
  }
}

func inspectionFindingStatus(_ inspection: AdapterInspection) -> DoctorFinding.Status {
  if inspection.status == .ready { return .ok }
  if isAcceptedInspection(inspection) { return .warning }
  return inspection.requirement == .required ? .failure : .warning
}

private func isAcceptedInspection(_ inspection: AdapterInspection) -> Bool {
  inspection.status == .ready
    || (inspection.status == .unsupported && isNamedThemeOnlyAdapter(inspection.adapterID))
}

/// Named-theme-only consumers (herdr, neovim) report `unsupported` for a theme without a named
/// mapping; reconcile, doctor and environment status all accept that outcome.
private func isNamedThemeOnlyAdapter(_ adapterID: String) -> Bool {
  GeneratedThemeCapabilities.namedThemeAdapterIDs.contains(adapterID)
}

func isAcceptedReconciliationResult(_ result: AdapterResult) -> Bool {
  result.status == .applied
    || result.status == .restartRequired
    || (result.adapterID == "wallpaper" && result.status == .disabled)
    || (result.status == .unsupported && isNamedThemeOnlyAdapter(result.adapterID))
}

/// `environment status` carries inspection and reconciliation outcomes as raw strings. It accepts
/// what reconcile and doctor accept, except a disabled wallpaper, which it never selects.
func isAcceptedEnvironmentThemeStatus(_ adapter: DesktopThemeAdapterStatus) -> Bool {
  switch adapter.status {
  case AdapterInspectionStatus.ready.rawValue, AdapterStatus.applied.rawValue,
    AdapterStatus.restartRequired.rawValue:
    return true
  case AdapterStatus.unsupported.rawValue:
    return isNamedThemeOnlyAdapter(adapter.adapterID)
  default:
    return false
  }
}
