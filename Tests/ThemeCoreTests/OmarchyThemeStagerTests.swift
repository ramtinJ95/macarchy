import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct OmarchyThemeStagerTests {
  @Test
  func githubURLsDeriveCanonicalOmarchyThemeIDs() throws {
    let ordinary = try OmarchyGitHubThemeSource(
      "https://github.com/ramtinJ95/purple-dream")
    #expect(ordinary.repositoryURL.absoluteString == "https://github.com/ramtinJ95/purple-dream")
    #expect(ordinary.themeID == "purple-dream")

    let decorated = try OmarchyGitHubThemeSource(
      "https://github.com/Example/omarchy-Purple-Dream-theme.git/")
    #expect(
      decorated.repositoryURL.absoluteString
        == "https://github.com/Example/omarchy-Purple-Dream-theme")
    #expect(decorated.themeID == "purple-dream")
  }

  @Test(
    arguments: [
      "http://github.com/example/theme",
      "git@github.com:example/theme.git",
      "https://gitlab.com/example/theme",
      "https://github.com/example/theme/tree/main",
      "https://github.com/example/theme?ref=main",
      "https://user@github.com/example/theme",
      "https://github.com:443/example/theme",
      "https://github.com/example/theme%2Fother",
      "https://github.com/example/invalid_theme",
      "https://github.com/example/omarchy--theme",
    ]
  )
  func rejectsNonPublicOrAmbiguousGitHubRepositoryURLs(_ source: String) {
    #expect(throws: OmarchyThemeStagingError.self) {
      _ = try OmarchyGitHubThemeSource(source)
    }
  }

  @Test
  func stagesTheDefaultBranchWithoutInitializingSubmodulesAndCleansUp() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let recorder = RequestRecorder()
    let stager = OmarchyThemeStager(
      temporaryRoot: fixture.stagingRoot,
      processRunner: localRepositoryRunner(
        source: fixture.repository,
        recorder: recorder
      )
    )

    let evidence = try stager.withStagedCheckout(
      from: "https://github.com/example/omarchy-fixture-theme.git"
    ) { staged in
      #expect(staged.themeID == "fixture")
      #expect(staged.sourceURL.absoluteString == "https://github.com/example/omarchy-fixture-theme")
      #expect(staged.resolvedCommit == fixture.defaultBranchCommit)
      #expect(
        try gitOutput([
          "-C", staged.checkoutURL.path, "rev-list", "--count", "HEAD",
        ]) == "1")
      let branch = try String(
        contentsOf: staged.checkoutURL.appending(path: "branch.txt"),
        encoding: .utf8
      )
      let submoduleContents = try FileManager.default.contentsOfDirectory(
        at: staged.checkoutURL.appending(path: "vendor/submodule"),
        includingPropertiesForKeys: nil
      )
      #expect(branch == "default\n")
      #expect(submoduleContents.isEmpty)
      return (staged.themeID, staged.resolvedCommit)
    }

    #expect(evidence.0 == "fixture")
    #expect(evidence.1 == fixture.defaultBranchCommit)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: fixture.stagingRoot,
        includingPropertiesForKeys: nil
      ).isEmpty)

    let recorded = recorder.requests.withLock { $0 }
    let clone = try #require(recorded.first)
    #expect(clone.arguments.contains("--depth=1"))
    #expect(clone.arguments.contains("--single-branch"))
    #expect(clone.arguments.contains("--no-tags"))
    #expect(clone.arguments.contains("--no-recurse-submodules"))
    #expect(!clone.arguments.contains("--recurse-submodules"))
    #expect(clone.arguments.contains("https://github.com/example/omarchy-fixture-theme"))
    #expect(clone.environmentOverrides["GIT_TERMINAL_PROMPT"] == "0")
    #expect(clone.environmentOverrides["GIT_CONFIG_NOSYSTEM"] == "1")
    #expect(clone.environmentRemovals.contains("GIT_CONFIG_PARAMETERS"))
    #expect(clone.environmentRemovals.contains("GIT_ALLOW_PROTOCOL"))
    #expect(clone.environmentRemovals.contains("GIT_SSL_NO_VERIFY"))
  }

  @Test
  func fetchFailureIsBoundedAndRemovesPartialCheckout() throws {
    let root = try temporaryDirectory(named: "failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ProcessRunner { request in
      let destination = URL(
        filePath: request.arguments.last!,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true
      )
      return ProcessResult(
        terminationStatus: 128,
        output: String(repeating: "remote failure ", count: 1_000)
      )
    }
    let stager = OmarchyThemeStager(temporaryRoot: root, processRunner: runner)

    do {
      try stager.withStagedCheckout(from: "https://github.com/example/theme") { _ in }
      Issue.record("Expected staging to fail")
    } catch let error as OmarchyThemeStagingError {
      guard case .fetchFailed(let detail) = error else {
        Issue.record("Expected a fetch failure, got \(error)")
        return
      }
      #expect(detail.utf8.count <= 4_096)
      #expect(detail.hasSuffix("..."))
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  func callbackFailurePreservesTheErrorAndCleansUp() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let stager = OmarchyThemeStager(
      temporaryRoot: fixture.stagingRoot,
      processRunner: localRepositoryRunner(
        source: fixture.repository,
        recorder: RequestRecorder()
      )
    )

    #expect(throws: CallbackError.expected) {
      try stager.withStagedCheckout(from: "https://github.com/example/theme") { _ in
        throw CallbackError.expected
      }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: fixture.stagingRoot,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  func invalidResolvedCommitIsTypedAndCleansUp() throws {
    let root = try temporaryDirectory(named: "commit")
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Mutex(0)
    let runner = ProcessRunner { request in
      calls.withLock { $0 += 1 }
      if request.arguments.contains("clone") {
        try FileManager.default.createDirectory(
          at: URL(filePath: request.arguments.last!, directoryHint: .isDirectory),
          withIntermediateDirectories: true
        )
        return ProcessResult(terminationStatus: 0, output: "")
      }
      return ProcessResult(terminationStatus: 0, output: "not-a-commit")
    }
    let stager = OmarchyThemeStager(temporaryRoot: root, processRunner: runner)

    #expect(throws: OmarchyThemeStagingError.commitResolutionFailed("not-a-commit")) {
      try stager.withStagedCheckout(from: "https://github.com/example/theme") { _ in }
    }
    #expect(calls.withLock { $0 } == 2)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  func processRunnerCanRemoveInheritedEnvironmentValues() throws {
    let result = try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: URL(filePath: "/usr/bin/env"),
        arguments: [],
        timeout: 10,
        environmentOverrides: ["MACARCHY_ENVIRONMENT_TEST": "present"],
        environmentRemovals: ["HOME"]
      )
    )

    #expect(result.terminationStatus == 0)
    #expect(result.output.contains("MACARCHY_ENVIRONMENT_TEST=present"))
    #expect(!result.output.split(separator: "\n").contains { $0.hasPrefix("HOME=") })
  }

  @Test
  func oversizedCheckoutFailsBeforeCommitResolutionAndCleansUp() throws {
    let root = try temporaryDirectory(named: "size-limit")
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Mutex(0)
    let runner = ProcessRunner { request in
      calls.withLock { $0 += 1 }
      let checkout = URL(filePath: request.arguments.last!, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
      let oversized = checkout.appending(path: "oversized")
      _ = FileManager.default.createFile(atPath: oversized.path, contents: nil)
      let handle = try FileHandle(forWritingTo: oversized)
      try handle.truncate(atOffset: UInt64(256 * 1_048_576 + 1))
      try handle.close()
      return ProcessResult(terminationStatus: 0, output: "")
    }
    let stager = OmarchyThemeStager(temporaryRoot: root, processRunner: runner)

    #expect(
      throws: OmarchyThemeStagingError.stagingLimitExceeded("more than 256 MiB of files")
    ) {
      try stager.withStagedCheckout(from: "https://github.com/example/theme") { _ in }
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test
  func cancellationIsNotMappedToAStagingFailure() throws {
    let root = try temporaryDirectory(named: "cancellation")
    defer { try? FileManager.default.removeItem(at: root) }
    let stager = OmarchyThemeStager(
      temporaryRoot: root,
      processRunner: ProcessRunner { _ in throw CancellationError() }
    )

    #expect(throws: CancellationError.self) {
      try stager.withStagedCheckout(from: "https://github.com/example/theme") { _ in }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  private enum CallbackError: Error {
    case expected
  }
}

private final class GitFixture {
  let root: URL
  let repository: URL
  let stagingRoot: URL
  let defaultBranchCommit: String

  init() throws {
    root = try temporaryDirectory(named: "git")
    repository = root.appending(path: "repository", directoryHint: .isDirectory)
    stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
    let submodule = root.appending(path: "submodule", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)

    try runGit(["init", "--initial-branch=main", submodule.path])
    try configureGitRepository(submodule)
    try "submodule\n".write(
      to: submodule.appending(path: "contents.txt"),
      atomically: true,
      encoding: .utf8
    )
    try runGit(["-C", submodule.path, "add", "contents.txt"])
    try runGit(["-C", submodule.path, "commit", "-m", "submodule"])

    try runGit(["init", "--initial-branch=trunk", repository.path])
    try configureGitRepository(repository)
    try "default\n".write(
      to: repository.appending(path: "branch.txt"),
      atomically: true,
      encoding: .utf8
    )
    try runGit(["-C", repository.path, "add", "branch.txt"])
    try runGit(["-C", repository.path, "commit", "-m", "default branch"])
    try runGit([
      "-c", "protocol.file.allow=always",
      "-C", repository.path,
      "submodule", "add", submodule.path, "vendor/submodule",
    ])
    try runGit(["-C", repository.path, "commit", "-am", "add submodule"])
    defaultBranchCommit = try gitOutput([
      "-C", repository.path, "rev-parse", "HEAD",
    ])

    try runGit(["-C", repository.path, "switch", "-c", "other"])
    try "other\n".write(
      to: repository.appending(path: "branch.txt"),
      atomically: true,
      encoding: .utf8
    )
    try runGit(["-C", repository.path, "commit", "-am", "other branch"])
    try runGit(["-C", repository.path, "switch", "trunk"])
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func localRepositoryRunner(
  source: URL,
  recorder: RequestRecorder
) -> ProcessRunner {
  ProcessRunner { request in
    recorder.requests.withLock { $0.append(request) }
    guard let cloneIndex = request.arguments.firstIndex(of: "clone") else {
      return try ProcessRunner.live.run(request)
    }

    var arguments = request.arguments
    arguments.insert(contentsOf: ["-c", "protocol.file.allow=always"], at: cloneIndex)
    let separator = try #require(arguments.firstIndex(of: "--"))
    arguments[separator + 1] = source.absoluteString
    return try ProcessRunner.live.run(
      ProcessRequest(
        executableURL: request.executableURL,
        arguments: arguments,
        timeout: request.timeout,
        environmentOverrides: request.environmentOverrides,
        environmentRemovals: request.environmentRemovals
      )
    )
  }
}

private final class RequestRecorder: Sendable {
  let requests = Mutex([ProcessRequest]())
}

private func configureGitRepository(_ repository: URL) throws {
  try runGit(["-C", repository.path, "config", "user.name", "Macarchy Tests"])
  try runGit(["-C", repository.path, "config", "user.email", "tests@example.invalid"])
}

private func runGit(_ arguments: [String]) throws {
  _ = try gitOutput(arguments)
}

private func gitOutput(_ arguments: [String]) throws -> String {
  let result = try ProcessRunner.live.run(
    ProcessRequest(
      executableURL: URL(filePath: "/usr/bin/git"),
      arguments: arguments,
      timeout: 10
    )
  )
  guard result.terminationStatus == 0 else {
    throw GitFixtureError.commandFailed(result.output)
  }
  return result.output
}

private func temporaryDirectory(named name: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "macarchy-omarchy-stager-\(name)-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private enum GitFixtureError: Error {
  case commandFailed(String)
}
