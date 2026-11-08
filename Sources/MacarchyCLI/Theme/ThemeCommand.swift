import AppKit
import ArgumentParser
import Foundation
import ThemeCore

struct Theme: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect or select themes.",
    subcommands: [
      List.self, Set.self, Install.self, Next.self, Undo.self, Status.self, Get.self,
      Background.self, Browse.self, Screensaver.self,
    ]
  )
}

extension Theme {
  struct Screensaver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Prepare or select a per-theme Photos screensaver image without changing the wallpaper or macOS settings."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = StateLayout.defaultRootPath

    @OptionGroup var roots: ThemeRootOptions

    @Option(help: "Theme whose screensaver choice is saved. Defaults to the active theme.")
    var theme: String?

    @Option(
      help: "Validated background identifier to use independently as this theme's screensaver.")
    var background: String?

    @Flag(help: "Clear this theme's independent selection and follow its wallpaper again.")
    var followWallpaper = false

    mutating func validate() throws {
      if background != nil && followWallpaper {
        throw ValidationError("--background and --follow-wallpaper are mutually exclusive")
      }
      if theme != nil && background == nil && !followWallpaper {
        throw ValidationError("--theme requires --background or --follow-wallpaper")
      }
    }

    mutating func run() async throws {
      let root = URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      print(
        try await ThemeScreenSaverCommandRunner().execute(
          repository: roots.repository(userRoot: root.appending(path: "themes")),
          stateRoot: root, themeID: theme, backgroundID: background,
          followWallpaper: followWallpaper))
    }
  }

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
        stateRoot: StateLayout.defaultRoot(
          in: FileManager.default.homeDirectoryForCurrentUser, directoryHint: .isDirectory)
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
      roots.repository(userRoot: StateLayout(root: stateRootURL).userThemes)
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
      let execution = try await ThemeActivationService.live.execute(
        repository: options.repository,
        themeID: themeID,
        stateRoot: options.stateRootURL,
        consumerPaths: options.consumerPaths,
        dryRun: options.dryRun,
        json: json
      )
      try emitExecution(execution)
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
      try emitExecution(execution)
    }
  }

  struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Return to the theme and background that were active before the last change.",
      discussion: """
        Each committed theme or background change is recorded in the theme history. Undo
        activates the newest earlier selection and drops the undone entries; there is no redo.
        """
    )

    @OptionGroup var options: ActivationOptions

    @Flag(help: .hidden)
    var alertOnError = false

    @MainActor
    mutating func run() async throws {
      let execution: ThemeUndoExecution
      do {
        execution = try await ThemeUndoCommandRunner.live.execute(
          repository: options.repository,
          stateRoot: options.stateRootURL,
          consumerPaths: options.consumerPaths,
          dryRun: options.dryRun
        )
      } catch {
        if alertOnError {
          showNativeAlert(title: "Theme not undone", message: String(describing: error))
        }
        throw error
      }
      if alertOnError {
        if !execution.succeeded {
          showNativeAlert(title: "Theme undo did not complete", message: execution.output)
        } else if let notice = execution.notice {
          showNativeAlert(title: "Theme undone", message: notice, style: .informational)
        }
      }
      try emitExecution(execution.command)
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the canonical theme and its reconciliation state."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = StateLayout.defaultRootPath

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try ThemeStatusCommandRunner.live.execute(
        stateRoot: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL,
        json: json
      )
      try emitExecution(execution)
    }
  }

  struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the active theme's manual-import payload for an application."
    )

    @Option(help: "Canonical Macarchy state directory.")
    var stateRoot = StateLayout.defaultRootPath

    @Argument(help: "Manual-import target identifier, such as 'slack'.")
    var target: String

    mutating func run() throws {
      let output = try ManualThemePayloadStore(
        root: URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
      ).payload(targetID: target)
      print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
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
      let repository = roots.repository(userRoot: StateLayout(root: stateRoot).userThemes)
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
        try emitExecution(execution)
        return
      }
      let content = try await ThemePackageLock(root: stateRoot).withLock {
        try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: stateRoot)
      }
      let launcher = ThemeBrowserApplyProcessLauncher.live
      try await MainActor.run {
        let controller = try ThemeBrowserWindowController(
          content: content,
          saveScreenSaverSelection: { selection in
            try await ThemeScreenSaverCommandRunner().execute(
              repository: repository, stateRoot: stateRoot,
              themeID: selection.themeID, backgroundID: selection.backgroundID,
              followWallpaper: selection.backgroundID == nil)
          },
          deleteSelection: { target in
            await ThemeBrowserDeletionRunner.live.execute(
              target: target, repository: repository, stateRoot: stateRoot
            )
          },
          reloadContent: {
            try await ThemePackageLock(root: stateRoot).withLock {
              try ThemeBrowserCommandLoader.live.load(repository: repository, stateRoot: stateRoot)
            }
          }
        ) { selection in
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
      var stateRoot = StateLayout.defaultRootPath

      @Argument(help: "Theme package identifier.")
      var themeID: String

      mutating func run() throws {
        let root = URL(filePath: stateRoot, directoryHint: .isDirectory).standardizedFileURL
        let package = try MacarchyConfigurationStore(root: root).addingPersonalBackgrounds(
          to: roots.repository(userRoot: StateLayout(root: root).userThemes).package(id: themeID)
        )
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
      var stateRoot = StateLayout.defaultRootPath

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
        try emitExecution(execution)
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
        try emitExecution(execution)
      }
    }
  }
}
