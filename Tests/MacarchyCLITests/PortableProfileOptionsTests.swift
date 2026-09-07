import ArgumentParser
import Foundation
import Testing

@testable import MacarchyCLI

struct PortableProfileOptionsTests {
  @Test
  func onlyExplicitProfilesAreRequiredEvenAtTheDefaultPath() throws {
    let home = URL(filePath: "/tmp/profile-options-home")
    let defaultURL = home.appending(path: ".config/macarchy/profile.toml")
    let implicit = try PortableProfileOptions.parse([])
    #expect(!implicit.isRequired)
    #expect(implicit.url(homeDirectory: home) == defaultURL)

    for path in [defaultURL.path, "/tmp/nested/../profile.toml", "relative/profile.toml"] {
      let explicit = try PortableProfileOptions.parse(["--profile", path])
      #expect(explicit.isRequired)
      #expect(explicit.url(homeDirectory: home) == URL(filePath: path).standardizedFileURL)
    }
  }

  @Test(arguments: [
    ["keybindings", "plan"], ["keybindings", "apply"], ["keybindings", "status"],
    ["keybindings", "list", "--effective"], ["keybindings", "doctor", "--effective"],
    ["keybindings", "show", "--effective"],
    ["desktop", "plan"], ["desktop", "apply"], ["desktop", "status"], ["desktop", "doctor"],
    ["environment", "plan"], ["environment", "apply"], ["environment", "status"],
    ["environment", "doctor"],
  ])
  func directCommandsAcceptPortableButNotMachineProfiles(_ arguments: [String]) throws {
    _ = try Macarchy.parseAsRoot(arguments + ["--profile", "/tmp/profile.toml"])
    #expect(throws: (any Error).self) {
      _ = try Macarchy.parseAsRoot(arguments + ["--machine-profile", "/tmp/machine.toml"])
    }
  }

  @Test(arguments: ["list", "doctor", "show"])
  func sourceInspectionStillRejectsPortableProfiles(_ command: String) {
    #expect(throws: (any Error).self) {
      _ = try Macarchy.parseAsRoot(["keybindings", command, "--profile", "/tmp/profile.toml"])
    }
  }

  @Test
  func setupRetainsItsIndependentMachineOverlay() throws {
    let options = try Macarchy.Setup.ProfileOptions.parse([
      "--profile", "/tmp/portable.toml", "--machine-profile", "/tmp/machine.toml",
    ])
    #expect(options.portable.profile == "/tmp/portable.toml")
    #expect(options.portable.isRequired)
    #expect(options.machineProfile == "/tmp/machine.toml")
  }
}
