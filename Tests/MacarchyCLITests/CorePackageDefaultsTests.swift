import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct CorePackageDefaultsTests {
  @Test(arguments: ["schema_version = 1\n", "schema_version = 1\n[packages]\n"])
  func omittedBaselineSelectsOnlyComponentRequirements(source: String) throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    try source.write(to: fixture.context.profileURL, atomically: true, encoding: .utf8)
    var planner = fixture.planner()
    planner.standardBrewfile = { _ in
      Issue.record("Core defaults must not read the optional catalog")
      throw SetupPackageAdoptionError("catalog unavailable")
    }
    let inventory = try planner.packageInventory(
      context: fixture.context, adoptionState: .available(nil))
    #expect(inventory.baseline == .core)
    #expect(!inventory.proposed.isEmpty)
    #expect(inventory.proposed.allSatisfy { !$0.requirements.isEmpty })
    #expect(
      !inventory.proposed.contains {
        ["zoom", "docker-desktop", "tailscale-app", "azure-cli", "hashicorp/tap/terraform"]
          .contains($0.identity.name)
      })
    #expect(PackageProfile.defaults.baseline == .core)
  }

  @Test
  func catalogContainsNoZoomButPersonalDeclarationsRemainAllowed() throws {
    let catalog = try SetupBrewfile.read(at: repositoryRoot.appending(path: "Environment/Brewfile"))
    #expect(!catalog.packages.contains { $0.name == "zoom" })
    #expect(try SetupBrewfile.parse("cask 'zoom'").packages.count == 1)
  }

  @Test(arguments: [false, true])
  func menuDefaultsOffAndProtectsActualSelectedRequirements(disableShell: Bool) throws {
    let fzf = HomebrewPackageIdentity(kind: .formula, name: "fzf")
    let keys =
      (disableShell ? Array(repeating: "down", count: 4) + [" "] : [])
      + ["up", "enter"]
    let responses = Mutex(keys)
    let answers = try GuidedSetupSelectionMenu(
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { _ in }),
      packages: [fzf, .init(kind: .cask, name: "docker-desktop")],
      requirements: coreTestRequirements
    ).collect()
    #expect(answers.packageAdditions.isEmpty)
    #expect(answers.packageExclusions.contains(fzf) == disableShell)
    #expect(answers.packageExclusions.contains(.init(kind: .cask, name: "docker-desktop")))
  }

  @Test
  func requiredRowCannotBeUnchecked() throws {
    let responses = Mutex(["up", " ", "enter"])
    let transcript = Mutex("")
    let fzf = HomebrewPackageIdentity(kind: .formula, name: "fzf")
    let answers = try GuidedSetupSelectionMenu(
      io: .init(
        read: { responses.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
        write: { output in transcript.withLock { $0 += output } }),
      packages: [fzf], requirements: coreTestRequirements
    ).collect()
    #expect(answers.packageAdditions.isEmpty && answers.packageExclusions.isEmpty)
    #expect(transcript.withLock { $0.contains("[required]") })
    #expect(transcript.withLock { $0.contains("disable that component first") })
  }

  @Test
  func optInPersistsThroughOrdinaryPlanningAndReapply() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    var answers = GuidedSetupAnswers()
    answers.packageAdditions = [.init(kind: .formula, name: "hashicorp/tap/terraform")]
    answers.packageExclusions = [.init(kind: .cask, name: "docker-desktop")]
    let fragment = try #require(
      try GuidedSetupProfileWriter.write(
        answers: answers, nativeSources: "", to: fixture.context.profileURL))
    let original = try Data(contentsOf: fragment)
    #expect(try SetupBrewfile.read(at: fragment) == .installing(answers.packageAdditions))
    for _ in 0..<2 {
      let inventory = try fixture.planner().packageInventory(
        context: fixture.context, adoptionState: .available(nil))
      let selected = try #require(
        inventory.proposed.first {
          $0.identity.key == "formula:hashicorp/tap/terraform"
        })
      #expect(selected.personalDeclarations.first?.sourcePath == fragment.path)
      #expect(selected.standardDeclaration == nil)
      #expect(!inventory.proposed.contains { $0.identity.name == "docker-desktop" })
    }
    #expect(try Data(contentsOf: fragment) == original)
    let attributes = try FileManager.default.attributesOfItem(atPath: fragment.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func failedProfilePublicationReportsRetainedFragmentWithoutOverwriting() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let target = fixture.context.profileURL
    try "incumbent".write(to: target, atomically: true, encoding: .utf8)
    var answers = GuidedSetupAnswers()
    answers.packageAdditions = [.init(kind: .formula, name: "jq")]
    do {
      _ = try GuidedSetupProfileWriter.write(answers: answers, nativeSources: "", to: target)
      Issue.record("Existing profile must block")
    } catch {
      #expect(String(describing: error).contains("Unreferenced package fragment retained"))
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "incumbent")
  }
}

func coreTestRequirements(_ answers: GuidedSetupAnswers) throws -> Set<HomebrewPackageIdentity> {
  let profile = try PortableProfileLoader().decode(
    answers.profileTOML, source: URL(filePath: "/tmp/guided-test.toml"))
  return Set(
    try DependencyProfile.personal(homeDirectory: URL(filePath: "/tmp")).selectedForSetup(
      profile, defaultsURL: repositoryRoot.appending(path: "Desktop/sketchybar/defaults.toml")
    ).compactMap { $0.remediation.homebrewPackage })
}
