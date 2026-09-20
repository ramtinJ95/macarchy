import Foundation
import ThemeCore

/// Existing-profile review, not guided onboarding or recovery authorization.
struct MenuSetupReview: Sendable {
  let runner: UnifiedSetupApplyCommandRunner
  let io: GuidedSetupIO

  func execute(context: UnifiedSetupPlanContext, consumerPaths: ThemeConsumerPaths) async throws
    -> (output: String, succeeded: Bool)
  {
    guard FileManager.default.fileExists(atPath: context.profileURL.path) else {
      return (
        "Review & apply requires an existing portable profile; use setup guided for onboarding.",
        false
      )
    }
    try SetupPackageInstallationStore(context: context).requireResolved()
    guard try UnifiedSetupTransactionStore(stateRoot: context.stateRoot).read() == nil else {
      return ("Interrupted setup requires explicit setup recover before menu apply.", false)
    }
    let preparation = try runner.planner.prepare(context: context)
    let plan = preparation.report
    io.write(try runner.planner.inspectedReport(plan, context: context).render(json: false) + "\n")
    guard case .ready(let model, _) = preparation, model.packages.external.isEmpty else {
      return ("The setup plan is blocked; resolve its prerequisites before applying.", false)
    }
    let reviewedPlan = try plan.approvalText()
    let approvals = Dictionary(uniqueKeysWithValues: plan.adoption.map { ($0.id, $0.digest) })
    io.write(
      "Confirmation authorizes only this plan's missing packages, configuration adoptions, "
        + "native preferences and provider/service changes (including selected keybindings).\n"
        + "Homebrew effects are not rolled back. Permissions are never granted automatically. "
        + "This does not create a profile, seed missing native sources or recover interrupted setup.\n"
    )
    guard try io.confirm("Apply the reviewed configuration now?") else {
      return ("Cancelled; no configuration or packages changed.", true)
    }
    return try await runner.execute(
      context: context, consumerPaths: consumerPaths,
      packageApproval: plan.packageInstallation?.approvalDigest,
      preferencesApproval: plan.preferencesApprovalDigest,
      adoptions: UnifiedSetupAdoptionApprovals(
        yabai: approvals["yabai"], keybindings: approvals["keybindings"],
        sketchybar: approvals["sketchybar"], environment: approvals["environment"]),
      reviewedPlan: reviewedPlan, json: false)
  }
}
