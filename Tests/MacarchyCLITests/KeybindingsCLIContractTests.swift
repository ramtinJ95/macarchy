import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI

struct KeybindingsCLIContractTests {
  @Test
  func productionCLISeparatesLegacyV1SourcesFromExplicitEffectiveV2Inspection() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybindings-cli-contract-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = root.appending(path: "external.skhdrc")
    let catalog = root.appending(path: "external-metadata.toml")
    let profile = root.appending(path: "profile.toml")
    let stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
    try "alt - j : externally managed command\n".write(
      to: configuration,
      atomically: true,
      encoding: .utf8
    )
    try """
    schema_version = 1
    [[bindings]]
    identity = "alt-j"
    label = "External binding"
    category = "External"
    order = 1
    """.write(to: catalog, atomically: true, encoding: .utf8)
    try "schema_version = 1\n[keybindings]\n".write(
      to: profile,
      atomically: true,
      encoding: .utf8
    )

    let legacyList = try run([
      "keybindings", "list", "--skhd-config", configuration.path,
      "--catalog", catalog.path, "--json",
    ])
    let legacyDoctor = try run([
      "keybindings", "doctor", "--skhd-config", configuration.path,
      "--catalog", catalog.path, "--json",
    ])
    let effectiveList = try run([
      "keybindings", "list", "--effective", "--profile", profile.path,
      "--state-root", stateRoot.path, "--json",
    ])
    let effectiveDoctor = try run([
      "keybindings", "doctor", "--effective", "--profile", profile.path,
      "--state-root", stateRoot.path, "--json",
    ])
    let effectiveStatus = try run([
      "keybindings", "status", "--profile", profile.path,
      "--state-root", stateRoot.path, "--json",
    ])

    let legacyListJSON = try json(legacyList.output)
    let legacyDoctorJSON = try json(legacyDoctor.output)
    let effectiveListJSON = try json(effectiveList.output)
    let effectiveDoctorJSON = try json(effectiveDoctor.output)
    let effectiveStatusJSON = try json(effectiveStatus.output)

    #expect(legacyList.status == 0)
    #expect(legacyDoctor.status == 0)
    #expect(legacyListJSON["schema_version"] as? Int == 1)
    #expect(legacyListJSON["source"] as? String == configuration.path)
    #expect(legacyListJSON["operation"] == nil)
    #expect(legacyDoctorJSON["schema_version"] as? Int == 1)
    #expect(legacyDoctorJSON["operation"] as? String == "keybindings_doctor")

    #expect(effectiveList.status == 0)
    #expect(effectiveDoctor.status == 0)
    #expect(effectiveStatus.status != 0)
    #expect(effectiveListJSON["schema_version"] as? Int == 2)
    #expect(effectiveListJSON["operation"] as? String == "keybindings_list_effective")
    #expect(effectiveListJSON["source"] == nil)
    #expect(effectiveDoctorJSON["schema_version"] as? Int == 2)
    #expect(effectiveDoctorJSON["operation"] as? String == "keybindings_doctor_effective")
    #expect(effectiveStatusJSON["schema_version"] as? Int == 1)
    #expect(effectiveStatusJSON["operation"] as? String == "keybindings_status")
    #expect(effectiveStatusJSON["outcome"] as? String != nil)
  }

  @Test
  func productionCLIRejectsMixedLegacyAndEffectiveSources() throws {
    let execution = try run([
      "keybindings", "list", "--effective", "--skhd-config", "/tmp/external.skhdrc",
    ])

    #expect(execution.status != 0)
    #expect(execution.error.contains("cannot be used with --effective"))
  }

  @Test(arguments: ["list", "doctor"])
  func productionCLIRejectsSourceStateRootForNonPopupCommands(_ command: String) throws {
    let execution = try run([
      "keybindings", command, "--state-root", "/tmp/macarchy-state",
    ])

    #expect(execution.status != 0)
    #expect(execution.error.contains("--state-root requires --effective"))
  }

  @Test
  func parserRetainsSourceStateRootForShowThemeSelection() throws {
    let stateRoot = "/tmp/macarchy-popup-theme-state"

    let command = try Keybindings.Show.parse(["--state-root", stateRoot])

    #expect(!command.inspection.effective)
    #expect(command.inspection.stateRoot == stateRoot)
  }

  private func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
    let isolatedHome = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-keybindings-cli-home-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: isolatedHome) }
    let process = Process()
    process.executableURL = productDirectory.appending(path: "macarchy")
    process.arguments = arguments
    process.currentDirectoryURL = repositoryRoot
    process.environment = ProcessInfo.processInfo.environment.merging([
      "CFFIXED_USER_HOME": isolatedHome.path,
      "HOME": isolatedHome.path,
      "MACARCHY_DISABLE_UPDATE_CHECKS": "1",
      "XDG_CONFIG_HOME": isolatedHome.appending(path: ".config").path,
    ]) { _, isolated in isolated }
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let output = String(
      decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let error = String(
      decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return (process.terminationStatus, output, error)
  }

  private func json(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var productDirectory: URL {
    Bundle(for: KeybindingsCLIContractBundleToken.self).bundleURL.deletingLastPathComponent()
  }
}

private final class KeybindingsCLIContractBundleToken: NSObject {}
