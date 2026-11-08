import Foundation
import TestSupport

@testable import MacarchyCLI
@testable import ThemeCore

func coreTestRequirements(_ answers: GuidedSetupAnswers) throws -> Set<HomebrewPackageIdentity> {
  let profile = try PortableProfileLoader().decode(
    answers.profileTOML, source: URL(filePath: "/tmp/guided-test.toml"))
  return Set(
    try DependencyProfile.personal(homeDirectory: URL(filePath: "/tmp")).selectedForSetup(
      profile, defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml")
    ).compactMap { $0.remediation.homebrewPackage })
}
