import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct EnvironmentConfigurationSourceTests {
  @Test(arguments: EnvironmentNativeSeed.Provider.allCases)
  func resolvesExplicitUserLinksWithoutParsingOrCopyingBehavior(
    provider: EnvironmentNativeSeed.Provider
  ) throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let real = fixture.root.appending(path: "user-source")
    let alias = fixture.root.appending(path: "source-link")
    if provider == .neovim {
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    } else {
      try "deliberately invalid native syntax, editable for repair\n".write(
        to: real, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n[\(provider.rawValue)]\n\(provider.profileKey) = \"source-link\"\n",
      source: fixture.root.appending(path: "profile.toml"))
    let result = EnvironmentConfigurationSourceResolver(
      homeDirectory: fixture.home, stateRoot: fixture.state
    ).resolve(provider, profile: profile)
    #expect(result.status == .editable, "\(result.message)")
    #expect(result.authority == "native_profile")
    #expect(result.source == alias.path)
    #expect(result.resolvedSource == real.path)
    #expect(result.kind == (provider == .neovim ? "directory" : "file"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == real.path)
    #expect(try EnvironmentStateStore(stateRoot: fixture.state).readOwnership() == nil)
  }

  @Test(arguments: EnvironmentNativeSeed.Provider.allCases)
  func defaultConfigurationDoesNotGuessFromPublicEntries(provider: EnvironmentNativeSeed.Provider)
    throws
  {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = EnvironmentConfigurationSourceResolver(
      homeDirectory: fixture.home, stateRoot: fixture.state
    ).resolve(provider, profile: .defaults)
    #expect(result.status == .nativeSetupRequired)
    #expect(result.source == nil)
    #expect(result.resolvedSource == nil)
  }

  @Test(arguments: ["missing", "state", "public", "disabled", "copied"])
  func distinguishesUnavailableAndLegacyInputs(scenario: String) throws {
    let fixture = try EnvironmentLifecycleFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source: URL
    switch scenario {
    case "state": source = fixture.state.appending(path: "unowned-user-file")
    case "public": source = fixture.home.appending(path: ".zshrc")
    default: source = fixture.root.appending(path: "user.zsh")
    }
    if scenario != "missing" {
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "export PERSONAL=kept\n".write(to: source, atomically: true, encoding: .utf8)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let path = scenario == "copied" ? "user.zsh" : source.path
    let quoted = String(decoding: try encoder.encode(path), as: UTF8.self)
    let declaration =
      scenario == "disabled"
      ? "[shell]\nprovider = \"disabled\"\n"
      : "[zsh]\n\(scenario == "copied" ? "hook" : "configuration") = \(quoted)\n"
    let profile = try PortableProfileLoader().decode(
      "schema_version = 1\n" + declaration, source: fixture.root.appending(path: "profile.toml"))
    let result = EnvironmentConfigurationSourceResolver(
      homeDirectory: fixture.home, stateRoot: fixture.state
    ).resolve(.zsh, profile: profile)
    switch scenario {
    case "missing": #expect(result.status == .missing)
    case "state": #expect(result.status == .blocked)
    case "public":
      #expect(result.status == .editable)
      #expect(result.authority == "native_profile")
      #expect(result.source == source.path)
    case "disabled": #expect(result.status == .disabledInProfile)
    case "copied":
      #expect(result.status == .editable)
      #expect(result.authority == "copied_profile_input")
      #expect(result.source == source.path)
    default: Issue.record("Unknown scenario")
    }
  }

}
