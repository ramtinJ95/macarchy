import Foundation
import Testing

@testable import MacarchyCLI

/// Residue settlement and refusals of the shared preset transaction, driven through tuicr's
/// document rules. The preset lifecycle suites cover each preset's own document rules.
struct EnvironmentPresetFileTransactionTests {
  @Test
  func applySettlesACompletedReplacementResidue() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.managed.write(to: fixture.target)
    try fixture.original.write(to: fixture.residue)

    try fixture.transaction.transition(
      from: nil, to: fixture.environment, replacementName: fixture.replacementName)

    #expect(try Data(contentsOf: fixture.target) == fixture.managed)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test
  func applyRedoesAnUndoneReplacementResidue() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.original.write(to: fixture.target)
    try fixture.managed.write(to: fixture.residue)

    try fixture.transaction.transition(
      from: nil, to: fixture.environment, replacementName: fixture.replacementName)

    #expect(try Data(contentsOf: fixture.target) == fixture.managed)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test
  func teardownSettlesACompletedRestorationResidue() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.original.write(to: fixture.target)
    try fixture.managed.write(to: fixture.residue)

    try fixture.transaction.transition(
      from: fixture.environment, to: nil, replacementName: fixture.replacementName)

    #expect(try Data(contentsOf: fixture.target) == fixture.original)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test
  func unrecognizedResidueBlocksWithoutTouchingEitherFile() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let foreign = Data("theme = \"foreign\"\n".utf8)
    try fixture.original.write(to: fixture.target)
    try foreign.write(to: fixture.residue)

    expectFailure(.drift("tuicr replacement residue")) {
      try fixture.transaction.transition(
        from: nil, to: fixture.environment, replacementName: fixture.replacementName)
    }
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
    #expect(try Data(contentsOf: fixture.residue) == foreign)
  }

  @Test
  func unrecognizedContentIsDriftAndStaysUntouched() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let foreign = Data("theme = \"foreign\"\n".utf8)
    try foreign.write(to: fixture.target)

    expectFailure(.drift(fixture.target.path)) {
      try fixture.transaction.transition(
        from: nil, to: fixture.environment, replacementName: fixture.replacementName)
    }
    #expect(try Data(contentsOf: fixture.target) == foreign)
    #expect(!FileManager.default.fileExists(atPath: fixture.residue.path))
  }

  @Test
  func changedOwnershipIsRefusedWithoutTouchingTheFile() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.managed.write(to: fixture.target)
    let changed = Fixture.environment(
      tuicr: EnvironmentTuicrOwnership(
        path: fixture.target.path, originalFileExisted: false, originalSelector: nil,
        insertedSeparatorBefore: false))

    expectFailure(.blocked("tuicr ownership changed unexpectedly")) {
      try fixture.transaction.transition(
        from: fixture.environment, to: changed, replacementName: fixture.replacementName)
    }
    #expect(try Data(contentsOf: fixture.target) == fixture.managed)
  }

  private func expectFailure(
    _ expected: EnvironmentLifecycleError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () throws -> Void
  ) {
    do {
      try operation()
      Issue.record("expected \(expected)", sourceLocation: sourceLocation)
    } catch let error as EnvironmentLifecycleError {
      #expect(error.description == expected.description, sourceLocation: sourceLocation)
    } catch {
      Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
    }
  }

  private struct Fixture {
    let root: URL
    let replacementName = ".macarchy-environment-tuicr-test.replacement"
    let original = Data("theme = \"dracula\"\n".utf8)
    let managed: Data
    let environment: EnvironmentOwnership
    var target: URL { root.appending(path: "config.toml") }
    var residue: URL { root.appending(path: replacementName) }
    var transaction: EnvironmentTuicrFileTransaction { .init(homeDirectory: root) }

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "macarchy-preset-transaction-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let target = root.appending(path: "config.toml")
      let ownership = try EnvironmentTuicrDocument.ownership(
        for: String(decoding: original, as: UTF8.self), source: target)
      managed = try EnvironmentTuicrOwnership.managed(from: original, at: target)
      environment = Self.environment(tuicr: ownership)
    }

    static func environment(tuicr: EnvironmentTuicrOwnership) -> EnvironmentOwnership {
      EnvironmentOwnership(
        generationID: "e-00000000-0000-4000-8000-000000000000", records: [],
        createdDirectories: [], originalThemeBridges: [], tuicr: tuicr, tuicrEnabled: true)
    }
  }
}
