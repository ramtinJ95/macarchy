import Darwin
import Foundation

@testable import MacarchyCLI
@testable import ThemeCore

// Shares command wiring only; fixtures retain provider setup, runners, and consumer paths.
struct PresetLifecycleTestHarness {
  let profile: URL
  let state: URL
  let home: URL

  func plan() throws -> (output: String, succeeded: Bool) {
    try EnvironmentPlanCommandRunner(prerequisites: .assumed).execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      json: true
    )
  }

  func apply(
    runner: EnvironmentApplyCommandRunner,
    consumerPaths: ThemeConsumerPaths,
    adopt: String?
  ) async throws -> (output: String, succeeded: Bool) {
    try await runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      adopt: adopt,
      json: true
    )
  }

  func status(
    runner: EnvironmentStatusCommandRunner,
    consumerPaths: ThemeConsumerPaths
  ) throws -> (output: String, succeeded: Bool) {
    try runner.execute(
      resourcesRoot: repositoryRoot.appending(path: "Environment"),
      profileURL: profile,
      profileRequired: true,
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      json: true
    )
  }

  func teardown(consumerPaths: ThemeConsumerPaths) async throws -> (
    output: String, succeeded: Bool
  ) {
    try await EnvironmentTeardownCommandRunner().execute(
      stateRoot: state,
      homeDirectory: home,
      consumerPaths: consumerPaths,
      dryRun: false,
      json: true
    )
  }
}

/// A portable profile that disables every provider and selects only the given tools and presets.
func presetTestProfile(
  bat: Bool = false, btop: Bool = false, presets: KeyValuePairs<String, Bool>
) -> String {
  """
  schema_version = 1
  [focus_ring]
  provider = "disabled"
  [terminal]
  provider = "disabled"
  [shell]
  provider = "disabled"
  [editor]
  provider = "disabled"
  [tools]
  bat = \(bat)
  eza = false
  btop = \(btop)
  yazi = false
  [presets]

  """ + presets.map { "\($0.key) = \($0.value)\n" }.joined()
}

/// Reports one fixed reconcile status and one fixed inspect status for every adapter.
func stubThemeController(
  reconciled: (status: String, message: String),
  inspected: (status: String, message: String)
) -> DesktopThemeController {
  DesktopThemeController(
    reconcile: { adapterIDs, _, _ in
      DesktopThemeReconciliation(
        generationID: "theme",
        results: adapterIDs.map {
          DesktopThemeAdapterStatus(
            adapterID: $0, requirement: "required", status: reconciled.status,
            message: reconciled.message)
        },
        succeeded: true
      )
    },
    inspect: { adapterIDs, _, _ in
      adapterIDs.map {
        DesktopThemeAdapterStatus(
          adapterID: $0, requirement: "required", status: inspected.status,
          message: inspected.message)
      }
    }
  )
}

/// The lstat identity, link destination and bytes of each path in an externally owned tuple.
struct ExternalTupleSnapshot: Equatable {
  struct Entry: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let userID: UInt32
    let groupID: UInt32
    let flags: UInt32
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
    let statusChangeTimeSeconds: Int64
    let statusChangeTimeNanoseconds: Int64
    let linkDestination: String?
    let data: Data?
  }

  let entries: [String: Entry]

  /// Omits missing paths unless `requireAll`, which refuses them instead.
  init(_ paths: [URL], requireAll: Bool = false) throws {
    var entries = [String: Entry]()
    for path in paths {
      var metadata = stat()
      guard lstat(path.path, &metadata) == 0 else {
        if errno == ENOENT, !requireAll { continue }
        throw EnvironmentLifecycleError.system("snapshot external tuple", path, errno)
      }
      let kind = metadata.st_mode & S_IFMT
      entries[path.path] = Entry(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        mode: UInt32(metadata.st_mode),
        size: Int64(metadata.st_size),
        userID: metadata.st_uid,
        groupID: metadata.st_gid,
        flags: metadata.st_flags,
        modificationTimeSeconds: Int64(metadata.st_mtimespec.tv_sec),
        modificationTimeNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
        statusChangeTimeSeconds: Int64(metadata.st_ctimespec.tv_sec),
        statusChangeTimeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
        linkDestination: kind == S_IFLNK
          ? try FileManager.default.destinationOfSymbolicLink(atPath: path.path) : nil,
        data: kind == S_IFREG ? try BoundedRegularFile.read(at: path).data : nil
      )
    }
    self.entries = entries
  }
}

/// A preset whose configuration file goes through the shared preset file transaction.
protocol PresetFileFixture: Sendable {
  var root: URL { get }
  var home: URL { get }
  var state: URL { get }
  var presetFile: URL { get }
  /// Each owned theme link and the generated file it points at.
  var themeLinks: [(link: URL, destination: URL)] { get }
  func setPresetEnabled(_ enabled: Bool) throws
  func plan() throws -> (output: String, succeeded: Bool)
  func applyPreset(
    adopt: String?,
    faultInjector: @escaping @Sendable (EnvironmentTransactionCheckpoint) throws -> Void
  ) async throws -> (output: String, succeeded: Bool)
  func status() throws -> (output: String, succeeded: Bool)
  func teardown() async throws -> (output: String, succeeded: Bool)
}

extension PresetFileFixture {
  func applyPreset(adopt: String? = nil) async throws -> (output: String, succeeded: Bool) {
    try await applyPreset(adopt: adopt) { _ in }
  }

  func recoverTransaction() throws -> Bool {
    try EnvironmentTransactionCoordinator(homeDirectory: home, stateRoot: state).recoverLocked()
  }

  func runtimeAdapterIDs() throws -> Set<String> {
    try ThemeRuntimeSelection.enabledAdapterIDs(stateRoot: state, homeDirectory: home)
  }

  func destination(of link: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
  }
}
