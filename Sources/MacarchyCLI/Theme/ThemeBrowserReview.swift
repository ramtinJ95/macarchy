import ThemeCore

/// What the theme browser's Review sheet shows for a planned selection, and whether that plan
/// can still be applied when Apply Reviewed is chosen.
struct ThemeBrowserReview: Sendable {
  enum Choice: Equatable, Sendable {
    case apply
    case editProfile
    case cancel

    var title: String {
      switch self {
      case .apply: "Apply Reviewed"
      case .editProfile: "Edit Profile…"
      case .cancel: "Cancel"
      }
    }
  }

  let review: ThemeActivationReview
  let displayName: String

  var title: String {
    "Review \(displayName)" + (review.backgroundID.map { " with background \($0)" } ?? "")
  }

  /// The sheet's buttons in order; a plan with a failed preflight cannot be applied.
  var choices: [Choice] {
    (review.canApply ? [.apply] : []) + [.editProfile, .cancel]
  }

  /// One line per enabled consumer, then the consumers disabled in the profile.
  var planText: String {
    (reviewConsumerLines(review) + [reviewDisabledLine(review)].compactMap { $0 })
      .joined(separator: "\n")
  }

  var summary: String {
    let profile =
      "The profile turns consumers on or off; Edit Profile opens it, and setup applies it."
    guard review.canApply else {
      return ThemeActivationReviewError.blocked(review.failedConsumerIDs).description + ". "
        + profile
    }
    return "Apply Reviewed applies exactly this plan. It is refused if the theme, its "
      + "background, the enabled consumers or the active theme change first. " + profile
  }

  /// Why `current`, planned again just before applying, can no longer be applied as reviewed;
  /// nil while it still can. The apply process checks the digest once more under the lock.
  func refusal(current: ThemeActivationReview) -> String? {
    guard current.digest == review.digest else {
      let change =
        current.activeGenerationID != review.activeGenerationID
        ? "The active theme changed" : "The theme or its enabled consumers changed"
      return "\(change) since this review, so nothing was applied. Review it again."
    }
    guard current.canApply else {
      return ThemeActivationReviewError.blocked(current.failedConsumerIDs).description
        + ". Nothing was applied."
    }
    return nil
  }
}
