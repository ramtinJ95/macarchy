import Darwin
import Foundation
import Synchronization
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
  func managedReapplyPublishesOnlyUpdatedInheritedBehaviorWithoutRewritingInputs() throws {
    let environment = try isolatedEnvironment(createSkhdDirectory: true)
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let firstResources = try copyFixture(
      named: "package-v1",
      to: environment.root.appending(
        path: "inputs/package-v1",
        directoryHint: .isDirectory
      )
    )
    let secondResources = try copyFixture(
      named: "package-v2",
      to: environment.root.appending(
        path: "inputs/package-v2",
        directoryHint: .isDirectory
      )
    )
    let portableInputs = try copyFixture(
      named: "portable",
      to: environment.home.appending(
        path: "dotfiles/keybindings",
        directoryHint: .isDirectory
      )
    )
    let profile = portableInputs.appending(path: "profile.toml")
    let inputsBefore = try filesystemSnapshot(at: portableInputs)
    let lifecycleCalls = Mutex<[String]>([])
    let runner = KeybindingsApplyCommandRunner(
      lifecycle: KeybindingLifecycleController(
        preflight: { lifecycleCalls.withLock { $0.append("preflight") } },
        restart: { lifecycleCalls.withLock { $0.append("restart") } },
        reload: { lifecycleCalls.withLock { $0.append("reload") } },
        verifyProcess: { lifecycleCalls.withLock { $0.append("verify") } },
        inspectProcess: { .testRunning }
      )
    )

    let initialPlan = try plan(
      resources: firstResources,
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    let initialPlanReport = try jsonObject(initialPlan.output)
    let initialProvider = try #require(initialPlanReport["provider"] as? [String: Any])
    let applied = try runner.execute(
      resourcesRoot: firstResources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: environment.stateRoot,
      homeDirectory: environment.home,
      adopt: nil,
      json: true
    )
    let appliedReport = try jsonObject(applied.output)
    let current = KeybindingGenerationInspector().inspect(stateRoot: environment.stateRoot)
    let firstRendered = try String(
      contentsOf: environment.stateRoot.appending(path: "keybindings/current/skhdrc"),
      encoding: .utf8
    )

    let update = try plan(
      resources: secondResources,
      profile: profile,
      profileRequired: true,
      environment: environment
    )
    let report = try jsonObject(update.output)
    let bindings = try #require(report["bindings"] as? [[String: Any]])
    let disabled = try #require(report["disabled_defaults"] as? [[String: Any]])
    let generation = try #require(report["generation"] as? [String: Any])
    let updateProvider = try #require(report["provider"] as? [String: Any])
    let actions = try #require(report["actions"] as? [[String: Any]])
    let secondRendered = try #require(report["rendered_skhdrc"] as? String)
    let reapplied = try runner.execute(
      resourcesRoot: secondResources,
      profileURL: profile,
      profileRequired: true,
      stateRoot: environment.stateRoot,
      homeDirectory: environment.home,
      adopt: nil,
      json: true
    )
    let reappliedReport = try jsonObject(reapplied.output)
    let updatedCurrent = KeybindingGenerationInspector().inspect(stateRoot: environment.stateRoot)
    let updatedRendered = try String(
      contentsOf: environment.stateRoot.appending(path: "keybindings/current/skhdrc"),
      encoding: .utf8
    )
    let managedProvider = KeybindingProviderInspector().inspect(
      homeDirectory: environment.home,
      stateRoot: environment.stateRoot,
      generation: updatedCurrent
    )

    #expect(initialPlan.succeeded)
    #expect(initialProvider["status"] as? String == "install_required")
    #expect(initialProvider["ownership"] as? String == "ordinary_directory")
    #expect(applied.succeeded)
    #expect(appliedReport["outcome"] as? String == "applied")
    #expect(appliedReport["lifecycle"] as? String == "restart")
    #expect(current.status == .current)
    #expect(update.succeeded)
    #expect(report["outcome"] as? String == "ready")
    #expect(report["mutated"] as? Bool == false)
    #expect(generation["status"] as? String == "current")
    #expect(generation["generation_id"] as? String == current.generationID)
    #expect(generation["current_input_digest"] as? String == current.inputDigest)
    #expect(generation["current_rendered_digest"] as? String == current.renderedDigest)
    #expect(updateProvider["status"] as? String == "managed")
    #expect(updateProvider["adoption_evidence_digest"] == nil)
    #expect(actions.map { $0["id"] as? String } == ["publish_generation"])
    #expect(bindings.map { $0["identity"] as? String } == ["alt-j", "cmd-b", "cmd-x"])
    #expect(
      try binding("alt-j", in: bindings)["command"] as? String == "personal focus south")
    #expect(
      try binding("alt-j", in: bindings)["command_source"] as? String == "user_replacement")
    #expect(
      try binding("cmd-x", in: bindings)["command"] as? String == "personal open extra")
    #expect(
      try binding("cmd-x", in: bindings)["command_source"] as? String == "user_addition")
    #expect(
      try binding("cmd-b", in: bindings)["command"] as? String == "package open browser v2")
    #expect(
      try binding("cmd-b", in: bindings)["command_source"] as? String == "packaged_default")
    #expect(!bindings.contains { $0["identity"] as? String == "alt-k" })
    #expect(disabled.map { $0["identity"] as? String } == ["alt-k"])
    #expect(
      try binding("alt-k", in: disabled)["command"] as? String == "package focus north v2")
    #expect(
      secondRendered
        == firstRendered.replacingOccurrences(
          of: "package open browser v1",
          with: "package open browser v2"
        )
    )
    #expect(report["rendered_digest"] as? String != current.renderedDigest)
    #expect(report["proposed_input_digest"] as? String != current.inputDigest)
    #expect(reapplied.succeeded)
    #expect(reappliedReport["outcome"] as? String == "applied")
    #expect(reappliedReport["lifecycle"] as? String == "reload")
    #expect(updatedCurrent.status == .current)
    #expect(updatedCurrent.inputDigest == report["proposed_input_digest"] as? String)
    #expect(updatedCurrent.renderedDigest == report["rendered_digest"] as? String)
    #expect(updatedRendered == secondRendered)
    #expect(managedProvider.status == .managed)
    #expect(managedProvider.adoptionEvidenceDigest == nil)
    #expect(
      lifecycleCalls.withLock { $0 }
        == ["preflight", "restart", "verify", "preflight", "reload", "verify"]
    )
    #expect(try filesystemSnapshot(at: portableInputs) == inputsBefore)
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
    }
    let firstBefore = try filesystemSnapshot(at: firstInputs)
    let secondBefore = try filesystemSnapshot(at: secondInputs)
    #expect(firstBefore != secondBefore)
    #expect(
      firstBefore.map(\.portableContent)
        == secondBefore.map(\.portableContent)
    )
    #expect(
      firstBefore.contains {
        $0.path == "empty" && $0.type == "directory" && $0.mode == 0o700
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
      verifyProcess: {},
      inspectProcess: { .testRunning }
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

  @Test
  func filesystemSnapshotStopsAtTheOverflowSentinel() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let inventory = environment.root.appending(path: "overflow", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: false)
    for index in 0..<256 {
      #expect(
        FileManager.default.createFile(
          atPath: inventory.appending(path: "entry-\(index)").path,
          contents: Data()
        )
      )
    }

    #expect(throws: FilesystemSnapshotError.tooManyEntries) {
      _ = try filesystemSnapshot(at: inventory)
    }
  }

  @Test
  func filesystemSnapshotRejectsFIFOsAndSymlinksWithoutFollowingThem() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }

    let fifoRoot = environment.root.appending(path: "fifo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: fifoRoot, withIntermediateDirectories: false)
    let fifo = fifoRoot.appending(path: "entry")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: FilesystemSnapshotError.unsupportedEntry("entry")) {
      _ = try filesystemSnapshot(at: fifoRoot)
    }

    let symlinkRoot = environment.root.appending(path: "symlink", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      atPath: symlinkRoot.appending(path: "entry").path,
      withDestinationPath: "missing"
    )
    #expect(throws: FilesystemSnapshotError.cannotOpen("entry")) {
      _ = try filesystemSnapshot(at: symlinkRoot)
    }
  }

  @Test
  func filesystemSnapshotRejectsARegularFileReplacedAfterOpen() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let inventory = environment.root.appending(path: "race", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: false)
    let entry = inventory.appending(path: "entry")
    try Data("original".utf8).write(to: entry)
    var replaced = false

    #expect(throws: FilesystemSnapshotError.changedEntry("entry")) {
      _ = try filesystemSnapshot(at: inventory) { opened in
        guard opened == entry, !replaced else { return }
        replaced = true
        try FileManager.default.removeItem(at: opened)
        guard mkfifo(opened.path, 0o600) == 0 else {
          throw FilesystemSnapshotError.cannotOpen("entry")
        }
      }
    }
  }

  @Test
  func filesystemSnapshotDetectsSameByteSameModeReplacementAndRewrite() throws {
    let environment = try isolatedEnvironment()
    defer { try? FileManager.default.removeItem(at: environment.root) }
    let inventory = environment.root.appending(path: "evidence", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: false)
    let entry = inventory.appending(path: "entry")
    let replacement = inventory.appending(path: "replacement")
    let payload = Data("unchanged payload".utf8)
    try payload.write(to: entry)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: entry.path
    )
    let original = try #require(filesystemSnapshot(at: inventory).first { $0.path == "entry" })

    try payload.write(to: replacement)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: replacement.path
    )
    #expect(rename(replacement.path, entry.path) == 0)
    let replaced = try #require(filesystemSnapshot(at: inventory).first { $0.path == "entry" })

    #expect(replaced.portableContent == original.portableContent)
    #expect(replaced.device == original.device)
    #expect(replaced.inode != original.inode)
    #expect(replaced != original)

    let writable = try FileHandle(forWritingTo: entry)
    defer { try? writable.close() }
    try writable.seek(toOffset: 0)
    try writable.write(contentsOf: payload)
    try writable.truncate(atOffset: UInt64(payload.count))
    try writable.synchronize()
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 978_393_661)],
      ofItemAtPath: entry.path
    )
    let rewritten = try #require(filesystemSnapshot(at: inventory).first { $0.path == "entry" })

    #expect(rewritten.portableContent == replaced.portableContent)
    #expect(rewritten.device == replaced.device)
    #expect(rewritten.inode == replaced.inode)
    #expect(
      rewritten.modifiedSeconds != replaced.modifiedSeconds
        || rewritten.modifiedNanoseconds != replaced.modifiedNanoseconds
        || rewritten.changedSeconds != replaced.changedSeconds
        || rewritten.changedNanoseconds != replaced.changedNanoseconds
    )
    #expect(rewritten != replaced)
  }

  private func plan(
    resources: URL,
    profile: URL,
    profileRequired: Bool,
    environment: IsolatedKeybindingEnvironment
  ) throws -> (output: String, succeeded: Bool) {
    try KeybindingsPlanCommandRunner(
      effectiveInspector: KeybindingEffectiveBehaviorInspector(
        processInspector: KeybindingProcessInspector { .testRunning }
      )
    ).execute(
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

  private func filesystemSnapshot(
    at root: URL,
    afterOpeningRegularFile: ((URL) throws -> Void)? = nil
  ) throws -> [FilesystemSnapshotEntry] {
    let maximumEntries = 256
    let maximumDepth = 16
    let maximumRegularBytes = 2 * 1024 * 1024
    let maximumPathBytes = 1_024
    var entries: [FilesystemSnapshotEntry] = []
    var regularBytes = 0

    func metadata(descriptor: Int32, path: String) throws -> stat {
      var value = stat()
      guard fstat(descriptor, &value) == 0 else {
        throw FilesystemSnapshotError.cannotInspect(path)
      }
      return value
    }

    func sameIdentity(_ left: stat, _ right: stat) -> Bool {
      left.st_dev == right.st_dev
        && left.st_ino == right.st_ino
        && left.st_mode & S_IFMT == right.st_mode & S_IFMT
    }

    func unchanged(_ left: stat, _ right: stat) -> Bool {
      sameIdentity(left, right)
        && left.st_mode == right.st_mode
        && left.st_size == right.st_size
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
        && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
        && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
        && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    func visit(
      descriptor: Int32,
      url: URL,
      path: String,
      depth: Int,
      parentDescriptor: Int32? = nil,
      name: String? = nil
    ) throws {
      guard path.utf8.count <= maximumPathBytes else {
        throw FilesystemSnapshotError.pathTooLong
      }
      guard entries.count < maximumEntries else {
        throw FilesystemSnapshotError.tooManyEntries
      }
      let initial = try metadata(descriptor: descriptor, path: path)
      let mode = UInt16(initial.st_mode & 0o7777)
      switch initial.st_mode & S_IFMT {
      case S_IFDIR:
        entries.append(
          FilesystemSnapshotEntry(
            path: path,
            type: "directory",
            mode: mode,
            metadata: initial
          )
        )
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
          let childPath = path == "." ? name : "\(path)/\(name)"
          let childURL = url.appending(path: name)
          let childDescriptor = name.withCString {
            Darwin.openat(
              descriptor,
              $0,
              O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
          }
          guard childDescriptor >= 0 else {
            throw FilesystemSnapshotError.cannotOpen(childPath)
          }
          do {
            defer { Darwin.close(childDescriptor) }
            try visit(
              descriptor: childDescriptor,
              url: childURL,
              path: childPath,
              depth: depth + 1,
              parentDescriptor: descriptor,
              name: name
            )
          }
        }
      case S_IFREG:
        guard initial.st_size >= 0 else {
          throw FilesystemSnapshotError.cannotInspect(path)
        }
        let remainingBytes = maximumRegularBytes - regularBytes
        guard initial.st_size <= remainingBytes else {
          throw FilesystemSnapshotError.tooMuchRegularData
        }
        try afterOpeningRegularFile?(url)
        let file = try BoundedRegularFile.read(
          descriptor: descriptor,
          maximumSize: remainingBytes
        )
        guard file.data.count == initial.st_size else {
          throw FilesystemSnapshotError.changedEntry(path)
        }
        regularBytes += file.data.count
        entries.append(
          FilesystemSnapshotEntry(
            path: path,
            type: "regular",
            mode: mode,
            digest: sha256Digest(file.data),
            metadata: initial
          )
        )
      default:
        throw FilesystemSnapshotError.unsupportedEntry(path)
      }

      let final = try metadata(descriptor: descriptor, path: path)
      guard unchanged(initial, final) else {
        throw FilesystemSnapshotError.changedEntry(path)
      }
      if let parentDescriptor, let name {
        var current = stat()
        let result = name.withCString {
          Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, sameIdentity(initial, current) else {
          throw FilesystemSnapshotError.changedEntry(path)
        }
      }
    }

    let rootDescriptor = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(rootDescriptor) }
    try visit(descriptor: rootDescriptor, url: root, path: ".", depth: 0)
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
  let digest: String?
  let device: UInt64
  let inode: UInt64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64

  init(path: String, type: String, mode: UInt16, digest: String? = nil, metadata: stat) {
    self.path = path
    self.type = type
    self.mode = mode
    self.digest = digest
    device = UInt64(metadata.st_dev)
    inode = UInt64(metadata.st_ino)
    modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
    changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
  }

  var portableContent: FilesystemSnapshotContent {
    FilesystemSnapshotContent(path: path, type: type, mode: mode, digest: digest)
  }
}

private struct FilesystemSnapshotContent: Equatable {
  let path: String
  let type: String
  let mode: UInt16
  let digest: String?
}

private enum FilesystemSnapshotError: Error, Equatable {
  case cannotOpen(String)
  case cannotInspect(String)
  case changedEntry(String)
  case pathTooLong
  case tooDeep
  case tooManyEntries
  case tooMuchRegularData
  case unsupportedEntry(String)
}
