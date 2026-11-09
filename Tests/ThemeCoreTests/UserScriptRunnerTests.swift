import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ThemeCore

@Suite(.serialized)
struct UserScriptRunnerTests {
  @Test func theEnvironmentCarriesThePaletteAFixedPathAndOnlyBasicVariables() throws {
    let theme = try normalizedTheme()
    let environment = UserScriptRunner.environment(
      event: .teardown, theme: theme, themeFile: URL(filePath: "/state/current/theme.json"),
      inherited: ["HOME": "/Users/me", "TMPDIR": "/tmp/me/", "PATH": "/opt/evil", "SECRET": "x"])

    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["HOME"] == "/Users/me")
    #expect(environment["TMPDIR"] == "/tmp/me/")
    #expect(environment["SECRET"] == nil)
    #expect(environment["MACARCHY_EVENT"] == "teardown")
    #expect(environment["MACARCHY_THEME_ID"] == theme.themeID)
    #expect(environment["MACARCHY_APPEARANCE"] == theme.appearance.rawValue)
    #expect(environment["MACARCHY_THEME_FILE"] == "/state/current/theme.json")
    #expect(environment["MACARCHY_BACKGROUND"] == theme.semantic.background.rawValue)
    #expect(environment["MACARCHY_MUTED_TEXT"] == theme.semantic.mutedText.rawValue)
    #expect(environment["MACARCHY_ERROR"] == theme.semantic.error.rawValue)
    #expect(environment["MACARCHY_ANSI_0"] == theme.terminal.ansi[0].rawValue)
    #expect(environment["MACARCHY_ANSI_15"] == theme.terminal.ansi[15].rawValue)
    #expect(environment.keys.filter { $0.hasPrefix("MACARCHY_") }.count == 4 + 12 + 16)
    #expect(environment.count == 3 + 4 + 12 + 16)
  }

  @Test func aScriptRunsWithoutAShellAndReceivesExactlyTheGivenEnvironment() throws {
    try withScriptDirectory { directory in
      let script = try makeScript(
        "#!/bin/sh\n/usr/bin/env | /usr/bin/sort > \"$(dirname \"$0\")/received\"\n",
        in: directory)

      let outcome = UserScriptRunner().run(
        script, environment: ["PATH": UserScriptRunner.path, "MACARCHY_EVENT": "apply"])

      #expect(outcome == .succeeded)
      let received = try String(
        contentsOf: directory.appending(path: "received"), encoding: .utf8)
      #expect(received.contains("MACARCHY_EVENT=apply\n"))
      #expect(received.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"))
      #expect(!received.contains("HOME="))
    }
  }

  @Test func aScriptWithoutAnInterpreterLineIsNotHandedToAShell() throws {
    try withScriptDirectory { directory in
      let script = try makeScript("touch \"$(dirname \"$0\")/ran\"\n", in: directory)

      let outcome = UserScriptRunner().run(script, environment: [:])

      #expect(outcome == .failed("could not start: Exec format error"))
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "ran").path))
    }
  }

  @Test func aFailingScriptReportsItsStatusAndTheStartOfItsStandardError() throws {
    try withScriptDirectory { directory in
      let long = String(repeating: "x", count: 300)
      let failing = try makeScript(
        "#!/bin/sh\necho 'cannot\n  reach   the bar' >&2\nexit 3\n", named: "failing",
        in: directory)
      let verbose = try makeScript(
        "#!/bin/sh\necho \(long) >&2\nexit 1\n", named: "verbose", in: directory)
      let quiet = try makeScript("#!/bin/sh\nexit 4\n", named: "quiet", in: directory)

      #expect(
        UserScriptRunner().run(failing, environment: [:])
          == .failed("exited with status 3: cannot reach the bar"))
      #expect(
        UserScriptRunner().run(verbose, environment: [:])
          == .failed("exited with status 1: \(String(repeating: "x", count: 200))…"))
      #expect(UserScriptRunner().run(quiet, environment: [:]) == .failed("exited with status 4"))
    }
  }

  @Test func aScriptPastItsLimitIsStoppedWithItsWholeProcessGroup() throws {
    try withScriptDirectory { directory in
      let script = try makeScript(
        "#!/bin/sh\n/bin/sleep 30 &\necho $! > \"$(dirname \"$0\")/child\"\n/bin/sleep 30\n",
        in: directory)
      let started = ContinuousClock.now

      let outcome = UserScriptRunner(executionLimit: 1).run(script, environment: [:])

      #expect(outcome == .failed("did not finish within 1 seconds and was stopped"))
      #expect(ContinuousClock.now - started < .seconds(5))
      try expectStopped(childRecordedIn: directory)
    }
  }

  @Test func aBackgroundChildIsStoppedWhenTheScriptExits() throws {
    try withScriptDirectory { directory in
      let script = try makeScript(
        "#!/bin/sh\n/bin/sleep 30 &\necho $! > \"$(dirname \"$0\")/child\"\nexit 0\n",
        in: directory)

      #expect(UserScriptRunner().run(script, environment: [:]) == .succeeded)
      try expectStopped(childRecordedIn: directory)
    }
  }

  @Test func writeGrantingACLsAreRefusedButDenyEntriesRemainRunnable() throws {
    try withScriptDirectory { directory in
      let script = try makeScript("#!/bin/sh\nexit 0\n", in: directory)
      try setACL("group:staff allow write", on: script)
      #expect(
        UserScriptRunner().run(script, environment: [:])
          == .refused("it has an access control list that lets others change it"))
      try setACL(nil, on: script)
      defer { try? setACL(nil, on: script) }
      try setACL("everyone deny delete", on: script)
      #expect(UserScriptRunner().run(script, environment: [:]) == .succeeded)
      try setACL("group:staff allow add_file", on: directory)
      let resolved = try #require(realpathString(directory.path))
      #expect(
        UserScriptRunner().run(script, environment: [:])
          == .refused(
            "its directory \(resolved) has an access control list that lets others change it"))
    }
  }

  @Test func writableGrandparentsAreRefusedEvenWithAPrivateParent() throws {
    try withScriptDirectory { grandparent in
      let parent = grandparent.appending(path: "private")
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let script = try makeScript("#!/bin/sh\nexit 0\n", in: parent)
      let runner = UserScriptRunner()
      // The ordinary path includes root-owned / and /Users, and the home deny-delete ACL.
      #expect(runner.run(script, environment: [:]) == .succeeded)
      chmod(grandparent.path, 0o777)
      let resolved = try #require(realpathString(grandparent.path))
      #expect(
        runner.run(script, environment: [:])
          == .refused("its directory \(resolved) is writable by its group or by others"))
      chmod(grandparent.path, 0o700)
      try setACL("group:staff allow add_subdirectory", on: grandparent)
      #expect(
        runner.run(script, environment: [:])
          == .refused(
            "its directory \(resolved) has an access control list that lets others change it"))
    }
  }

  @Test func untrustedScriptsAreRefusedBeforeTheyRun() throws {
    try withScriptDirectory { directory in
      let groupWritable = try makeScript("#!/bin/sh\nexit 0\n", named: "group", in: directory)
      chmod(groupWritable.path, 0o775)
      let notExecutable = try makeScript("#!/bin/sh\nexit 0\n", named: "plain", in: directory)
      chmod(notExecutable.path, 0o644)
      let shared = directory.appending(path: "shared", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
      chmod(shared.path, 0o777)
      let inShared = try makeScript("#!/bin/sh\nexit 0\n", named: "inner", in: shared)
      let mine = try makeScript("#!/bin/sh\nexit 0\n", named: "mine", in: directory)
      let link = directory.appending(path: "link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inShared)

      let runner = UserScriptRunner()
      #expect(
        runner.run(groupWritable, environment: [:])
          == .refused("it is writable by its group or by others"))
      #expect(
        runner.run(notExecutable, environment: [:])
          == .refused("it is not executable by its owner"))
      let resolvedShared = try #require(realpathString(shared.path))
      #expect(
        runner.run(link, environment: [:])
          == .refused("its directory \(resolvedShared) is writable by its group or by others"))
      #expect(
        runner.run(directory.appending(path: "missing"), environment: [:])
          == .refused("it cannot be found (No such file or directory)"))
      #expect(
        UserScriptRunner(userID: getuid() + 1).run(mine, environment: [:])
          == .refused("it belongs to another user"))
      #expect(runner.run(mine, environment: [:]) == .succeeded)
    }
  }
}

extension AdapterContractTests {
  @Test
  func userScriptsRunAfterEveryOtherAdapterWithTheActiveTheme() async throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryRoot(root) }
    let manifest = try testActivator(root: root).activate(package: catppuccinPackage())
    let scripts = try makeTrustedScriptDirectory()
    defer { removeTemporaryRoot(scripts) }
    let script = try makeScript(
      "#!/bin/sh\nprintf '%s %s %s' \"$MACARCHY_EVENT\" \"$MACARCHY_THEME_ID\" "
        + "\"$MACARCHY_ANSI_15\" > \"$(dirname \"$0\")/received\"\n",
      in: scripts)
    let refused = try makeScript("#!/bin/sh\nexit 0\n", named: "refused", in: scripts)
    chmod(refused.path, 0o777)
    let otherFinished = Mutex(false)
    let other = AdapterReconciliation(id: "aaa-slow", requirement: .required) {
      try await Task.sleep(for: .milliseconds(200))
      otherFinished.withLock { $0 = true }
      return AdapterOutcome(status: .applied)
    }
    let adapter = UserScriptsAdapter(root: root, mode: UserScriptsMode(scripts: [script]))
    let userScripts = adapter.reconciliation()
    let observed = AdapterReconciliation(
      id: userScripts.id, requirement: userScripts.requirement, runsAfterOthers: true
    ) {
      #expect(otherFinished.withLock { $0 })
      return try await userScripts.run()
    }

    let record = try await ThemeReconciler(statusStore: ReconciliationStatusStore(root: root))
      .reconcile(manifest: manifest, adapters: [observed, other])

    let result = try #require(record.results.first { $0.adapterID == UserScriptsAdapter.id })
    #expect(userScripts.runsAfterOthers)
    #expect(result.status == .applied)
    #expect(result.requirement == .optional)
    #expect(result.message == "Ran 1 script: \(script.path) succeeded")
    let package = try catppuccinPackage()
    #expect(
      try String(contentsOf: scripts.appending(path: "received"), encoding: .utf8)
        == "apply \(package.id) \(package.terminal.ansi[15].rawValue)")

    let failing = UserScriptsAdapter(root: root, mode: UserScriptsMode(scripts: [script, refused]))
    let outcome = try await failing.reconciliation().run()
    #expect(outcome.status == .failed)
    #expect(
      outcome.message
        == "Ran 2 scripts: \(script.path) succeeded; \(refused.path) refused, it is writable "
        + "by its group or by others")
    #expect(failing.inspection().status == .failed)
    #expect(adapter.inspection().status == .ready)
    #expect(
      UserScriptsAdapter(root: root, mode: nil).inspection().message
        == "no applied user scripts; review the setup plan and apply the profile first")
  }
}

private func withScriptDirectory(_ body: (URL) throws -> Void) throws {
  let root = try makeTrustedScriptDirectory()
  defer { removeTemporaryRoot(root) }
  try body(root)
}

@discardableResult
private func makeScript(_ text: String, named name: String = "script", in directory: URL) throws
  -> URL
{
  let url = directory.appending(path: name)
  try text.write(to: url, atomically: false, encoding: .utf8)
  chmod(url.path, 0o700)
  return url
}

private func realpathString(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// The background child the script recorded no longer runs.
private func expectStopped(childRecordedIn directory: URL) throws {
  let recorded = try String(contentsOf: directory.appending(path: "child"), encoding: .utf8)
  let child = try #require(pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines)))
  let deadline = ContinuousClock.now + .seconds(2)
  while kill(child, 0) == 0, ContinuousClock.now < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
  #expect(kill(child, 0) == -1)
}

private func normalizedTheme() throws -> NormalizedTheme {
  try withTemporaryRootReturning { root in
    let manifest = try ThemeActivator(root: root, faultInjector: { _ in })
      .activate(package: BuiltInThemePackages.catppuccinMocha.get())
    return try manifest.normalizedTheme(root: root)
  }
}

private func withTemporaryRootReturning<T>(_ body: (URL) throws -> T) throws -> T {
  let root = try makeTemporaryDirectory(named: "macarchy-user-script-theme")
  defer { removeTemporaryRoot(root) }
  return try body(root)
}

private func setACL(_ entry: String?, on url: URL) throws {
  let process = Process()
  process.executableURL = URL(filePath: "/bin/chmod")
  process.arguments = entry.map { ["+a", $0, url.path] } ?? ["-N", url.path]
  try process.run()
  process.waitUntilExit()
  try #require(process.terminationStatus == 0)
}
