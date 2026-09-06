import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct SetupBrewfileTests {
  @Test
  func literalDeclarationsNormalizeAndRenderDeterministically() throws {
    let file = try SetupBrewfile.parse(
      """
      # Only data, not executable Ruby
      cask 'slack'
      brew "homebrew/core/jq" # normalized
      tap "hashicorp/tap"
      brew "hashicorp/tap/terraform"
      """)
    #expect(
      file.packages.map(\.key) == [
        "cask:slack", "formula:hashicorp/tap/terraform", "formula:jq",
      ])
    #expect(try SetupBrewfile.parse(file.text) == file)
    #expect(SetupBrewfile(packages: file.packages.reversed(), taps: file.taps).text == file.text)
  }

  @Test(arguments: [
    "brew ENV.fetch('PACKAGE')", "brew \"jq\", restart_service: true", "system 'touch /tmp/no'",
    "brew \"jq\"; exit", "brew \"#{system('false')}\"", "mas \"App\", id: 1",
    "tap \"vendor/tap\", trusted: true", "brew \"../jq\"", "brew \"-jq\"",
    "brew \"jq\"\nbrew \"homebrew/core/jq\"", "tap \"vendor/tap\"\ntap \"vendor/tap\"",
  ])
  func executableAndUnsupportedSyntaxIsRejected(source: String) {
    #expect(throws: SetupPackageAdoptionError.self) { try SetupBrewfile.parse(source) }
  }

  @Test
  func nativeRequestUsesOnlyTheGeneratedFileAndInstallOnlyControls() {
    let home = URL(filePath: "/tmp/personal home")
    let brewfile = URL(filePath: "/tmp/macarchy state/installation.Brewfile")
    let log = URL(filePath: "/tmp/macarchy state/homebrew-install.log")
    let request = HomebrewBundleInstaller.request(brewfile: brewfile, log: log, homeDirectory: home)
    #expect(request.executableURL.path == "/bin/sh")
    #expect(
      request.arguments.suffix(6) == [
        "/opt/homebrew/bin/brew", "bundle", "install", "--no-upgrade", "--file", brewfile.path,
      ])
    #expect(request.arguments.contains("/usr/bin/env") && request.arguments.contains("-i"))
    #expect(request.arguments.contains("HOME=\(home.path)"))
    for guardValue in [
      "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_AUTOREMOVE=1",
      "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_INSTALL_UPGRADE=1",
    ] { #expect(request.arguments.contains(guardValue)) }
    for prohibited in [
      "upgrade", "cleanup", "autoremove", "trust", "--force", "--overwrite",
      "--ignore-dependencies", "--force-bottle", "/usr/bin/sandbox-exec",
    ] { #expect(!request.arguments.contains(prohibited)) }
    #expect(request.environmentOverrides.isEmpty && request.environmentRemovals.isEmpty)
    #expect(request.timeout == 1800)
  }

  @Test
  func retiredImpactOptionIsAnExplicitCLIError() {
    #expect(throws: (any Error).self) { try Macarchy.Setup.Plan.parse(["--package-impact"]) }
  }

  @Test
  func unavailableDefaultsDoNotSilentlyBecomeAnEmptyBaseline() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    var planner = fixture.planner()
    planner.standardBrewfile = { _ in throw SetupPackageAdoptionError("Missing packaged Brewfile") }
    #expect(throws: SetupPackageAdoptionError.self) {
      try planner.packageInventory(context: fixture.context, adoptionState: .available(nil))
    }
    let plan = try planner.execute(context: fixture.context, json: true)
    #expect(!plan.succeeded && plan.output.contains("Missing packaged Brewfile"))
  }
}
