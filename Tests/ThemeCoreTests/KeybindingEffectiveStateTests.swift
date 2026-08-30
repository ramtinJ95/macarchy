import Foundation
import Testing

@testable import ThemeCore

struct KeybindingEffectiveStateTests {
  @Test
  func absentDefaultProfileInheritsEveryPackagedBindingAndMetadataRecord() throws {
    let fixture = try EffectiveStateFixture()
    defer { fixture.remove() }

    let state = fixture.inspect(profileRequired: false)

    #expect(!state.configuration.isBlocked)
    #expect(state.configuration.sources.profileStatus == "absent_default")
    #expect(state.attributedBindings.map(\.binding.identity) == ["alt-j", "alt-k"])
    #expect(state.attributedBindings.allSatisfy { $0.commandSource == .packagedDefault })
    #expect(state.attributedBindings.allSatisfy { $0.metadataSource == .packagedDefault })
    #expect(state.disabledDefaults.isEmpty)
  }

  @Test
  func attributesPackagedReplacementAdditionAndDisableFromOneReadOnlyLoad() throws {
    let fixture = try EffectiveStateFixture()
    defer { fixture.remove() }
    try fixture.writeProfile(
      disabled: ["alt-k"],
      override: "alt - j : personal south\ncmd - x : personal command\n"
    )

    let state = fixture.inspect(profileRequired: true)

    #expect(!state.configuration.isBlocked)
    #expect(state.generationAgreement == .missing)
    #expect(state.attributedBindings.map(\.binding.identity) == ["alt-j", "cmd-x"])
    #expect(
      state.attributedBindings.map(\.commandSource) == [.userReplacement, .userAddition]
    )
    #expect(
      state.attributedBindings.map(\.metadataSource) == [.packagedDefault, nil]
    )
    #expect(state.disabledDefaults.map(\.binding.identity) == ["alt-k"])
  }

  @Test
  func comparesBothValidatedInputAndRenderedDigestsWithCanonicalGeneration() throws {
    let fixture = try EffectiveStateFixture()
    defer { fixture.remove() }
    let initial = fixture.inspect(profileRequired: false)
    let composition = try #require(initial.configuration.composition)
    let generation = try fixture.publish(
      configuration: try #require(composition.renderedConfiguration),
      inputDigest: try #require(composition.inputDigest),
      renderedDigest: try #require(composition.renderedDigest)
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: generation.path)
    }

    #expect(fixture.inspect(profileRequired: false).generationAgreement == .matches)

    try fixture.writeProfile(disabled: ["alt-k"], override: nil)
    let changed = fixture.inspect(profileRequired: true)
    #expect(changed.generation.status == .current)
    #expect(changed.generationAgreement == .differs)
    #expect(changed.disabledDefaults.map(\.binding.identity) == ["alt-k"])
  }

  @Test
  func blockedPortableInputDoesNotLaunderGenerationStateIntoAgreement() throws {
    let fixture = try EffectiveStateFixture()
    defer { fixture.remove() }
    try fixture.writeProfile(disabled: ["cmd-z"], override: nil)

    let state = fixture.inspect(profileRequired: true)

    #expect(state.configuration.isBlocked)
    #expect(state.generationAgreement == .unavailable)
    #expect(
      state.configuration.diagnostics.map(\.code) == ["unknown_disabled_identity"]
    )
  }

  @Test
  func invalidNativeOverridePreservesExactSourceAndLineDiagnostics() throws {
    let fixture = try EffectiveStateFixture()
    defer { fixture.remove() }
    try fixture.writeProfile(
      disabled: [],
      override: "unsupported enabled input\nstill unsupported\n"
    )

    let state = fixture.inspect(profileRequired: true)

    #expect(state.configuration.isBlocked)
    #expect(state.generationAgreement == .unavailable)
    #expect(
      state.configuration.diagnostics.map(\.code) == [
        "unsupported_syntax", "unsupported_syntax",
      ])
    #expect(state.configuration.diagnostics.map(\.line) == [1, 2])
    #expect(
      state.configuration.diagnostics.allSatisfy {
        $0.source.hasSuffix("/profile/personal.skhdrc")
      }
    )
  }
}

private struct EffectiveStateFixture {
  let root: URL
  let resources: URL
  let profile: URL
  let stateRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-effective-state-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    resources = root.appending(path: "resources", directoryHint: .isDirectory)
    profile = root.appending(path: "profile/profile.toml")
    stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: profile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "alt - j : default south\nalt - k : default north\n".write(
      to: resources.appending(path: "defaults.skhdrc"),
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1

    [[bindings]]
    identity = "alt-j"
    label = "Focus south"
    category = "Windows"
    order = 1

    [[bindings]]
    identity = "alt-k"
    label = "Focus north"
    category = "Windows"
    order = 2
    """.write(
      to: resources.appending(path: "metadata.toml"),
      atomically: true,
      encoding: .utf8
    )
  }

  func inspect(profileRequired: Bool) -> KeybindingEffectiveState {
    KeybindingEffectiveStateInspector().inspect(
      resourcesRoot: resources,
      profileURL: profile,
      profileRequired: profileRequired,
      stateRoot: stateRoot
    )
  }

  func writeProfile(disabled: [String], override: String?) throws {
    var text = "schema_version = 1\n[keybindings]\n"
    if let override {
      text += "override = \"personal.skhdrc\"\n"
      try override.write(
        to: profile.deletingLastPathComponent().appending(path: "personal.skhdrc"),
        atomically: true,
        encoding: .utf8
      )
    }
    text += "disabled = [\(disabled.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
    try text.write(to: profile, atomically: true, encoding: .utf8)
  }

  func publish(
    configuration: String,
    inputDigest: String,
    renderedDigest: String
  ) throws -> URL {
    let generationID = "k-01234567-89ab-cdef-0123-456789abcdef"
    let keybindings = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let generation = keybindings.appending(
      path: "generations/\(generationID)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(
      KeybindingGenerationManifest(
        generationID: generationID,
        inputDigest: inputDigest,
        renderedDigest: renderedDigest
      )
    ).write(to: generation.appending(path: "manifest.json"))
    try Data(configuration.utf8).write(to: generation.appending(path: "skhdrc"))
    for file in ["manifest.json", "skhdrc"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: generation.appending(path: file).path
      )
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: generation.path)
    try FileManager.default.createSymbolicLink(
      atPath: keybindings.appending(path: "current").path,
      withDestinationPath: "generations/\(generationID)"
    )
    return generation
  }

  func remove() {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: stateRoot.appending(
        path: "keybindings/generations/k-01234567-89ab-cdef-0123-456789abcdef"
      ).path
    )
    try? FileManager.default.removeItem(at: root)
  }
}
