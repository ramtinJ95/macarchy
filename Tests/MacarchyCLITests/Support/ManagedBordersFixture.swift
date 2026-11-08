import Foundation
import Synchronization
import TestSupport
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ManagedBordersFixture {
  struct State {
    var running: Bool
    var pid: Int32 = 100
    var actions: [String] = []
    var failRequest = false
    var failStop = false
    var interruptedRegistration = false
    var incompatible = false
  }
  final class StateBox: Sendable {
    private let value: Mutex<State>
    init(_ value: State) { self.value = Mutex(value) }
    func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
      try value.withLock { try body(&$0) }
    }
  }
  let directory: URL
  let home: URL
  let root: URL
  let profile: URL
  let kind: String
  let state: StateBox
  var runtime: EnvironmentBordersRuntime
  let original = Data(
    "#!/bin/sh\n# arbitrary native options, never parsed or rewritten\nborders width=11.0 style=square\n"
      .utf8)

  init(kind: String, running: Bool) throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-managed-borders-\(UUID())")
    home = directory.appending(path: "home")
    root = home.appending(path: ".config/macarchy")
    profile = directory.appending(path: "profile.toml")
    self.kind = kind
    let state = StateBox(State(running: running))
    self.state = state
    let recovery: @Sendable (URL) throws -> BordersServiceInspection = { _ in
      state.withLock { value in
        value.running || value.interruptedRegistration
          ? BordersServiceInspection(
            processID: value.running ? value.pid : nil,
            executablePath: "/opt/homebrew/Cellar/borders/1.9.0/bin/borders",
            propertyListDigest: sha256Digest(Data("native plist".utf8))) : .stopped
      }
    }
    let inspect: @Sendable (URL) throws -> BordersServiceInspection = { home in
      try state.withLock { value in
        if value.incompatible {
          throw BordersServiceError.blocked("unsupported provider compatibility")
        }
        if value.interruptedRegistration {
          throw BordersServiceError.blocked("dormant registration")
        }
      }
      return try recovery(home)
    }
    runtime = EnvironmentBordersRuntime(
      inspect: inspect, preflight: inspect, recoveryPreflight: recovery,
      start: { _ in
        state.withLock {
          $0.running = true
          $0.interruptedRegistration = false
          $0.pid += 1
          $0.actions.append("start")
        }
      },
      restart: { _ in
        state.withLock {
          $0.running = true
          $0.interruptedRegistration = false
          $0.pid += 1
          $0.actions.append("restart")
        }
      },
      stop: { _ in
        try state.withLock {
          if $0.failStop { throw BordersServiceError.blocked("injected stop failure") }
          $0.running = false
          $0.interruptedRegistration = false
          $0.actions.append("stop")
        }
      },
      request: { root, _ in
        let palette = try BordersPalette.read(root: root)
        try state.withLock {
          $0.actions.append(palette.accent)
          if $0.failRequest { throw BordersServiceError.blocked("injected request failure") }
        }
        return "Accepted canonical palette request; no native settings readback."
      },
      lean: .unexpectedInTest, inspectIncumbent: recovery)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".config"), withIntermediateDirectories: true)
    if kind == "file" {
      try FileManager.default.createDirectory(
        at: home.appending(path: ".config/borders"), withIntermediateDirectories: false)
      try original.write(to: home.appending(path: ".config/borders/bordersrc"))
      try Data("unrelated".utf8).write(to: home.appending(path: ".config/borders/personal.txt"))
    } else if kind == "directory-link" {
      let target = directory.appending(path: "dotfiles/borders")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try original.write(to: target.appending(path: "bordersrc"))
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: ".config/borders"), withDestinationURL: target)
    } else if kind == "fallback" {
      try original.write(to: home.appending(path: ".bordersrc"))
    }
    if running, kind != "absent" {
      let originalPath = kind == "fallback" ? ".bordersrc" : ".config/borders/bordersrc"
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: home.appending(path: originalPath).path)
    }
    try writeProfile(enabled: true)
    try activate("catppuccin-mocha")
  }

  func writeProfile(enabled: Bool) throws {
    try writeProfile(provider: enabled ? .borders : .disabled)
  }

  func writeProfile(provider: FocusRingProviderSelection) throws {
    let contents = """
      schema_version = 1
      [focus_ring]
      provider = "\(provider.rawValue)"
      [terminal]
      provider = "disabled"
      [shell]
      provider = "disabled"
      [editor]
      provider = "disabled"
      [tools]
      bat = false
      eza = false
      btop = false
      yazi = false
      """
    try Data(contents.utf8).write(to: profile)
  }

  func activate(_ theme: String) throws {
    let package = try ThemePackageLoader().load(
      packageURL: repositoryRoot.appending(path: "Themes/\(theme)"))
    _ = try ThemeActivator(
      root: root, faultInjector: { _ in }, onThemeChanged: { _ in },
      postDarwinNotification: { _ in }
    ).activate(package: package)
  }

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: .assumed, bordersRuntime: runtime).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: profile,
      profileRequired: true, stateRoot: root, homeDirectory: home, json: true)
  }

  func stageUnverifiedApply() throws {
    let composition = try EnvironmentConfigurationComposer().compose(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profile: PortableProfileLoader().load(at: profile, required: true), stateRoot: root)
    let inspection = EnvironmentProviderInspector().inspectIncludingBordersRuntime(
      composition: composition, homeDirectory: home, stateRoot: root, runtime: runtime)
    _ = try EnvironmentLifecycleLock(stateRoot: root).withActivationLock {
      try EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: root).applyLocked(
        composition: composition, inspection: inspection,
        adoptionDigest: inspection.adoptionEvidenceDigest, themeBridges: .init(entries: []))
    }
  }

  func apply(adopt: String? = nil) async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentApplyCommandRunner(
      prerequisites: .assumed, theme: nil, verifier: .assumed, bordersRuntime: runtime
    ).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"), profileURL: profile,
      profileRequired: true, stateRoot: root, homeDirectory: home,
      consumerPaths: testConsumerPaths(), adopt: adopt, json: true)
  }

  func teardown() async throws -> (output: String, succeeded: Bool) {
    try await EnvironmentTeardownCommandRunner(bordersRuntime: runtime).execute(
      stateRoot: root, homeDirectory: home, consumerPaths: testConsumerPaths(), dryRun: false,
      json: true)
  }

  func digest(_ output: String) throws -> String? {
    (try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?[
      "adoption_evidence_digest"] as? String
  }

  func verifyOriginal() throws {
    switch kind {
    case "file", "directory-link":
      #expect(try Data(contentsOf: home.appending(path: ".config/borders/bordersrc")) == original)
      if kind == "file" {
        #expect(
          try Data(contentsOf: home.appending(path: ".config/borders/personal.txt"))
            == Data("unrelated".utf8))
      } else {
        #expect(
          try FileManager.default.destinationOfSymbolicLink(
            atPath: home.appending(path: ".config/borders").path)
            == directory.appending(path: "dotfiles/borders").path)
      }
    case "fallback": #expect(try Data(contentsOf: home.appending(path: ".bordersrc")) == original)
    default:
      #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config/borders").path))
    }
  }

  func remove() {
    removeTemporaryRoot(directory)
  }
}
