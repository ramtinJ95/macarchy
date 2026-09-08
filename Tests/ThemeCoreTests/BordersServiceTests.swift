import Darwin
import Foundation
import Synchronization
import Testing

@testable import ThemeCore

struct BordersServiceTests {
  @Test
  func stoppedInspectionIsInertAndRejectsDormantRegistration() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = Mutex<[ProcessRequest]>([])
    let service = BordersService(
      homeDirectory: root,
      runner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        if request.executableURL.path == "/usr/bin/pgrep" {
          return ProcessResult(terminationStatus: 1, output: "")
        }
        #expect(request.executableURL.path == "/bin/launchctl")
        return ProcessResult(terminationStatus: 113, output: "")
      })
    #expect(try service.inspect() == .stopped)
    let agents = root.appending(path: "Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try Data("external dormant registration".utf8).write(
      to: agents.appending(path: "\(BordersService.label).plist"))
    #expect(throws: (any Error).self) { try service.inspect() }
    #expect(requests.withLock { $0.count } == 6)
  }

  @Test
  func loadedJobRequiresExactExecutableArgumentsAndPID() {
    let executable = BordersService.serviceExecutableURL.path
    let output = """
      path = /fixture/borders.plist
      state = running
      program = \(executable)
      pid = 123
      arguments = {
        \(executable)
      }
      """
    #expect(
      BordersService.loadedServiceMatches(
        output, propertyListPath: "/fixture/borders.plist", processID: 123))
    #expect(
      !BordersService.loadedServiceMatches(
        output, propertyListPath: "/fixture/borders.plist", processID: 124))
    #expect(
      !BordersService.loadedServiceMatches(
        output.replacingOccurrences(of: "\n}", with: "\n ax_focus=on\n}"),
        propertyListPath: "/fixture/borders.plist", processID: 123))
  }

  @Test(
    arguments: HomebrewUserServiceRegistration.Provider.borders.labels,
    [
      "supported", "custom-job", "request-rejected", "pid-change",
      "dormant", "exited", "dormant-custom", "exited-custom",
    ])
  func nativeRequestsRequireExactSupportedServiceIdentity(label: String, condition: String) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plist = root.appending(path: "Library/LaunchAgents/\(label).plist")
    try FileManager.default.createDirectory(
      at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    var fields: [String: Any] = [
      "Label": label,
      "ProgramArguments": [BordersService.serviceExecutableURL.path],
      "KeepAlive": true, "RunAtLoad": true, "ProcessType": "Interactive",
      "StandardOutPath": "/opt/homebrew/var/log/borders/borders.out.log",
      "StandardErrorPath": "/opt/homebrew/var/log/borders/borders.err.log",
      "LimitLoadToSessionType": ["Aqua", "Background", "LoginWindow", "StandardIO", "System"],
      "EnvironmentVariables": [
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
      ],
    ]
    if condition.contains("custom") { fields["WorkingDirectory"] = "/external/custom" }
    try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(
      to: plist)
    let requests = Mutex<[ProcessRequest]>([])
    let job = """
      path = \(plist.path)
      state = running
      program = \(BordersService.serviceExecutableURL.path)
      pid = 123
      arguments = {
        \(BordersService.serviceExecutableURL.path)
      }
      """
    let service = BordersService(
      homeDirectory: root,
      runner: ProcessRunner { request in
        let count = requests.withLock { values in
          values.append(request)
          return values.count
        }
        if request.executableURL.path == "/usr/bin/pgrep" {
          if condition.hasPrefix("dormant") || condition.hasPrefix("exited") {
            return ProcessResult(terminationStatus: 1, output: "")
          }
          return ProcessResult(
            terminationStatus: 0, output: condition == "pid-change" && count > 4 ? "124" : "123")
        }
        if request.executableURL.path == "/bin/launchctl" {
          if request.arguments.last != "gui/\(getuid())/\(label)" {
            return ProcessResult(terminationStatus: 113, output: "")
          }
          if condition.hasPrefix("dormant") {
            return ProcessResult(terminationStatus: 113, output: "")
          }
          if condition.hasPrefix("exited") {
            return ProcessResult(
              terminationStatus: 0,
              output:
                job
                .replacingOccurrences(of: "state = running", with: "state = waiting")
                .replacingOccurrences(of: "pid = 123\n", with: ""))
          }
          return ProcessResult(terminationStatus: 0, output: job)
        }
        #expect(request.executableURL == BordersService.executableURL)
        #expect(
          request.arguments
            == BordersPalette(generationID: "fixture", themeID: "fixture", accent: "#abcdef")
            .arguments)
        return ProcessResult(
          terminationStatus: condition == "request-rejected" ? 1 : 0, output: "fixture response")
      }, processPath: { _ in BordersService.serviceExecutableURL.resolvingSymlinksInPath().path })
    let palette = BordersPalette(generationID: "fixture", themeID: "fixture", accent: "#abcdef")
    if condition.hasPrefix("dormant") || condition.hasPrefix("exited") {
      #expect(throws: (any Error).self) { try service.inspect() }
      if condition.contains("custom") {
        #expect(throws: (any Error).self) {
          try service.inspect(allowInterruptedRegistration: true)
        }
      } else {
        let recovery = try service.inspect(allowInterruptedRegistration: true)
        #expect(!recovery.isRunning && recovery.isRegistered && recovery.hasValidShape)
      }
      return
    }
    if condition == "supported" {
      #expect(try service.request(palette).contains("no readback"))
    } else {
      #expect(throws: (any Error).self) { try service.request(palette) }
    }
    if condition == "custom-job" {
      #expect(
        requests.withLock { $0.allSatisfy { $0.executableURL != BordersService.executableURL } })
    }
  }

  @Test
  func installedProviderCompatibilityRejectsUnsupportedVersionAndUnsafeHome() throws {
    let requests = Mutex<[ProcessRequest]>([])
    for (version, home) in [
      ("borders-v1.8.0", "/tmp/safe"), ("borders-v1.9.0", "/tmp/unsafe home"),
    ] {
      let service = BordersService(
        homeDirectory: URL(filePath: home),
        runner: ProcessRunner { request in
          requests.withLock { $0.append(request) }
          return ProcessResult(terminationStatus: 0, output: version)
        })
      #expect(throws: (any Error).self) { try service.preflight() }
    }
    #expect(requests.withLock { $0.allSatisfy { $0.arguments == ["--version"] } })
  }

  @Test
  func failedHomebrewStartDoesNotGrantTrustOrFallBackToLaunchctl() {
    let requests = Mutex<[ProcessRequest]>([])
    let service = BordersService(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      runner: ProcessRunner { request in
        requests.withLock { $0.append(request) }
        return ProcessResult(terminationStatus: 1, output: "Formula is not trusted")
      })
    #expect(throws: (any Error).self) { try service.start() }
    #expect(requests.withLock { $0.count } == 1)
    #expect(requests.withLock { $0.first?.executableURL.path } == "/opt/homebrew/bin/brew")
    #expect(
      requests.withLock { $0.first?.arguments } == ["services", "start", BordersService.formula])
  }

  @Test
  func alternateHomeCannotMutateTheRealUsersService() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Mutex(0)
    let service = BordersService(
      homeDirectory: root,
      runner: ProcessRunner { _ in
        calls.withLock { $0 += 1 }
        return ProcessResult(terminationStatus: 0, output: "")
      })
    #expect(throws: (any Error).self) { try service.start() }
    #expect(calls.withLock { $0 } == 0)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "borders-service-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
