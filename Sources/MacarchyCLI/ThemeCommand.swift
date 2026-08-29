import ArgumentParser
import Foundation
import ThemeCore

struct Theme: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect or select themes.",
    subcommands: [
      List.self, Set.self, Install.self, Next.self, Status.self, Background.self, Browse.self,
    ]
  )
}

extension Theme {
  struct ThemeRootOptions: ParsableArguments {
    @Option(help: "Built-in theme package directory.")
    var themesRoot: String?

    func repository(
      userRoot: URL? = nil,
      runtime: RuntimeEnvironment = .live
    ) -> ThemeRepository {
      let builtInRoot =
        themesRoot.map {
          URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL
        } ?? runtime.builtInThemesURL
      return ThemeRepository(
        builtInRoot: builtInRoot,
        userRoot: userRoot
      )
    }
  }

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List valid available themes.")

    @OptionGroup var roots: ThemeRootOptions

    mutating func run() throws {
      for package in try roots.repository().packages() {
        print("\(package.id)\t\(package.appearance.rawValue)\t\(package.displayName)")
      }
      UpdateNoticeRunner.live.run(
        stateRoot: FileManager.default.homeDirectoryForCurrentUser
          .appending(path: ".config/macarchy", directoryHint: .isDirectory)
      )
    }
  }

  struct ActivationOptions: ParsableArguments {
    @OptionGroup var roots: ThemeRootOptions
    @OptionGroup var state: Macarchy.StateOptions

    @Flag(help: "Validate and describe outputs without writing files.")
    var dryRun = false

    var stateRootURL: URL {
      state.stateRootURL
    }

    var consumerPaths: ThemeConsumerPaths {
      state.consumerPaths
    }

    var repository: ThemeRepository {
      roots.repository(
        userRoot: stateRootURL.appending(path: "themes", directoryHint: .isDirectory)
      )
    }
  }

  struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate a theme and reconcile its consumers."
    )

    @OptionGroup var options: ActivationOptions

    @Argument(help: "Theme package identifier.")
    var themeID: String

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() async throws {
      let execution = try await ThemeSetCommandRunner.live.execute(
        repository: options.repository,
        themeID: themeID,
        stateRoot: options.stateRootURL,
        consumerPaths: options.consumerPaths,
        dryRun: options.dryRun,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Next: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate the next available theme."
    )

    @OptionGroup var options: ActivationOptions

    mutating func run() async throws {
      let execution = try await ThemeNextCommandRunner.live.execute(
        repository: options.repository,
        stateRoot: options.stateRootURL,
        consumerPaths: options.consumerPaths,
        dryRun: options.dryRun
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the canonical theme and its reconciliation state."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try ThemeStatusCommandRunner.live.execute(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        json: json
      )
      print(execution.output)
      if !execution.succeeded {
        throw ExitCode.failure
      }
    }
  }

  struct Browse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Browse installed themes, previews, and backgrounds in a native popup."
    )

    @OptionGroup var roots: ThemeRootOptions
    @OptionGroup var state: Macarchy.StateOptions

    mutating func run() async throws {
      let stateRoot = state.stateRootURL
      let repository = roots.repository(
        userRoot: stateRoot.appending(path: "themes", directoryHint: .isDirectory)
      )
      if let request = ThemeBrowserApplyRequest(
        environment: ProcessInfo.processInfo.environment
      ) {
        let execution = try await ThemeBrowserApplyRunner.live.execute(
          repository: repository,
          themeID: request.selection.themeID,
          backgroundID: request.selection.backgroundID,
          stateRoot: stateRoot,
          consumerPaths: state.consumerPaths
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
        return
      }
      let content = try ThemeBrowserCommandLoader.live.load(
        repository: repository,
        stateRoot: stateRoot
      )
      let launcher = ThemeBrowserApplyProcessLauncher.live
      try await MainActor.run {
        let controller = try ThemeBrowserWindowController(content: content) { selection in
          try launcher.launch(selection: selection)
        }
        try controller.run()
      }
    }
  }

  struct Background: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Inspect or select a theme background.",
      subcommands: [List.self, Current.self, Set.self, Next.self]
    )

    struct List: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "List a theme package's validated backgrounds in selection order."
      )

      @OptionGroup var roots: ThemeRootOptions

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      @Argument(help: "Theme package identifier.")
      var themeID: String

      mutating func run() throws {
        let userThemes = URL(filePath: stateRoot, directoryHint: .isDirectory)
          .standardizedFileURL.appending(path: "themes", directoryHint: .isDirectory)
        let package = try roots.repository(userRoot: userThemes).package(id: themeID)
        for background in package.backgrounds {
          print("\(background.id)\t\(background.format.rawValue)\t\(background.path)")
        }
      }
    }

    struct Current: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Show the active generation's canonical background selection."
      )

      @Option(help: "Canonical Macarchy state directory.")
      var stateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/macarchy", directoryHint: .isDirectory).path

      mutating func run() throws {
        print(
          try ThemeBackgroundCommandRunner.live.current(
            stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
          )
        )
      }
    }

    struct Set: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Select a background for the active theme."
      )

      @OptionGroup var options: ActivationOptions

      @Argument(help: "Stable background identifier.")
      var backgroundID: String

      mutating func run() async throws {
        let execution = try await ThemeBackgroundCommandRunner.live.set(
          repository: options.repository,
          backgroundID: backgroundID,
          stateRoot: options.stateRootURL,
          consumerPaths: options.consumerPaths,
          dryRun: options.dryRun
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }

    struct Next: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Select the next background for the active theme and wrap in package order."
      )

      @OptionGroup var options: ActivationOptions

      mutating func run() async throws {
        let execution = try await ThemeBackgroundCommandRunner.live.next(
          repository: options.repository,
          stateRoot: options.stateRootURL,
          consumerPaths: options.consumerPaths,
          dryRun: options.dryRun
        )
        print(execution.output)
        if !execution.succeeded { throw ExitCode.failure }
      }
    }
  }
}
