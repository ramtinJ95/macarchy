import ArgumentParser
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct PackageImpactTests {
  @Test
  func onlyExplicitPlanRequestsImpactAndFailuresKeepTheInventory() throws {
    let options = try Macarchy.Setup.Plan.parse(["--package-impact", "--json"])
    #expect(options.packageImpact)
    #expect(try !Macarchy.Setup.Plan.parse([]).packageImpact)
    #expect(throws: (any Error).self) { try Macarchy.Setup.Apply.parse(["--package-impact"]) }
    #expect(throws: (any Error).self) { try Macarchy.Setup.Status.parse(["--package-impact"]) }
    let fixture = try ApplyFixture()
    defer { fixture.cleanup() }
    let calls = Mutex(0)
    var planner = fixture.planner()
    planner.packageImpactReader = { identities in
      calls.withLock { $0 += 1 }
      return SetupPackageImpact(identities: identities, issue: "Unsupported Homebrew revision")
    }
    #expect(try planner.prepare(context: fixture.context).report.packageImpact == nil)
    let ordinary = try planner.execute(context: fixture.context, json: true)
    #expect(ordinary.succeeded)
    #expect(!ordinary.output.contains("package_impact"))
    #expect(calls.withLock { $0 } == 0)
    let explicit = try planner.execute(
      context: fixture.context, json: options.json, packageImpact: options.packageImpact
    )
    #expect(!explicit.succeeded)
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(explicit.output.utf8)) as? [String: Any])
    #expect(json["mutated"] as? Bool == false)
    #expect(json["package_inventory"] != nil)
    let impact = try #require(json["package_impact"] as? [String: Any])
    #expect((impact["packages"] as? [Any])?.count == 62)
    #expect(impact["status"] as? String == "unavailable")
    #expect(calls.withLock { $0 } == 1)
  }

  @Test
  func translatesNativePendingAndSatisfiedEvidenceWithoutClaimingCompleteEffects() throws {
    let response = #"""
      [
        {"name":"jq","status":"resolved_dependencies","version":"1.8.2","installed":true,
         "current":true,"linked":true,"dependencies":[]},
        {"name":"resvg","status":"resolved_dependencies","version":"0.47.0","installed":false,
         "current":false,"linked":false,"dependencies":[
           {"name":"libpng","version":"1.6.55","installed":true,"linked":true}]}
      ]
      """#
    let evidence = try JSONDecoder().decode(
      [SetupPackageImpact.FormulaEvidence].self, from: Data(response.utf8))
    let identities = [
      HomebrewPackageIdentity(kind: .formula, name: "jq"),
      HomebrewPackageIdentity(kind: .formula, name: "resvg"),
      HomebrewPackageIdentity(kind: .cask, name: "kitty"),
      HomebrewPackageIdentity(kind: .formula, name: "asmvik/formulae/yabai"),
    ]
    let report = SetupPackageImpact(identities: identities, evidence: evidence)
    #expect(report.status == "partial")
    #expect(report.packages.map(\.identity) == identities)
    #expect(
      report.packages.map(\.status) == [
        "resolved_dependencies", "resolved_dependencies", "unsupported", "unsupported",
      ])
    #expect(report.packages[1].evidence?.dependencies.first?.installed == true)
    #expect(report.humanOutput.contains("no installation/adoption authority"))
    #expect(report.humanOutput.contains("no pending dependencies"))
    #expect(report.humanOutput.contains("Pending libpng"))
  }

  @Test
  func missingStaleMalformedAndDuplicateEvidenceNeverBecomesResolved() {
    let identity = HomebrewPackageIdentity(kind: .formula, name: "jq")
    let incomplete = SetupPackageImpact.FormulaEvidence(
      name: "jq", status: "incomplete", issue: "Missing matching bottle dependency evidence")
    for evidence in [
      [], [incomplete], [incomplete, incomplete],
      [.init(name: "jq", status: "resolved_dependencies", version: "1")],
    ] {
      let report = SetupPackageImpact(identities: [identity], evidence: evidence)
      #expect(report.packages[0].status == "incomplete")
      #expect(report.packages[0].evidence == nil)
      #expect(report.packages[0].issue != nil)
    }
  }

  @Test
  func unsupportedRevisionStopsBeforeNetworkOrRuby() {
    let requests = Mutex([ProcessRequest]())
    let reader = HomebrewPackageImpactReader(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 0, output: "unqualified-revision")
      })
    let report = reader.read([.init(kind: .formula, name: "jq")])
    #expect(report.status == "unavailable")
    #expect(report.issue?.contains("Unsupported Homebrew revision") == true)
    let observed = requests.withLock { $0 }
    #expect(observed.count == 1)
    #expect(observed.first?.arguments.suffix(2) == ["rev-parse", "HEAD"])
  }

  @Test
  func configuredBrewEnvironmentStopsBeforeSubprocesses() throws {
    let home = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-impact-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: home.appending(path: ".homebrew"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("HOMEBREW_NO_INSTALL_FROM_API=1\n".utf8)
      .write(to: home.appending(path: ".homebrew/brew.env"))
    let reader = HomebrewPackageImpactReader(
      processRunner: ProcessRunner { _ in
        Issue.record("Configured brew.env must stop before subprocesses")
        return ProcessResult(terminationStatus: 1, output: "unexpected")
      }, homeDirectory: home)
    let report = reader.read([.init(kind: .formula, name: "jq")])
    #expect(report.status == "unavailable")
    #expect(report.issue?.contains("brew.env") == true)
  }

  @Test(arguments: ["modified_checkout", "metadata_failure", "sandbox_failure"])
  func failedPrerequisitesNeverFallBackToUnconfinedRuby(failure: String) throws {
    let requests = Mutex([ProcessRequest]())
    let scratch = Mutex<URL?>(nil)
    let reader = HomebrewPackageImpactReader(
      processRunner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.arguments.contains("rev-parse") {
          return ProcessResult(terminationStatus: 0, output: HomebrewFormulaResolver.revision)
        }
        if request.arguments.contains("status") {
          return ProcessResult(
            terminationStatus: 0, output: failure == "modified_checkout" ? " M brew.sh" : "")
        }
        if request.arguments.contains("/usr/bin/curl") {
          if failure == "metadata_failure" {
            return ProcessResult(terminationStatus: 22, output: "metadata unavailable")
          }
          let index = try #require(request.arguments.firstIndex(of: "--output"))
          let destination = URL(filePath: request.arguments[index + 1])
          scratch.withLock {
            $0 = destination.deletingLastPathComponent().deletingLastPathComponent()
              .deletingLastPathComponent().deletingLastPathComponent()
          }
          try Data("transport placeholder; no native resolver runs in this failure test".utf8)
            .write(to: destination)
          return ProcessResult(terminationStatus: 0, output: "")
        }
        #expect(request.arguments.contains("/usr/bin/sandbox-exec"))
        #expect(request.arguments.contains("HOMEBREW_DEV_CMD_RUN=1"))
        #expect(request.arguments.first == "-i")
        return ProcessResult(terminationStatus: 1, output: "sandbox denied")
      })
    let report = reader.read([.init(kind: .formula, name: "jq")])
    #expect(report.status == "unavailable")
    #expect(report.packages[0].status == "incomplete")
    let observed = requests.withLock { $0 }
    #expect(
      observed.count == (failure == "modified_checkout" ? 2 : failure == "metadata_failure" ? 3 : 4)
    )
    if let directory = scratch.withLock({ $0 }) {
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test
  func sandboxAllowsOnlyPhysicalScratchWrites() throws {
    let parent = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-impact-confinement-\(UUID().uuidString)")
    let scratch = parent.appending(path: "scratch")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let profile = scratch.appending(path: "resolver.sb")
    try HomebrewFormulaResolver.sandbox.write(to: profile, atomically: true, encoding: .utf8)
    for (destination, allowed) in [
      (scratch.appending(path: "inside"), true), (parent.appending(path: "outside"), false),
    ] {
      let result = try ProcessRunner.live.run(
        ProcessRequest(
          executableURL: URL(filePath: "/usr/bin/sandbox-exec"),
          arguments: [
            "-D", "SCRATCH=\(try HomebrewPackageImpactReader.sandboxPath(scratch))",
            "-f", profile.path, "/usr/bin/touch", destination.path,
          ], timeout: 5))
      #expect((result.terminationStatus == 0) == allowed)
      #expect(FileManager.default.fileExists(atPath: destination.path) == allowed)
    }
  }
}
