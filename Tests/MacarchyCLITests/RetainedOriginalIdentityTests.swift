import ArgumentParser
import Darwin
import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct RetainedOriginalIdentityTests {
  @Test(arguments: ["volume", "inode", "link", "source", "marker", "pending", "generation"])
  func skhdMigrationRefusesDriftWithoutRewritingTheLedger(change: String) throws {
    let fixture = try KeybindingsApplyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.root.appending(path: "original-skhdrc")
    try Data("alt - x : original\n".utf8).write(to: source)
    let entry = fixture.home.appending(path: ".config/skhd/skhdrc")
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: source)
    let lifecycle = LifecycleFixture()
    #expect(
      try fixture.execute(
        runner: fixture.runner(lifecycle: lifecycle.controller),
        adopt: true, json: true
      ).succeeded)
    let manager = SetupOwnershipManager()
    let context = SetupOwnershipManager.Context(homeDirectory: fixture.home)
    var records = try manager.readRecords(context: context)
    let index = try #require(
      records.firstIndex { $0.id == KeybindingProviderInspector.ownershipID })
    records[index].originalVolumeUUID = nil
    try manager.persist(records: records, context: context)
    let migration = RetainedOwnershipMigration(homeDirectory: fixture.home)
    let preview = try migration.execute(provider: .skhd)
    switch change {
    case "volume": records[index].originalVolumeUUID = UUID().uuidString
    case "inode":
      records[index] = try ownershipFixtureReplacing(
        records[index],
        [
          "original_inode": try #require(records[index].originalInode) + 1
        ])
    case "link":
      let retained = try #require(records[index].retainedOriginalPath)
      try FileManager.default.removeItem(atPath: retained)
      try FileManager.default.createSymbolicLink(atPath: retained, withDestinationPath: "changed")
    case "source": try Data("alt - x : changed\n".utf8).write(to: source)
    case "marker":
      #expect(
        removexattr(entry.path, KeybindingProviderTransaction.claimMarkerAttribute, XATTR_NOFOLLOW)
          == 0)
    case "pending":
      try Data("{}".utf8).write(
        to: fixture.stateRoot.appending(path: "keybindings/transaction.json"))
    default:
      try FileManager.default.removeItem(
        at: fixture.stateRoot.appending(path: "keybindings/current"))
    }
    try manager.persist(records: records, context: context)
    let receipt = fixture.stateRoot.appending(path: "state/setup/ownership.json")
    let before = try Data(contentsOf: receipt)
    let calls = lifecycle.calls.withLock { $0 }
    #expect(throws: (any Error).self) {
      try migration.execute(provider: .skhd, approval: preview.evidenceDigest)
    }
    #expect(try Data(contentsOf: receipt) == before)
    #expect(lifecycle.calls.withLock { $0 } == calls)
  }

  @Test
  func identityUsesTheContainingVolumeOfADanglingLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "original")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "missing/target")
    var metadata = stat()
    #expect(lstat(link.path, &metadata) == 0)
    let uuid = try RetainedOriginalIdentity.volumeUUID(at: link, matching: metadata)
    #expect(uuid == (try root.resourceValues(forKeys: [.volumeUUIDStringKey])).volumeUUIDString)
    #expect(
      try RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: uuid, device: UInt64(metadata.st_dev) + 2))
    #expect(
      try !RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: UUID().uuidString, device: UInt64(metadata.st_dev)))
    #expect(
      try !RetainedOriginalIdentity.matches(
        at: link, metadata: metadata,
        volumeUUID: nil, device: UInt64(metadata.st_dev) + 2))
    metadata.st_ino += 1
    #expect(throws: (any Error).self) {
      try RetainedOriginalIdentity.volumeUUID(at: link, matching: metadata)
    }
  }

  @Test
  func migrationCLIRequiresOneExplicitProvider() throws {
    let preview = try Desktop.MigrateOwnership.parse(["sketchybar", "--json"])
    #expect(preview.provider == .sketchybar)
    #expect(preview.approve == nil)
    let approved = try Desktop.MigrateOwnership.parse(["skhd", "--approve", "sha256:reviewed"])
    #expect(approved.approve == "sha256:reviewed")
    #expect(throws: (any Error).self) { try Desktop.MigrateOwnership.parse(["all"]) }
    #expect(throws: (any Error).self) { try Desktop.MigrateOwnership.parse([]) }
  }
}

/// Simulate persisted evidence from another boot without replacing the retained filesystem object.
func ownershipFixtureReplacing<T: Codable>(_ value: T, _ fields: [String: Any]) throws -> T {
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  for (key, replacement) in fields { object[key] = replacement }
  return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
