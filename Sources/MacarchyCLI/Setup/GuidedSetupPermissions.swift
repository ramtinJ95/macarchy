import Foundation
import ThemeCore

struct GuidedBarPermissions: Equatable, Sendable {
  let apple: Bool
  let appearance: Bool
}

/// Interaction only; services, configuration and rollback remain with their existing owners.
struct GuidedSetupPermissions: Sendable {
  let io: GuidedSetupIO
  let openPane: @Sendable (String) throws -> Void
  let servicesNeedingGuidance: @Sendable () -> [URL]
  let verifyBar: @Sendable (UnifiedSetupPlanContext) throws -> GuidedBarPermissions
  let requestBarAccessibility: @Sendable (UnifiedSetupPlanContext) throws -> Void
  let verifyAppearance: @Sendable () throws -> Void
  let requestAppearance: @Sendable () throws -> Void
  let appearanceContext: @Sendable () -> String
  let reconcileAppearance:
    @Sendable (UnifiedSetupPlanContext, ThemeConsumerPaths) async throws -> Void

  static func live(io: GuidedSetupIO) -> Self {
    Self(
      io: io,
      openPane: { pane in
        let result = try ProcessRunner.live.run(
          .init(
            executableURL: URL(filePath: "/usr/bin/open"),
            arguments: ["x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane],
            timeout: 3))
        guard result.terminationStatus == 0 else {
          throw SetupPackageAdoptionError(
            "Cannot open Privacy & Security > \(pane): \(result.output)")
        }
      },
      servicesNeedingGuidance: {
        var paths = [URL]()
        if (try? YabaiLifecycleController.live.preflight()) != true {
          paths.append(ExternalTool.yabai)
        }
        if (try? KeybindingLifecycleController.live.preflight()) == nil {
          paths.append(ExternalTool.skhd)
        }
        return paths
      },
      verifyBar: { try verifyBar(context: $0) },
      requestBarAccessibility: { _ = try verifyBar(context: $0, requestAccessibility: true) },
      verifyAppearance: MacOSAppearanceEvents.verify,
      requestAppearance: MacOSAppearanceEvents.requestConsent,
      appearanceContext: { MacOSAppearanceEvents.launchContext },
      reconcileAppearance: { context, paths in
        guard case .current = try ReconciliationStatusStore(root: context.stateRoot).read() else {
          throw SetupPackageAdoptionError(
            "The active reconciliation record is missing or stale; review setup before resuming appearance."
          )
        }
        let coordinator = try ThemeRuntimeSelection.activationCoordinator(
          stateRoot: context.stateRoot, consumerPaths: paths)
        let result = try await coordinator.reconcile(adapterIDs: [MacOSAppearanceAdapter.id])
        guard
          result.record.results.first(where: { $0.adapterID == MacOSAppearanceAdapter.id })?
            .status == .applied
        else {
          throw SetupPackageAdoptionError(
            "Appearance reconciliation remains incomplete; inspect macarchy setup doctor.")
        }
      })
  }

  func beforeConfiguration(context: UnifiedSetupPlanContext, profile: PortableProfile) throws
    -> String?
  {
    guard profile.desktop.provider == .yabaiSkhd else { return nil }
    let paths = servicesNeedingGuidance().map { $0.resolvingSymlinksInPath() }
    guard !paths.isEmpty else { return nil }
    for path in paths {
      guard FileManager.default.isExecutableFile(atPath: path.path) else {
        return "Setup is blocked: the selected service binary is not installed: \(path.path). "
          + "No configuration was applied. Resume: \(Self.resumeCommand(context))."
      }
    }
    io.write("Accessibility — tiling/Space control and desktop keybindings\n")
    for path in paths { io.write("\(path.path)\n") }
    io.write(
      "In Accessibility, use + and Shift-Command-G to select each installed binary above, then enable it. Macarchy never grants access. "
        + "The actual managed service startup verifies access; checking a toggle is not proof. "
        + "On first start macOS may show its own request. Keep an ordinary application window open for yabai's AX check.\n"
    )
    try openPane("Accessibility")
    guard try confirm("Continue with managed service startup and verification?") else {
      return
        "Setup is blocked before configuration. Tiling/keybindings need Accessibility for the binaries above. "
        + "Installed packages and the profile are retained. Resume: \(Self.resumeCommand(context))."
    }
    return nil
  }

  func afterConfiguration(context: UnifiedSetupPlanContext, consumerPaths: ThemeConsumerPaths)
    async throws -> CommandExecution
  {
    let profile = try context.loadProfile().profile
    let selected = try DependencyProfile.personal(homeDirectory: context.homeDirectory)
      .selectedForSetup(
        profile,
        defaultsURL: DesktopDesiredState.sketchyBarDefaultsURL(
          resourcesRoot: context.desktopResourcesRoot))
    var missing = [String]()
    let resume = Self.resumeCommand(context)
    if selected.contains(where: { $0.id == "apple-menu-helper" }) {
      let helper = RuntimeEnvironment.live.executableURL.deletingLastPathComponent()
        .appending(path: AppleMenuHelper.executableName).resolvingSymlinksInPath()
      let bar = ExternalTool.sketchybar.resolvingSymlinksInPath()
      var verified: GuidedBarPermissions?
      do { verified = try verifyBar(context) } catch {
        io.write("SketchyBar permission check could not run: \(error)\n")
      }
      if verified?.apple != true {
        io.write(
          "Accessibility — Apple-menu feature\nSketchyBar service: \(bar.path)\nHelper: \(helper.path)\n"
            + "The helper is checked by the running SketchyBar service, not this terminal. "
            + "Enable the responsible app identified by macOS in Accessibility; the two paths above identify the launch chain, not interchangeable TCC entries.\n"
        )
        try openPane("Accessibility")
        if try confirm(
          "Ask macOS to identify the Accessibility entry for this bar-launched helper?")
        {
          do { try requestBarAccessibility(context) } catch {
            io.write("Native Accessibility request/check: \(error)\n")
          }
        }
        if try confirm(
          "After manually enabling the native entry, recheck the Apple-menu grant from SketchyBar now?"
        ) {
          do { verified = try verifyBar(context) } catch {
            io.write("SketchyBar permission recheck failed: \(error)\n")
          }
        }
      }
      if verified?.apple != true {
        missing.append(
          "Apple menu will not work: Accessibility is not verified for SketchyBar \(bar.path) → \(helper.path)."
        )
      }
      io.write(
        verified?.appearance == true
          ? "System Events read verified in the SketchyBar context (observation only).\n"
          : "System Events read is unverified in the SketchyBar context (observation only). The selected bar actions do not change appearance, so this is not an additional required grant.\n"
      )

    }

    var appearanceVerified = false
    do {
      try verifyAppearance()
      appearanceVerified = true
    } catch {
      io.write(
        "Automation — light/dark appearance\n\(appearanceContext())\nRecipient: \(MacOSAppearanceEvents.applicationURL.path)\n"
          + "This requests native consent and reads appearance only; it does not change appearance. "
          + "The native dialog identifies macOS's responsible application. Permission covers this invocation, not other launchers.\n"
      )
      try openPane("Automation")
      if try confirm("Request macOS System Events Automation consent for this launch context?") {
        do {
          try requestAppearance()
          try verifyAppearance()
          appearanceVerified = true
        } catch { io.write("System Events consent/verification failed: \(error)\n") }
      }
    }
    if appearanceVerified {
      io.write("System Events Automation verified for this invocation: \(appearanceContext()).\n")
      do { try await reconcileAppearance(context, consumerPaths) } catch {
        missing.append("Light/dark appearance reconciliation failed: \(error)")
      }
    } else {
      missing.append(
        "Light/dark appearance will not work in this invocation: \(appearanceContext()). "
          + "Switch a light/dark theme interactively to request consent. After denial, enable System Events for the responsible app in Privacy & Security > Automation."
      )
    }
    if profile.desktop.provider == .yabaiSkhd {
      missing.append(
        "Keybinding-origin light/dark Automation is unverified for "
          + ExternalTool.skhd.resolvingSymlinksInPath().path
          + " → macarchy → System Events. Open the theme browser with the configured keybinding and select a light/dark change to request native consent in that context. A terminal grant is not proof."
      )
    }
    if !missing.isEmpty {
      return (
        "Configuration is applied; permissions are incomplete.\n"
          + missing.map { "- " + $0 }.joined(separator: "\n")
          + "\nResume the checks without reinstalling satisfied packages: \(resume). "
          + (profile.desktop.provider == .yabaiSkhd
            ? "Keybinding-origin Automation must be completed from the actual menu/keybinding; terminal resume cannot verify it."
            : ""),
        false
      )
    }
    return (
      "Configuration and the selected permission checks are complete for this invocation. Other launch contexts are not implied authorized.",
      true
    )
  }

  private func confirm(_ question: String) throws -> Bool {
    do { return try io.confirm(question) } catch GuidedSetupError.inputClosed { return false }
  }

  static func resumeCommand(_ context: UnifiedSetupPlanContext) -> String {
    var command = "macarchy setup guided --resume"
    if context.profileURL.standardizedFileURL
      != StateLayout.defaultProfile(in: context.homeDirectory).standardizedFileURL
    {
      command += " --output-profile " + shellQuote(context.profileURL.path)
    }
    if context.machineProfileRequired {
      command += " --machine-profile " + shellQuote(context.machineProfileURL.path)
    }
    if context.stateRoot.standardizedFileURL
      != StateLayout.defaultRoot(in: context.homeDirectory).standardizedFileURL
    {
      command += " --state-root " + shellQuote(context.stateRoot.path)
    }
    return command
  }

  private static func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Fresh challenge sent through the owned plugin; no terminal helper check stands in for it.
  static func verifyBar(
    context: UnifiedSetupPlanContext, runner: ProcessRunner = .live,
    requestAccessibility: Bool = false,
    generationInspection: (@Sendable () -> SketchyBarGenerationInspection)? = nil,
    serviceInspection: @Sendable () throws -> SketchyBarRuntimeInspection =
      SketchyBarLifecycleController.live.inspect,
    wait: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  ) throws -> GuidedBarPermissions {
    let inspectGeneration =
      generationInspection ?? {
        SketchyBarGenerationInspector(stateRoot: context.stateRoot).inspect()
      }
    let generation = inspectGeneration()
    guard generation.status == .current else { throw SetupPackageAdoptionError(generation.message) }
    let service = try serviceInspection()
    guard service.status == .running else { throw SetupPackageAdoptionError(service.message) }
    func run(_ arguments: [String]) throws -> String {
      let result = try runner.run(
        .init(executableURL: ExternalTool.sketchybar, arguments: arguments, timeout: 2))
      guard result.terminationStatus == 0 else {
        throw SetupPackageAdoptionError("SketchyBar \(arguments): \(result.output)")
      }
      return result.output
    }
    func item(_ name: String) throws -> SketchyBarItemQuery {
      try SketchyBarQueryReply.decode(SketchyBarItemQuery.self, from: run(["--query", name]))
    }
    let apple = try item(SketchyBarContract.appleItem)
    let expected = context.stateRoot.appending(
      path: "\(StateLayout.sketchyBarDirectory)/current/plugins/apple.sh"
    ).path
    guard apple.scripting.script == expected else {
      throw SetupPackageAdoptionError(
        "The active Apple-menu plugin is not the selected managed script: \(expected)")
    }
    let token = UUID().uuidString.lowercased()
    _ = try run(["--set", SketchyBarContract.readyItem, "label=permission:checking:" + token])
    _ = try run([
      "--trigger", "macarchy_permission_check", "MACARCHY_PERMISSION_TOKEN=" + token,
      "MACARCHY_PERMISSION_REQUEST_AX=" + (requestAccessibility ? "1" : "0"),
    ])
    for _ in 0..<30 {
      let marker = try item(SketchyBarContract.readyItem).label.value
      if marker == "permission:granted:" + token || marker == "permission:missing:" + token {
        let current = try item(SketchyBarContract.appleItem)
        guard inspectGeneration().generationID == generation.generationID,
          try serviceInspection() == service
        else {
          throw SetupPackageAdoptionError(
            "SketchyBar changed during the permission check; retry from the actual service.")
        }
        return .init(
          apple: current.label.drawing == "off" && current.label.value.isEmpty,
          appearance: marker == "permission:granted:" + token)
      }
      wait()
    }
    throw SetupPackageAdoptionError(
      "SketchyBar did not complete the actual-context permission check within the bounded 30-attempt check."
    )
  }
}
