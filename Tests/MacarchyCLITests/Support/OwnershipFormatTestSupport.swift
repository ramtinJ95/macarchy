import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

/// A temporary home with the default state root for the released ownership-format fixtures
/// under `Tests/Fixtures/OwnershipFormats`. Fixtures spell machine-specific roots and
/// path-derived values as `{{NAME}}` placeholders that `substitutions` resolves. Paths below
/// the roots stay literal so a production path change cannot move the expectation with it.
struct OwnershipFormatFixture {
  let root: URL
  let home: URL
  let stateRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-ownership-formats-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    home = root.appending(path: "home", directoryHint: .isDirectory)
    stateRoot = home.appending(path: ".config/macarchy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
  }

  var setupContext: SetupOwnershipManager.Context {
    SetupOwnershipManager.Context(homeDirectory: home)
  }

  private var substitutions: [String: String] {
    let context = setupContext
    let batThemeDestination = context.stateRoot.path + "/current/generated/bat.tmTheme"
    return [
      "{{HOME}}": context.homeDirectory.path,
      "{{STATE}}": context.stateRoot.path,
      // Released lifecycle evidence must name the resolved Homebrew skhd, which only reads
      // the host's link metadata.
      "{{SKHD_EXECUTABLE}}": KeybindingProcessInspector.supportedExecutablePath,
      "{{BAT_THEME_DIGEST}}": sha256Digest(Data(batThemeDestination.utf8)),
    ]
  }

  /// The fixture's bytes with every placeholder resolved for this home.
  func contents(_ name: String) throws -> Data {
    var text = try fixtureContents("OwnershipFormats/\(name)")
    for (placeholder, value) in substitutions {
      text = text.replacingOccurrences(of: placeholder, with: value)
    }
    #expect(!text.contains("{{"), "unresolved placeholder in \(name)")
    return Data(text.utf8)
  }

  /// Places a fixture, optionally edited, where its store reads it.
  @discardableResult
  func install(
    _ name: String,
    at relativePath: String,
    editing edit: (String) -> String = { $0 }
  ) throws -> URL {
    let url = stateRoot.appending(path: relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let text = edit(String(decoding: try contents(name), as: UTF8.self))
    try Data(text.utf8).write(to: url)
    return url
  }

  /// Removes the installed file so the store's writer recreates it from the decoded value.
  func removeInstalled(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

/// Adds `addition` as a JSON member right after the member line `anchor` (which ends in a comma).
func addingMember(_ addition: String, after anchor: String) -> (String) -> String {
  { text in
    precondition(text.contains(anchor), "fixture does not contain \(anchor)")
    return text.replacingOccurrences(of: anchor, with: "\(anchor)\n  \(addition),")
  }
}

/// The written document has the same JSON keys, nesting and values as the released fixture.
/// Both sides are re-serialized canonically because `NSNumber` equality would equate `true`
/// with `1`.
func expectSameJSON(
  _ written: URL,
  as fixture: Data,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  #expect(
    try canonicalJSON(Data(contentsOf: written)) == canonicalJSON(fixture),
    "\(written.lastPathComponent) no longer matches the released format",
    sourceLocation: sourceLocation
  )
}

private func canonicalJSON(_ data: Data) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
    options: [.sortedKeys, .fragmentsAllowed]
  )
}

/// Released writers keep Foundation's default `\/` escaping unless they opt out.
func writesEscapedSlashes(_ url: URL) throws -> Bool {
  String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\\/")
}

func filePermissions(_ url: URL) throws -> Int? {
  try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}
