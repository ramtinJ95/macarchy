import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

let allIntegrationIDs = [
  "kitty.include",
  "bat.selector",
  "bat.theme-link",
  "eza.environment",
  "eza.theme-link",
  "btop.selector",
  "btop.theme-link",
  "yazi.selector",
  "yazi.flavor-link",
  "yazi.syntax-link",
  "atuin.selector",
  "atuin.theme-link",
  "neovim.watcher",
  "neovim.theme-link",
  "starship.behavior",
  "starship.configuration-link",
  "pi.selector",
  "pi.theme-link",
  "herdr.selector",
  "tuicr.selector",
  "tuicr.theme-link",
  "tuicr.syntax-link",
  "codex.selector",
  "codex.theme-link",
  "spicetify.selectors",
  "spicetify.color-link",
]

/// Teardown statuses when no legacy setup record exists.
let unownedTeardownStatuses = Dictionary(
  uniqueKeysWithValues: allIntegrationIDs.map { ($0, SetupIntegrationResult.Status.none) })

protocol IntegrationStatusResult {
  associatedtype IntegrationStatus: Equatable

  var id: String { get }
  var status: IntegrationStatus { get }
}

extension SetupIntegrationResult: IntegrationStatusResult {
  typealias IntegrationStatus = Status
}

func expectStatuses<Result: IntegrationStatusResult>(
  _ results: [Result],
  _ expectedByID: [String: Result.IntegrationStatus]
) {
  let actualIDs = results.map(\.id)
  let actualIDSet = Set(actualIDs)
  let expectedIDSet = Set(expectedByID.keys)
  let duplicateIDs = Dictionary(grouping: actualIDs, by: { $0 })
    .filter { $0.value.count > 1 }.keys.sorted()
  let missingIDs = expectedIDSet.subtracting(actualIDSet).sorted()
  let unexpectedIDs = actualIDSet.subtracting(expectedIDSet).sorted()

  #expect(duplicateIDs.isEmpty, "Duplicate integration IDs: \(duplicateIDs)")
  #expect(missingIDs.isEmpty, "Missing integration IDs: \(missingIDs)")
  #expect(unexpectedIDs.isEmpty, "Unexpected integration IDs: \(unexpectedIDs)")

  for id in expectedByID.keys.sorted() {
    guard
      let result = results.first(where: { $0.id == id }),
      let expectedStatus = expectedByID[id]
    else { continue }
    #expect(result.status == expectedStatus, "Unexpected status for \(id)")
  }
}

enum FixtureError: Error {
  case interrupted
}

final class Fixture: LegacySetupOwnershipFixture {
  let root: URL
  let home: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-ownership-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
  }

  var stateRoot: URL {
    home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
  }

  var kittyConfiguration: URL {
    home.appending(path: ".config/kitty/kitty.conf")
  }

  var includeDirective: String {
    ThemeActivationCoordinator.kittyIncludeDirective(root: stateRoot)
  }

  var manifest: URL {
    stateRoot.appending(path: "state/setup/ownership.json")
  }

  var backup: URL {
    stateRoot.appending(path: "state/setup/backups/kitty.conf")
  }

  var batSelectorBackup: URL {
    stateRoot.appending(path: "state/setup/backups/bat-config")
  }

  var ezaEnvironmentBackup: URL {
    stateRoot.appending(path: "state/setup/backups/zshrc")
  }

  var replacement: URL {
    kittyConfiguration.deletingLastPathComponent()
      .appending(path: ".macarchy-kitty-transaction")
  }

  var batConfiguration: URL {
    home.appending(path: ".config/bat/config")
  }

  var batThemeLink: URL {
    home.appending(path: ".config/bat/themes/\(BatAdapter.themeFileName)")
  }

  var batThemeDestination: URL {
    stateRoot.appending(path: "current/\(TextMateThemeArtifact.outputPath)")
  }

  var batThemeRemoval: URL {
    batThemeLink.deletingLastPathComponent()
      .appending(path: ".macarchy-bat-theme-link-removal")
  }

  var shellConfiguration: URL {
    home.appending(path: ".zshrc")
  }

  var ezaThemeLink: URL {
    home.appending(path: ".config/eza/theme.yml")
  }

  var ezaThemeDestination: URL {
    stateRoot.appending(path: "current/\(EzaAdapter.outputPath)")
  }

  var batDirective: String {
    BatAdapter.themeDirective
  }

  var ezaDirective: String {
    EzaAdapter.environmentDirective(
      configurationDirectoryURL: ezaThemeLink.deletingLastPathComponent()
    )
  }

  var btopConfiguration: URL {
    home.appending(path: ".config/btop/btop.conf")
  }

  var btopThemeLink: URL {
    home.appending(path: ".config/btop/themes/\(BtopAdapter.themeFileName)")
  }

  var btopThemeDestination: URL {
    stateRoot.appending(path: "current/\(BtopAdapter.outputPath)")
  }

  var yaziConfiguration: URL {
    home.appending(path: ".config/yazi/theme.toml")
  }

  var yaziFlavorLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/flavor.toml")
  }

  var yaziSyntaxLink: URL {
    home.appending(
      path: ".config/yazi/flavors/\(YaziAdapter.flavorName).yazi/tmtheme.xml")
  }

  var atuinConfiguration: URL {
    home.appending(path: ".config/atuin/config.toml")
  }

  var atuinThemeLink: URL {
    home.appending(path: ".config/atuin/themes/\(AtuinAdapter.themeName).toml")
  }

  var atuinThemeDestination: URL {
    stateRoot.appending(path: "current/\(AtuinAdapter.outputPath)")
  }

  func batConfigurationText() throws -> String {
    try String(contentsOf: batConfiguration, encoding: .utf8)
  }

  func shellConfigurationText() throws -> String {
    try String(contentsOf: shellConfiguration, encoding: .utf8)
  }

  func linkDestination(_ url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
  }

  func configuration() throws -> String {
    try String(contentsOf: kittyConfiguration, encoding: .utf8)
  }

  func permissions() throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: kittyConfiguration.path)[.posixPermissions]
        as? Int
    )
  }

  func setExtendedAttribute(name: String, value: String) throws {
    try MacarchyCLITests.setExtendedAttribute(name, value: value, at: kittyConfiguration)
  }

  func extendedAttribute(name: String) throws -> String {
    try MacarchyCLITests.extendedAttribute(name, at: kittyConfiguration)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

func decode<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(type, from: Data(output.utf8))
}

struct TeardownReport: Decodable {
  let integrations: [IntegrationReport]
}

struct IntegrationReport: Decodable {
  let id: String
  let status: String
  let target: String
  let message: String
  let mutationAttempted: Bool
}

extension IntegrationReport: IntegrationStatusResult {
  typealias IntegrationStatus = String
}

/// A home whose legacy setup ownership can be written exactly as an older release left it.
/// Setup no longer creates these records, so teardown tests build them directly.
protocol LegacySetupOwnershipFixture {
  var home: URL { get }
}

struct LegacySetupHome: LegacySetupOwnershipFixture {
  let home: URL
}

enum LegacyLinkPlacement {
  case target
  /// An interrupted teardown moved the link to its removal claim.
  case claimed
  case absent
}

private struct UnsupportedLegacyStep: Error {
  let id: String
}

extension LegacySetupOwnershipFixture {
  var ownershipContext: SetupOwnershipManager.Context {
    SetupOwnershipManager.Context(homeDirectory: home)
  }

  func writeLegacyOwnership(_ records: [SetupOwnershipRecord]) throws {
    let context = ownershipContext
    try FileManager.default.createDirectory(
      at: context.stateRoot, withIntermediateDirectories: true)
    try SetupOwnershipManager().persist(
      records: records.sorted { $0.id < $1.id }, context: context)
  }

  /// A whole-file or Spicetify selector record. The target holds `onDisk` (the installed bytes
  /// by default), the 0600 backup holds `original`, and `residue` sits at the replacement name.
  func legacyFileRecord(
    _ id: String,
    original: String,
    installed: String,
    onDisk: String? = nil,
    phase: SetupOwnershipRecord.Phase = .applied,
    backupPresent: Bool = true,
    residue: String? = nil
  ) throws -> SetupOwnershipRecord {
    let step = try legacyStep(id)
    let backup: URL
    let replacementName: String
    let kind: SetupOwnershipRecord.Kind
    switch step.mechanism {
    case .regularFile(let url, let name, _, _):
      backup = url
      replacementName = name
      kind = .regularFile
    case .spicetifySelectors(let url, let name):
      backup = url
      replacementName = name
      kind = .spicetifySelection
    default:
      throw UnsupportedLegacyStep(id: id)
    }
    try writeLegacyFile(onDisk ?? installed, to: step.target)
    if backupPresent {
      try writeLegacyFile(original, to: backup)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    if let residue {
      try writeLegacyFile(
        residue, to: step.target.deletingLastPathComponent().appending(path: replacementName))
    }
    return SetupOwnershipRecord(
      id: id,
      phase: phase,
      kind: kind,
      targetPath: step.target.path,
      backupPath: SetupOwnershipManager().relativePath(
        backup, below: ownershipContext.stateRoot),
      originalDigest: sha256Digest(Data(original.utf8)),
      installedDigest: sha256Digest(Data(installed.utf8)),
      linkDestination: nil
    )
  }

  func legacyThemeLink(
    _ id: String,
    phase: SetupOwnershipRecord.Phase = .applied,
    placement: LegacyLinkPlacement = .target
  ) throws -> SetupOwnershipRecord {
    let step = try legacyStep(id)
    guard case .themeLink(let destination, _) = step.mechanism else {
      throw UnsupportedLegacyStep(id: id)
    }
    try FileManager.default.createDirectory(
      at: step.target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let location: URL? =
      switch placement {
      case .target: step.target
      case .claimed: SetupOwnershipManager().themeLinkRemovalURL(id: id, target: step.target)
      case .absent: nil
      }
    if let location {
      try FileManager.default.createSymbolicLink(at: location, withDestinationURL: destination)
    }
    return SetupOwnershipRecord(
      id: id,
      phase: phase,
      kind: .symbolicLink,
      targetPath: step.target.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: sha256Digest(Data(destination.path.utf8)),
      linkDestination: destination.path
    )
  }

  /// The key-level Pi record; `contents` is the settings file as the release left it.
  func legacyPiSelector(
    contents: String,
    phase: SetupOwnershipRecord.Phase = .applied
  ) throws -> SetupOwnershipRecord {
    let target = ownershipContext.piConfiguration
    try writeLegacyFile(contents, to: target)
    return SetupOwnershipRecord(
      id: SetupOwnershipManager.piSelectorID,
      phase: phase,
      kind: .jsonSelector,
      targetPath: target.path,
      backupPath: nil,
      originalDigest: nil,
      installedDigest: SetupOwnershipManager().piSelectorContractDigest(),
      linkDestination: nil
    )
  }

  private func legacyStep(_ id: String) throws -> ConsumerSetupPlan.Step {
    try #require(
      SetupOwnershipManager().consumerSetupPlans(context: ownershipContext)
        .flatMap(\.steps).first { $0.id == id })
  }

  private func writeLegacyFile(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }
}

extension Fixture {
  /// The Kitty include an older release added to `original`.
  func legacyKittyInclude(
    original: String = "font_size 13\n",
    onDisk: String? = nil,
    phase: SetupOwnershipRecord.Phase = .applied,
    backupPresent: Bool = true,
    residue: String? = nil
  ) throws -> SetupOwnershipRecord {
    try legacyFileRecord(
      SetupOwnershipManager.integrationID,
      original: original,
      installed: original + "\(includeDirective)\n",
      onDisk: onDisk,
      phase: phase,
      backupPresent: backupPresent,
      residue: residue
    )
  }

  /// The four bat and eza seams an older release owned, with the selectors appended.
  func legacyBatEza(bat: String, shell: String) throws -> [SetupOwnershipRecord] {
    [
      try legacyFileRecord(
        SetupOwnershipManager.batSelectorID,
        original: bat, installed: bat + "\(batDirective)\n"),
      try legacyThemeLink(SetupOwnershipManager.batThemeLinkID),
      try legacyFileRecord(
        SetupOwnershipManager.ezaEnvironmentID,
        original: shell, installed: shell + "\(ezaDirective)\n"),
      try legacyThemeLink(SetupOwnershipManager.ezaThemeLinkID),
    ]
  }
}
