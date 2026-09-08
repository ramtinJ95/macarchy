import AppKit
import ArgumentParser
import Foundation

struct Desktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Plan and manage the default desktop providers.",
    subcommands: [
      Plan.self, Apply.self, Status.self, Doctor.self, Teardown.self, RunSketchyBarHook.self,
      Borders.self, CPULoad.self, WiFi.self, AudioOutputCommand.self, AudioPicker.self,
      Calendar.self, Media.self, Toggle.self,
    ]
  )

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Plan managed desktop provider configuration without making changes."
    )

    @OptionGroup var profileOptions: PortableProfileOptions

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution = try DesktopPlanCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profileOptions.isRequired,
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: home,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Publish, activate, and verify managed desktop providers."
    )

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Option(help: "Exact yabai adoption evidence digest from the reviewed desktop plan.")
    var adopt: String?

    @Option(help: "Exact skhd adoption evidence digest from the reviewed desktop plan.")
    var keybindingsAdopt: String?

    @Option(help: "Exact SketchyBar adoption evidence digest from the reviewed desktop plan.")
    var sketchybarAdopt: String?

    @Flag(help: "Inspect the aggregate desktop outcome without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution =
        if dryRun {
          try DesktopPlanCommandRunner.live.execute(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profileOptions.isRequired,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            json: json
          )
        } else {
          try await DesktopApplyCommandRunner.live.executeAggregate(
            resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
            profileURL: profileURL,
            profileRequired: profileOptions.isRequired,
            stateRoot: state.stateRootURL,
            homeDirectory: home,
            consumerPaths: state.consumerPaths,
            adopt: adopt,
            keybindingsAdopt: keybindingsAdopt,
            sketchyBarAdopt: sketchybarAdopt,
            json: json
          )
        }
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report managed desktop generation, ownership, and runtime state."
    )

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution = try DesktopStatusCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profileOptions.isRequired,
        stateRoot: state.stateRootURL,
        homeDirectory: home,
        json: json,
        consumerPaths: state.consumerPaths
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restore the exact desktop provider entries adopted by Macarchy."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Preview restoration without mutation.")
    var dryRun = false

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DesktopTeardownCommandRunner.live.executeAggregate(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        dryRun: dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose aggregate desktop prerequisites, providers, runtime, and theme state."
    )

    @OptionGroup var profileOptions: PortableProfileOptions

    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let profileURL = profileOptions.url(homeDirectory: home)
      let execution = try DesktopDoctorCommandRunner.live.execute(
        resourcesRoot: RuntimeEnvironment.live.builtInDesktopURL,
        profileURL: profileURL,
        profileRequired: profileOptions.isRequired,
        stateRoot: state.stateRootURL,
        homeDirectory: home,
        consumerPaths: state.consumerPaths,
        json: json
      )
      print(execution.output)
      if !execution.succeeded { throw ExitCode.failure }
    }
  }

  struct WiFi: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_wifi", shouldDisplay: false)
    @Option var name: String
    @Option var sender: String = "routine"
    @Option var textColor: String
    @Option var accentColor: String
    @Option var mutedColor: String
    @Option var errorColor: String

    mutating func run() throws {
      let runner = SketchyBarWiFi(
        processRunner: .live, read: WiFiState.read,
        sleep: { Thread.sleep(forTimeInterval: $0) },
        uptime: { ProcessInfo.processInfo.systemUptime },
        copy: { value in
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          guard pasteboard.setString(value, forType: .string) else {
            throw WiFiError.queryFailed("cannot write clipboard")
          }
        })
      try runner.execute(
        name: name, sender: sender,
        colors: .init(text: textColor, accent: accentColor, muted: mutedColor, error: errorColor))
    }
  }

  struct AudioOutputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_audio-output", shouldDisplay: false)
    @Option var id: UInt32?
    @Option var identity: String?

    mutating func validate() throws {
      guard (id == nil) == (identity == nil) else {
        throw ValidationError("Audio output selection requires both --id and --identity.")
      }
      if let identity {
        guard identity.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
          throw ValidationError("Audio output identity must be a SHA-256 digest.")
        }
      }
    }

    mutating func run() throws {
      if let id, let identity { try AudioOutputs.select(id: id, identity: identity) }
      let data = try JSONEncoder().encode(AudioOutputs.read())
      print(String(decoding: data, as: UTF8.self))
    }
  }

  struct CPULoad: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_cpu-load", shouldDisplay: false)

    mutating func run() throws {
      let previous = try CPUTicks.read()
      Thread.sleep(forTimeInterval: 1)
      print(try CPUTicks.read().utilization(since: previous))
    }
  }

  struct RunSketchyBarHook: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "_run-sketchybar-hook",
      shouldDisplay: false
    )

    @Argument var hook: String

    mutating func run() throws {
      try SketchyBarHookRunner().execute(URL(filePath: hook).standardizedFileURL)
    }
  }
}
