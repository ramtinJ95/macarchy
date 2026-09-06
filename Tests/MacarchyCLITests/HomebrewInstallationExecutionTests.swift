import Darwin
import Foundation
import Synchronization
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct HomebrewInstallationExecutionTests {
  @Test
  func processCannotRunBeforeIdentityPublicationAndFailedPublicationKillsIt() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let output = fixture.root.appending(path: "started")
    let script = fixture.root.appending(path: "command.sh")
    try fixture.write("#!/bin/sh\nprintf started > \"$1\"\nexit 7\n", at: script)
    let request = ProcessRequest(
      executableURL: URL(filePath: "/bin/sh"), arguments: [script.path, output.path], timeout: 2)
    let group = Mutex<Int32?>(nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewFormulaInstallProcess.run(request) { pid in
        group.withLock { $0 = pid }
        #expect(try HomebrewFormulaInstallProcess.groupExists(pid))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        throw SetupPackageAdoptionError("publication failed")
      }
    }
    #expect(try !HomebrewFormulaInstallProcess.groupExists(#require(group.withLock { $0 })))
    #expect(!FileManager.default.fileExists(atPath: output.path))
    let status = try HomebrewFormulaInstallProcess.run(request) { pid in
      #expect(!FileManager.default.fileExists(atPath: output.path))
      group.withLock { $0 = pid }
    }
    #expect(status == 7)
    #expect(try String(contentsOf: output, encoding: .utf8) == "started")
    #expect(try !HomebrewFormulaInstallProcess.groupExists(#require(group.withLock { $0 })))
  }

  @Test
  func timeoutTerminatesTheNativeProcessGroup() throws {
    let group = Mutex<Int32?>(nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try HomebrewFormulaInstallProcess.run(
        .init(
          executableURL: URL(filePath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
      ) { pid in group.withLock { $0 = pid } }
    }
    #expect(try !HomebrewFormulaInstallProcess.groupExists(#require(group.withLock { $0 })))
  }

  @Test
  func installationCommandUsesReviewedAllowlistAndMandatoryGuardsWithoutInvokingHomebrew() throws {
    let fixture = try InventoryFixture()
    defer { fixture.cleanup() }
    let scratch = URL(filePath: try HomebrewPackageImpactReader.sandboxPath(fixture.root))
    let session = HomebrewPackageImpactReader.Session(reader: .init(), scratch: scratch)
    let effects = effect()
    let result = try session.install(
      ["new-formula"], effects: effects, recordProcess: { _ in },
      run: {
        request, _ in
        #expect(request.executableURL.path == "/bin/sh")
        #expect(request.arguments.contains("HOMEBREW_NO_AUTOREMOVE=1"))
        #expect(request.arguments.contains("HOMEBREW_NO_INSTALL_CLEANUP=1"))
        #expect(request.arguments.contains("HOMEBREW_NO_INSTALL_UPGRADE=1"))
        #expect(
          !request.arguments.contains {
            $0.contains("NO_INSTALLED_DEPENDENTS_CHECK") || $0 == "--skip-post-install"
          })
        #expect(
          request.arguments.suffix(5) == [
            "install", "--formula", "--no-ask", "--force-bottle", "homebrew/core/new-formula",
          ])
        let sandbox = scratch.appending(path: "install.sb")
        let policy = try String(contentsOf: sandbox, encoding: .utf8)
        #expect(policy.contains("(deny network*)"))
        #expect(policy.contains("(subpath \"/opt/homebrew/Cellar/new-formula\")"))
        #expect(!policy.contains("(subpath \"/opt/homebrew\")"))
        #expect(!policy.contains("(subpath \"/opt/homebrew/opt\")"))
        func sandboxed(_ path: URL) throws -> ProcessResult {
          try ProcessRunner.live.run(
            .init(
              executableURL: URL(filePath: "/usr/bin/sandbox-exec"),
              arguments: ["-f", sandbox.path, "/usr/bin/touch", path.path], timeout: 3))
        }
        #expect(try sandboxed(scratch.appending(path: "allowed")).terminationStatus == 0)
        // A denied write is tested only against a disposable sibling, never a
        // real Homebrew path. The actual native installer remains uninvoked.
        let sibling = scratch.deletingLastPathComponent().appending(
          path: "macarchy-denied-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sibling) }
        #expect(try sandboxed(sibling).terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: sibling.path))
        try "bounded diagnostic".write(
          to: scratch.appending(path: "install.log"), atomically: true, encoding: .utf8)
        return 9
      })
    #expect(result.status == 9 && result.diagnostic == "bounded diagnostic")
  }

  @Test
  func malformedEffectsCannotBecomeWriteAuthority() throws {
    let valid = effect()
    try valid.validate(roots: ["new-formula"])
    #expect(throws: SetupPackageAdoptionError.self) { try valid.validate(roots: []) }
    #expect(throws: SetupPackageAdoptionError.self) { try valid.validate(roots: ["other"]) }
    for link in [
      HomebrewFormulaInstallEffects.Link(path: "/tmp/escape", target: valid.links[0].target),
      .init(path: valid.links[0].path, target: "/opt/homebrew/Cellar/old/1"),
      .init(path: "/opt/homebrew/opt/../escape", target: valid.links[0].target),
    ] {
      let invalid = HomebrewFormulaInstallEffects(
        components: valid.components, links: [link],
        directories: [],
        footprint: [.init(path: link.path, device: nil, inode: nil, mode: nil)],
        dependentIssue: nil)
      #expect(throws: SetupPackageAdoptionError.self) {
        try invalid.validate(roots: ["new-formula"])
      }
    }
    let occupied = HomebrewFormulaInstallEffects(
      components: valid.components, links: valid.links,
      directories: [],
      footprint: [.init(path: valid.links[0].path, device: 1, inode: 2, mode: 0o40755)],
      dependentIssue: nil)
    #expect(throws: SetupPackageAdoptionError.self) {
      try occupied.validate(roots: ["new-formula"])
    }
  }

  private func effect() -> HomebrewFormulaInstallEffects {
    .init(
      components: [
        .init(
          name: "new-formula", version: "1", sha256: String(repeating: "a", count: 64),
          dependencies: [])
      ],
      links: [
        .init(path: "/opt/homebrew/opt/new-formula", target: "/opt/homebrew/Cellar/new-formula/1")
      ],
      directories: [],
      footprint: [.init(path: "/opt/homebrew/opt/new-formula", device: nil, inode: nil, mode: nil)],
      dependentIssue: nil)
  }
}
