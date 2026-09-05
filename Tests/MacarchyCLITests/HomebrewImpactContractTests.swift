import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// Opt-in provider qualification, not a Homebrew SDK simulation. Requires the
/// pinned development checkout and this Mac's jq/tmux installation evidence.
struct HomebrewImpactContractTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_HOMEBREW_IMPACT"] == "1"))
  func realResolverRejectsMissingAndStaleManifestsThenReportsPendingDependencies() throws {
    let reader = HomebrewPackageImpactReader(
      processRunner: ProcessRunner { request in
        if request.arguments.contains("resolve") {
          let script = try #require(request.arguments.first { $0.hasSuffix("/resolver.rb") })
          let scratch = URL(filePath: script).deletingLastPathComponent()
          let metadata = try JSONDecoder().decode(
            [SetupPackageImpact.FormulaEvidence].self,
            from: Data(contentsOf: scratch.appending(path: "metadata-output.json")))
          let manifests = try metadata.map { entry -> (URL, Data) in
            let url = URL(filePath: try #require(entry.path))
            return (url, try Data(contentsOf: url))
          }
          for (url, _) in manifests { try FileManager.default.removeItem(at: url) }
          let missing = try ProcessRunner.live.run(request)
          #expect(missing.terminationStatus == 0)
          let output = scratch.appending(path: "resolve-output.json")
          let absent = try JSONDecoder().decode(
            [SetupPackageImpact.FormulaEvidence].self, from: Data(contentsOf: output))
          #expect(absent.allSatisfy { $0.status == "incomplete" && $0.dependencies == nil })
          for (url, data) in manifests {
            var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var entries = try #require(envelope["manifests"] as? [[String: Any]])
            for index in entries.indices {
              if var annotations = entries[index]["annotations"] as? [String: Any] {
                annotations["org.opencontainers.image.ref.name"] = "nonmatching-rebuild"
                entries[index]["annotations"] = annotations
              }
            }
            envelope["manifests"] = entries
            try JSONSerialization.data(withJSONObject: envelope).write(to: url)
          }
          let stale = try ProcessRunner.live.run(request)
          #expect(stale.terminationStatus == 0)
          let mismatched = try JSONDecoder().decode(
            [SetupPackageImpact.FormulaEvidence].self, from: Data(contentsOf: output))
          #expect(
            mismatched.allSatisfy {
              $0.status == "incomplete" && $0.issue?.contains("matching bottle checksum") == true
            }, "\(mismatched.compactMap(\.issue))")
          for (url, data) in manifests { try data.write(to: url) }
        }
        return try ProcessRunner.live.run(request)
      })
    let report = reader.read([
      .init(kind: .formula, name: "jq"), .init(kind: .formula, name: "tmux"),
    ])
    #expect(report.issue == nil)
    #expect(report.packages.allSatisfy { $0.status == "resolved_dependencies" })
    #expect(report.packages[0].evidence?.dependencies.isEmpty == true)
    #expect(
      report.packages[1].evidence?.dependencies.contains {
        $0.name == "jemalloc" && !$0.installed
      } == true)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACARCHY_TEST_HOMEBREW_IMPACT"] == "1"))
  func actualBrewRubyStartupDoesNotPersistDeveloperModeWithEmptyGitConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "macarchy-brew-startup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["bin", ".git", "cache", "tmp", "logs"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: directory), withIntermediateDirectories: true)
    }
    // Use the real entry point and libraries; only repository-local config is
    // empty. No live Git configuration, Cellar or trust store is changed.
    try FileManager.default.copyItem(
      at: URL(filePath: "/opt/homebrew/bin/brew"), to: root.appending(path: "bin/brew"))
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "Library"),
      withDestinationURL: URL(filePath: "/opt/homebrew/Library"))
    let config = root.appending(path: ".git/config")
    try Data().write(to: config)
    let probe = root.appending(path: "startup.rb")
    try
      #"raise 'Wrong transient state' unless ENV['HOMEBREW_DEV_CMD_RUN'] == '1'; puts 'startup-ok'"#
      .write(to: probe, atomically: true, encoding: .utf8)
    let profile = root.appending(path: "resolver.sb")
    try HomebrewFormulaResolver.sandbox.write(to: profile, atomically: true, encoding: .utf8)
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/env"),
        arguments: [
          "-i", "HOME=\(root.path)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C",
          "HOMEBREW_CACHE=\(root.appending(path: "cache").path)",
          "HOMEBREW_TEMP=\(root.appending(path: "tmp").path)",
          "HOMEBREW_LOGS=\(root.appending(path: "logs").path)",
          "TMPDIR=\(root.appending(path: "tmp").path)",
          "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1",
          "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1", "HOMEBREW_DEV_CMD_RUN=1",
          "/usr/bin/sandbox-exec", "-D",
          "SCRATCH=\(try HomebrewPackageImpactReader.sandboxPath(root))",
          "-f", profile.path, root.appending(path: "bin/brew").path, "ruby", probe.path,
        ], timeout: 30))
    #expect(result.terminationStatus == 0, "\(result.output)")
    #expect(result.output.contains("startup-ok"))
    #expect(try Data(contentsOf: config).isEmpty)
  }
}
