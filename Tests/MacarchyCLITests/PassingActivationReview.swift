import Foundation

@testable import ThemeCore

/// A review in which nothing is enabled, for activation fakes whose dry runs only need to pass.
func passingReview(_ package: ThemePackage) throws -> ThemeActivationReview {
  try ThemeActivationReview(
    themeID: package.id, backgroundID: nil, activeGenerationID: nil, inputDigest: "test",
    enabledAdapterIDs: [], consumers: [], disabledConsumerIDs: [])
}
