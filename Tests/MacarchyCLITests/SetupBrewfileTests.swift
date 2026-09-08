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
  func namedInstallationDerivesOnlyRequiredTapsOnceBeforePackages() throws {
    let declarations = try SetupBrewfile.parse(
      "tap 'unrelated/tap'\nbrew 'vendor/tools/jq'\ncask 'vendor/tools/slack'\nbrew 'homebrew/core/git'\n"
    )
    #expect(declarations.taps == ["unrelated/tap"])
    #expect(
      SetupBrewfile.installing(declarations.packages).text
        == "tap \"vendor/tools\"\ncask \"vendor/tools/slack\"\nbrew \"git\"\nbrew \"vendor/tools/jq\"\n"
    )
  }

  @Test
  func nativeRequestUsesOnlyTheGeneratedFileAndInstallOnlyControls() {
    let home = URL(filePath: "/tmp/personal home")
    let brewfile = URL(filePath: "/tmp/macarchy state/installation.Brewfile")
    let log = URL(filePath: "/tmp/macarchy state/homebrew-install.log")
    let request = HomebrewBundleInstaller.request(
      brewfile: brewfile, log: log, homeDirectory: home, inheritedEnvironment: [:])
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
  func configurationLocationIsSharedByApprovalAndSanitizedExecution() throws {
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let packages = [HomebrewPackageIdentity(kind: .formula, name: "resvg")]
    let file = HomebrewBundleInstaller.Preview.fileURL(context: fixture.context)
    let base = try HomebrewBundleInstaller.Preview(
      packages: packages, effectiveBrewfile: "brew \"resvg\"\n",
      context: fixture.context, inheritedEnvironment: [:])
    var approvals = Set([base.approvalDigest])
    for variable in ["XDG_CONFIG_HOME", "HOMEBREW_XDG_CONFIG_HOME"] {
      let location = fixture.root.appending(path: "custom config").path
      let inherited = [
        variable: location, "HOMEBREW_BUNDLE_FORCE": "1", "HOMEBREW_BUNDLE_SKIP": "resvg",
        "HOMEBREW_NO_INSTALL_CLEANUP": "0", "HOMEBREW_USER_CONFIG_HOME": "/ignored",
        "HOMEBREW_REQUIRE_TAP_TRUST": "0", "UNRELATED_SECRET": "not-forwarded",
      ]
      let preview = try HomebrewBundleInstaller.Preview(
        packages: packages, effectiveBrewfile: base.effectiveBrewfile,
        context: fixture.context, inheritedEnvironment: inherited)
      let request = HomebrewBundleInstaller.request(
        brewfile: file, log: file.appendingPathExtension("log"),
        homeDirectory: fixture.context.homeDirectory, inheritedEnvironment: inherited)
      #expect(preview.environment == base.environment + ["\(variable)=\(location)"])
      #expect(request.arguments.contains("\(variable)=\(location)"))
      #expect(
        !request.arguments.contains { $0.contains("not-forwarded") || $0.contains("/ignored") })
      #expect(!request.arguments.contains("HOMEBREW_REQUIRE_TAP_TRUST=0"))
      #expect(!request.arguments.contains("HOMEBREW_BUNDLE_FORCE=1"))
      #expect(!request.arguments.contains("HOMEBREW_BUNDLE_SKIP=resvg"))
      #expect(request.arguments.contains("HOMEBREW_NO_INSTALL_CLEANUP=1"))
      #expect(approvals.insert(preview.approvalDigest).inserted)
    }
  }

  @Test(arguments: ["default", "xdg", "homebrew", "empty-xdg"])
  func preflightRejectsOnlyTheSelectedUserBrewEnvironment(location: String) throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let home = fixture.root.appending(path: "home")
    let xdg = fixture.root.appending(path: "xdg")
    let brew = fixture.root.appending(path: "brew-config")
    let inherited: [String: String]
    let selected: URL
    switch location {
    case "xdg":
      inherited = ["XDG_CONFIG_HOME": xdg.path, "HOMEBREW_XDG_CONFIG_HOME": brew.path]
      selected = xdg.appending(path: "homebrew")
    case "homebrew":
      inherited = ["HOMEBREW_XDG_CONFIG_HOME": brew.path]
      selected = brew.appending(path: "homebrew")
    case "empty-xdg":
      inherited = ["HOMEBREW_XDG_CONFIG_HOME": brew.path, "XDG_CONFIG_HOME": ""]
      selected = brew.appending(path: "homebrew")
    default:
      inherited = ["XDG_CONFIG_HOME": "", "HOMEBREW_XDG_CONFIG_HOME": ""]
      selected = home.appending(path: ".homebrew")
    }
    if location != "default" {
      try fixture.write("HOMEBREW_BUNDLE_FORCE=1\n", at: home.appending(path: ".homebrew/brew.env"))
    }
    if location == "xdg" {
      try fixture.write("HOMEBREW_BUNDLE_FORCE=1\n", at: brew.appending(path: "homebrew/brew.env"))
      #expect(
        !HomebrewBundleInstaller.executionEnvironment(inheriting: inherited)
          .contains("HOMEBREW_XDG_CONFIG_HOME=\(brew.path)"))
    }
    try HomebrewBundleInstaller.validateConfiguration(
      homeDirectory: home, inheritedEnvironment: inherited)
    let configuration = selected.appending(path: "brew.env")
    try fixture.write("HOMEBREW_BUNDLE_FORCE=1\n", at: configuration)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewBundleInstaller.validateConfiguration(
        homeDirectory: home, inheritedEnvironment: inherited)
    }
    #expect(try String(contentsOf: configuration, encoding: .utf8) == "HOMEBREW_BUNDLE_FORCE=1\n")
  }

  @Test
  func declarationLimitIsEnforcedAtThePublicInputBoundary() throws {
    let names = (0..<1024).map { HomebrewPackageIdentity(kind: .formula, name: "tool-\($0)") }
    let text = SetupBrewfile(packages: names).text
    #expect(try SetupBrewfile.parse(text).packages.count == 1024)
    #expect(throws: SetupPackageAdoptionError.self) {
      try SetupBrewfile.parse(text + "brew \"one-more\"\n")
    }
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
