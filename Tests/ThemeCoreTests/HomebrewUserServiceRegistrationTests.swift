import Darwin
import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct HomebrewUserServiceRegistrationTests {
  @Test(
    arguments: ["borders", "sketchybar"],
    ["absent", "legacy", "current", "both-files", "both-jobs", "mixed", "error", "dangling"])
  func resolvesOnlyAnUnambiguousNativeRegistration(providerName: String, condition: String) throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "brew-labels-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let agents = home.appending(path: "Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let provider = try #require(HomebrewUserServiceRegistration.Provider(rawValue: providerName))
    let labels = provider.labels
    if ["legacy", "both-files", "mixed", "dangling"].contains(condition) {
      // A dangling symlink is still an incumbent registration, never absence.
      try FileManager.default.createSymbolicLink(
        at: agents.appending(path: "\(labels[0]).plist"),
        withDestinationURL: home.appending(path: "missing"))
    }
    if ["current", "both-files"].contains(condition) {
      try Data().write(to: agents.appending(path: "\(labels[1]).plist"))
    }
    let calls = Mutex<[ProcessRequest]>([])
    let runner = ProcessRunner { request in
      calls.withLock { $0.append(request) }
      let loaded =
        condition == "both-jobs"
        || (condition == "mixed" && request.arguments.last == "gui/\(getuid())/\(labels[1])")
      return ProcessResult(
        terminationStatus: condition == "error" ? 5 : loaded ? 0 : 113, output: "job")
    }
    if ["both-files", "both-jobs", "mixed", "error"].contains(condition) {
      #expect(throws: HomebrewUserServiceRegistration.InspectionError.self) {
        try HomebrewUserServiceRegistration.inspect(provider: provider, home: home, runner: runner)
      }
    } else {
      let found = try HomebrewUserServiceRegistration.inspect(
        provider: provider, home: home, runner: runner)
      #expect(
        found?.label
          == (condition == "absent" ? nil : condition == "current" ? labels[1] : labels[0]))
    }
    #expect(
      calls.withLock { requests in
        requests.allSatisfy { request in
          request.executableURL.path == "/bin/launchctl"
            && labels.contains { request.arguments == ["print", "gui/\(getuid())/\($0)"] }
        }
      })
  }
}
