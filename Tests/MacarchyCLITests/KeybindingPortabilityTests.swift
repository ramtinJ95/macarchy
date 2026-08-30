import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct KeybindingPortabilityTests {
  @Test
  func cleanProfileInheritsEveryPackagedDefault() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let resources = try copyFixture(
      named: "package-v1",
      to: environment.root.appending(path: "inputs/package-v1", directoryHint: .isDirectory)
    )

    let execution = try plan(
      resources: resources,
      profile: environment.home.appending(path: ".config/macarchy/profile.toml"),
      profileRequired: false,
      environment: environment
    )
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let bindings = try #require(report["bindings"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(summary["effective"] as? Int == 3)
    #expect(summary["packaged_defaults"] as? Int == 3)
    #expect(summary["user_replacements"] as? Int == 0)
    #expect(summary["user_additions"] as? Int == 0)
    #expect(summary["disabled_defaults"] as? Int == 0)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "alt-k", "cmd-b"])
    #expect(bindings.allSatisfy { $0["command_source"] as? String == "packaged_default" })
    #expect(
      report["rendered_skhdrc"] as? String
        == """
        alt - j : package focus south v1
        alt - k : package focus north v1
        cmd - b : package open browser v1

        """
    )
  }

  @Test
  func sparseProfileReplacesDisablesAddsAndInheritsUntouchedDefaults() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let resources = try copyFixture(
      named: "package-v1",
      to: environment.root.appending(path: "inputs/package-v1", directoryHint: .isDirectory)
    )
    let portableInputs = try copyFixture(
      named: "portable",
      to: environment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    let profile = portableInputs.appending(path: "profile.toml")
    let before = try filesystemSnapshot(at: portableInputs)

    let execution = try plan(
      resources: resources,
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    let report = try jsonObject(execution.output)
    let summary = try #require(report["summary"] as? [String: Any])
    let bindings = try #require(report["bindings"] as? [[String: Any]])
    let disabled = try #require(report["disabled_defaults"] as? [[String: Any]])

    #expect(execution.succeeded)
    #expect(summary["effective"] as? Int == 3)
    #expect(summary["packaged_defaults"] as? Int == 3)
    #expect(summary["user_replacements"] as? Int == 1)
    #expect(summary["user_additions"] as? Int == 1)
    #expect(summary["disabled_defaults"] as? Int == 1)
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "cmd-b", "cmd-x"])
    #expect(try binding("alt-j", in: bindings)["command_source"] as? String == "user_replacement")
    #expect(try binding("alt-j", in: bindings)["metadata_source"] as? String == "user_overlay")
    #expect(try binding("cmd-b", in: bindings)["command_source"] as? String == "packaged_default")
    #expect(try binding("cmd-b", in: bindings)["metadata_source"] as? String == "packaged_default")
    #expect(try binding("cmd-x", in: bindings)["command_source"] as? String == "user_addition")
    #expect(disabled.map { $0["identity"] as? String } == ["alt-k"])
    #expect(try filesystemSnapshot(at: portableInputs) == before)
  }

  @Test
  func packagedUpdateChangesOnlyUntouchedEffectiveBehaviorWithoutRewritingInputs() throws {
    let firstEnvironment = try isolatedEnvironment()
    let secondEnvironment = try isolatedEnvironment()
    defer {
      try? FileManager.default.removeItem(at: firstEnvironment.root)
      try? FileManager.default.removeItem(at: secondEnvironment.root)
    }
    let firstResources = try copyFixture(
      named: "package-v1",
      to: firstEnvironment.root.appending(
        path: "inputs/package-v1",
        directoryHint: .isDirectory
      )
    )
    let secondResources = try copyFixture(
      named: "package-v2",
      to: secondEnvironment.root.appending(
        path: "inputs/package-v2",
        directoryHint: .isDirectory
      )
    )
    let firstInputs = try copyFixture(
      named: "portable",
      to: firstEnvironment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    let secondInputs = try copyFixture(
      named: "portable",
      to: secondEnvironment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    let firstBefore = try filesystemSnapshot(at: firstInputs)
    let secondBefore = try filesystemSnapshot(at: secondInputs)

    let first = try jsonObject(
      plan(
        resources: firstResources,
        profile: firstInputs.appending(path: "profile.toml"),
        profileRequired: true,
        environment: firstEnvironment
      ).output
    )
    let second = try jsonObject(
      plan(
        resources: secondResources,
        profile: secondInputs.appending(path: "profile.toml"),
        profileRequired: true,
        environment: secondEnvironment
      ).output
    )
    let firstBindings = try #require(first["bindings"] as? [[String: Any]])
    let secondBindings = try #require(second["bindings"] as? [[String: Any]])
    let firstDisabled = try #require(first["disabled_defaults"] as? [[String: Any]])
    let secondDisabled = try #require(second["disabled_defaults"] as? [[String: Any]])
    let firstRendered = try #require(first["rendered_skhdrc"] as? String)
    let secondRendered = try #require(second["rendered_skhdrc"] as? String)

    #expect(
      try binding("alt-j", in: firstBindings)["command"] as? String == "personal focus south")
    #expect(
      try binding("alt-j", in: secondBindings)["command"] as? String == "personal focus south")
    #expect(
      try binding("cmd-x", in: firstBindings)["command"] as? String == "personal open extra")
    #expect(
      try binding("cmd-x", in: secondBindings)["command"] as? String == "personal open extra")
    #expect(
      try binding("cmd-b", in: firstBindings)["command"] as? String == "package open browser v1")
    #expect(
      try binding("cmd-b", in: secondBindings)["command"] as? String == "package open browser v2")
    #expect(
      firstBindings.map { $0["identity"] as? String }
        == secondBindings.map { $0["identity"] as? String })
    #expect(!firstBindings.contains { $0["identity"] as? String == "alt-k" })
    #expect(!secondBindings.contains { $0["identity"] as? String == "alt-k" })
    #expect(
      try binding("alt-k", in: firstDisabled)["command"] as? String == "package focus north v1")
    #expect(
      try binding("alt-k", in: secondDisabled)["command"] as? String == "package focus north v2")
    #expect(
      secondRendered
        == firstRendered.replacingOccurrences(
          of: "package open browser v1",
          with: "package open browser v2"
        )
    )
    #expect(first["rendered_digest"] as? String != second["rendered_digest"] as? String)
    #expect(first["proposed_input_digest"] as? String != second["proposed_input_digest"] as? String)
    #expect(try filesystemSnapshot(at: firstInputs) == firstBefore)
    #expect(try filesystemSnapshot(at: secondInputs) == secondBefore)
  }

  @Test
  func samePortableInputsReuseEffectiveBytesAcrossIndependentHomes() throws {
    let firstEnvironment = try isolatedEnvironment(createSkhdDirectory: true)
    let secondEnvironment = try isolatedEnvironment(createSkhdDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: firstEnvironment.root)
      try? FileManager.default.removeItem(at: secondEnvironment.root)
    }
    let firstResources = try copyFixture(
      named: "package-v1",
      to: firstEnvironment.home.appending(
        path: "release/keybindings",
        directoryHint: .isDirectory
      )
    )
    let secondResources = try copyFixture(
      named: "package-v1",
      to: secondEnvironment.home.appending(
        path: "release/keybindings",
        directoryHint: .isDirectory
      )
    )
    let firstInputs = try copyFixture(
      named: "portable",
      to: firstEnvironment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    let secondInputs = try copyFixture(
      named: "portable",
      to: secondEnvironment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    for inputs in [firstInputs, secondInputs] {
      let emptyDirectory = inputs.appending(path: "empty", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: emptyDirectory, withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: emptyDirectory.path
      )
      try FileManager.default.createSymbolicLink(
        atPath: inputs.appending(path: "dangling").path,
        withDestinationPath: "empty/missing"
      )
    }
    let firstBefore = try filesystemSnapshot(at: firstInputs)
    let secondBefore = try filesystemSnapshot(at: secondInputs)
    #expect(
      firstBefore.contains {
        $0.path == "empty" && $0.type == "directory" && $0.mode == 0o700
      }
    )
    #expect(
      firstBefore.contains {
        $0.path == "dangling" && $0.type == "symlink" && $0.target == "empty/missing"
      }
    )

    let firstPlan = try plan(
      resources: firstResources,
      profile: firstInputs.appending(path: "profile.toml"),
      profileRequired: true,
      environment: firstEnvironment
    )
    let firstRepeatedPlan = try plan(
      resources: firstResources,
      profile: firstInputs.appending(path: "profile.toml"),
      profileRequired: true,
      environment: firstEnvironment
    )
    let secondPlan = try plan(
      resources: secondResources,
      profile: secondInputs.appending(path: "profile.toml"),
      profileRequired: true,
      environment: secondEnvironment
    )
    let secondRepeatedPlan = try plan(
      resources: secondResources,
      profile: secondInputs.appending(path: "profile.toml"),
      profileRequired: true,
      environment: secondEnvironment
    )
    #expect(firstPlan.output == firstRepeatedPlan.output)
    #expect(secondPlan.output == secondRepeatedPlan.output)
    let firstPlanned = try jsonObject(firstPlan.output)
    let secondPlanned = try jsonObject(secondPlan.output)
    let expected = try #require(firstPlanned["rendered_skhdrc"] as? String)
    #expect(secondPlanned["rendered_skhdrc"] as? String == expected)
    #expect(
      secondPlanned["rendered_digest"] as? String == firstPlanned["rendered_digest"] as? String)
    #expect(
      secondPlanned["proposed_input_digest"] as? String
        == firstPlanned["proposed_input_digest"] as? String
    )

    let lifecycle = KeybindingLifecycleController(
      preflight: {},
      restart: {},
      reload: {},
      verifyProcess: {}
    )
    let runner = KeybindingsApplyCommandRunner(lifecycle: lifecycle)
    let firstApplied = try runner.execute(
      resourcesRoot: firstResources,
      profileURL: firstInputs.appending(path: "profile.toml"),
      profileRequired: true,
      stateRoot: firstEnvironment.stateRoot,
      homeDirectory: firstEnvironment.home,
      json: true
    )
    let secondApplied = try runner.execute(
      resourcesRoot: secondResources,
      profileURL: secondInputs.appending(path: "profile.toml"),
      profileRequired: true,
      stateRoot: secondEnvironment.stateRoot,
      homeDirectory: secondEnvironment.home,
      json: true
    )
    let firstApplyReport = try jsonObject(firstApplied.output)
    let secondApplyReport = try jsonObject(secondApplied.output)
    let firstGenerated = try String(
      contentsOf: firstEnvironment.stateRoot.appending(path: "keybindings/current/skhdrc"),
      encoding: .utf8
    )
    let secondGenerated = try String(
      contentsOf: secondEnvironment.stateRoot.appending(path: "keybindings/current/skhdrc"),
      encoding: .utf8
    )
    let firstCurrent = firstEnvironment.stateRoot.appending(path: "keybindings/current")
    let secondCurrent = secondEnvironment.stateRoot.appending(path: "keybindings/current")
    let firstTarget = try FileManager.default.destinationOfSymbolicLink(
      atPath: firstCurrent.path
    )
    let secondTarget = try FileManager.default.destinationOfSymbolicLink(
      atPath: secondCurrent.path
    )

    #expect(firstApplied.succeeded)
    #expect(secondApplied.succeeded)
    #expect(firstApplyReport["outcome"] as? String == "applied")
    #expect(secondApplyReport["outcome"] as? String == "applied")
    #expect(firstGenerated == expected)
    #expect(secondGenerated == expected)
    #expect(firstEnvironment.stateRoot != secondEnvironment.stateRoot)
    #expect(firstTarget != secondTarget)
    #expect(firstCurrent.resolvingSymlinksInPath().path.hasPrefix(firstEnvironment.stateRoot.path))
    #expect(
      secondCurrent.resolvingSymlinksInPath().path.hasPrefix(secondEnvironment.stateRoot.path))
    #expect(try filesystemSnapshot(at: firstInputs) == firstBefore)
    #expect(try filesystemSnapshot(at: secondInputs) == secondBefore)
  }

  private func plan(
    resources: URL,
    profile: URL,
    profileRequired: Bool,
    environment: IsolatedKeybindingEnvironment
  ) throws -> (output: String, succeeded: Bool) {
    try KeybindingsPlanCommandRunner.live.execute(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: profileRequired,
      stateRoot: environment.stateRoot,
      homeDirectory: environment.home,
      json: true
    )
  }

  private func binding(
    _ identity: String,
    in bindings: [[String: Any]]
  ) throws -> [String: Any] {
    try #require(bindings.first { $0["identity"] as? String == identity })
  }

  private func filesystemSnapshot(at root: URL) throws -> [FilesystemSnapshotEntry] {
    let maximumEntries = 128
    let maximumDepth = 16
    let maximumRegularBytes = 2 * 1024 * 1024
    let maximumPathBytes = 1_024
    var entries: [FilesystemSnapshotEntry] = []
    var regularBytes = 0

    func visit(_ url: URL, path: String, depth: Int) throws {
      guard path.utf8.count <= maximumPathBytes else {
        throw FilesystemSnapshotError.pathTooLong
      }
      guard entries.count < maximumEntries else {
        throw FilesystemSnapshotError.tooManyEntries
      }
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else {
        throw FilesystemSnapshotError.cannotInspect(path)
      }
      let mode = UInt16(metadata.st_mode & 0o7777)
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        entries.append(
          FilesystemSnapshotEntry(path: path, type: "directory", mode: mode)
        )
        let descriptor = try PinnedFilesystem.openDirectory(at: url)
        defer { Darwin.close(descriptor) }
        let inventory = try PinnedFilesystem.directoryEntries(
          descriptor: descriptor,
          url: url,
          limit: maximumEntries - entries.count
        )
        guard !inventory.truncated else {
          throw FilesystemSnapshotError.tooManyEntries
        }
        let names = inventory.entries
        guard names.isEmpty || depth < maximumDepth else {
          throw FilesystemSnapshotError.tooDeep
        }
        for name in names {
          try visit(
            url.appending(path: name),
            path: path == "." ? name : "\(path)/\(name)",
            depth: depth + 1
          )
        }
      case S_IFREG:
        guard metadata.st_size >= 0 else {
          throw FilesystemSnapshotError.cannotInspect(path)
        }
        regularBytes += Int(metadata.st_size)
        guard regularBytes <= maximumRegularBytes else {
          throw FilesystemSnapshotError.tooMuchRegularData
        }
        entries.append(
          FilesystemSnapshotEntry(
            path: path,
            type: "regular",
            mode: mode,
            digest: sha256Digest(try Data(contentsOf: url))
          )
        )
      case S_IFLNK:
        entries.append(
          FilesystemSnapshotEntry(
            path: path,
            type: "symlink",
            mode: mode,
            target: try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
          )
        )
      case S_IFIFO:
        entries.append(FilesystemSnapshotEntry(path: path, type: "fifo", mode: mode))
      case S_IFSOCK:
        entries.append(FilesystemSnapshotEntry(path: path, type: "socket", mode: mode))
      case S_IFBLK:
        entries.append(FilesystemSnapshotEntry(path: path, type: "block_device", mode: mode))
      case S_IFCHR:
        entries.append(
          FilesystemSnapshotEntry(path: path, type: "character_device", mode: mode)
        )
      default:
        entries.append(FilesystemSnapshotEntry(path: path, type: "unknown", mode: mode))
      }
    }

    try visit(root, path: ".", depth: 0)
    return entries
  }

  private func isolatedEnvironment(
    createSkhdDirectory: Bool = false
  ) throws -> IsolatedKeybindingEnvironment {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybinding-portability-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    if createSkhdDirectory {
      try FileManager.default.createDirectory(
        at: home.appending(path: ".config/skhd", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
    }
    return IsolatedKeybindingEnvironment(root: root, home: home, stateRoot: stateRoot)
  }

  private func copyFixture(named name: String, to destination: URL) throws -> URL {
    let source = fixtureRoot.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private var fixtureRoot: URL {
    repositoryRoot.appending(
      path: "Tests/Fixtures/Keybindings/Portability",
      directoryHint: .isDirectory
    )
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func jsonObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }
}

private struct IsolatedKeybindingEnvironment {
  let root: URL
  let home: URL
  let stateRoot: URL
}

private struct FilesystemSnapshotEntry: Equatable {
  let path: String
  let type: String
  let mode: UInt16
  var target: String? = nil
  var digest: String? = nil
}

private enum FilesystemSnapshotError: Error {
  case cannotInspect(String)
  case pathTooLong
  case tooDeep
  case tooManyEntries
  case tooMuchRegularData
}
