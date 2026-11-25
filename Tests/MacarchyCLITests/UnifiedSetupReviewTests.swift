import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Pure report fixtures: no live planners, activation locks or external processes.
struct UnifiedSetupReviewTests {
  @Test func summaryOmitsInventoryAndBytesButKeepsEveryConsentAndBlocker() throws {
    var plan = report()
    let proposal = SetupNativeReplacement.Proposal(
      id: "replace-zsh", provider: .zsh, destination: "/home/.zshrc",
      backup: "/home/.zshrc.backup", staging: "/home/.zshrc.stage",
      originalDigest: "old", linkTarget: "dotfiles/zshrc", enclosesKittyFile: false)
    plan.nativeStarters = [
      .init(
        provider: "zsh", destination: "/home/.zshrc",
        contents: String(repeating: "private-starter-line\n", count: 700),
        approval: "starter-approval", message: "seed", replacement: proposal)
    ]
    let before = try plan.render(json: true)
    let text = plan.renderReview()
    #expect(text.contains(proposal.summary))
    #expect(text.contains("target untouched"))
    #expect(!text.contains("private-starter-line"))
    #expect(!text.contains("inventory-99"))
    #expect(text.contains("adopt-existing"))
    #expect(text.contains("permission-required"))
    #expect(text.contains("permission-message"))
    #expect(text.contains("external-prerequisite-message"))
    #expect(text.contains("fatal-recovery-message"))
    #expect(text.contains("Skipped components (disabled by profile): editor"))
    #expect(text.contains("Full inventory: macarchy setup guided --resume --full"))
    #expect(!text.contains("setup plan --full"))
    #expect(text.split(separator: "\n").count < 25)
    #expect(try plan.render(json: true) == before)
    #expect(try plan.renderText().contains("private-starter-line"))
    #expect(try plan.renderText().contains("inventory-99"))
  }

  @Test func diagnosticsAndPermissionsAreNeverTruncatedToFitAScreen() {
    let text = report(boundaries: 60).renderReview()
    for index in 0..<60 { #expect(text.contains("required-boundary-\(index) [external]:")) }
    #expect(text.contains("fatal-recovery-message"))
  }

  @Test func fullReviewIsExplicitAndJSONRemainsComplete() throws {
    #expect(try Macarchy.Setup.Plan.parse([]).full == false)
    #expect(try Macarchy.Setup.Plan.parse(["--full"]).full)
    #expect(try Macarchy.Setup.Plan.parse(["--json", "--full"]).json)
    #expect(try Macarchy.Setup.Guided.parse(["--resume", "--full"]).full)
    #expect(try Macarchy.Setup.Guided.parse([]).full == false)
  }

  @Test func guidedPreflightReferencesTheReviewedPlanWithoutRepeatingInventory() throws {
    let transcript = Mutex("")
    let runner = UnifiedSetupApplyCommandRunner.guided(
      io: .init(read: { nil }, write: { output in transcript.withLock { $0 += output } }))
    try runner.writePreMutationPlan("full-inventory-not-to-repeat")
    let text = transcript.withLock { $0 }
    #expect(text.contains("applying the setup reviewed above"))
    #expect(!text.contains("full-inventory-not-to-repeat"))
  }

  @Test func completeApprovalDetectsByteChangesHiddenByTheSummary() throws {
    var plan = report()
    func starter(_ bytes: String) -> EnvironmentNativeSeed.Plan {
      .init(
        provider: "zsh", destination: "/home/.zshrc", contents: bytes,
        approval: "digest", message: "seed")
    }
    plan.nativeStarters = [starter("first reviewed bytes")]
    let summary = plan.renderReview()
    let approved = try plan.approvalText()
    plan.nativeStarters = [starter("changed hidden bytes")]
    #expect(plan.renderReview() == summary)
    #expect(try plan.approvalText() != approved)
  }

  private func report(boundaries: Int = 1) -> UnifiedSetupPlanReport {
    .init(
      outcome: "blocked", layers: [], fieldOrigins: ["origin": "inventory-origin"],
      providers: ["shell": "zsh", "editor": "disabled"], theme: nil, capabilities: [],
      packages: .init(),
      files: (0..<100).map {
        .init(
          id: "inventory-\($0)", path: "/file/\($0)", status: "install_required",
          ownership: "absent")
      },
      services: [],
      permissions: [
        .init(id: "permission-required", status: "manual", message: "permission-message")
      ],
      adoption: [.init(id: "adopt-existing", digest: "approval")],
      manualBoundaries: (0..<boundaries).map {
        .init(
          id: "required-boundary-\($0)", kind: "external",
          instruction: "external-prerequisite-message")
      },
      actions: [], components: nil,
      diagnostics: [.init(code: "fatal", source: "setup", message: "fatal-recovery-message")])
  }
}
