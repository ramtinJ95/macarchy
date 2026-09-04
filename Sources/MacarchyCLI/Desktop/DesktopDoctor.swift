import Foundation
import ThemeCore

struct DesktopDoctorCommandRunner: Sendable {
  let lifecycle: YabaiLifecycleController
  let sketchyBarLifecycle: SketchyBarLifecycleController
  let sketchyBarCoreRuntime: SketchyBarCoreRuntimeController?
  let keybindings: DesktopKeybindingOrchestrator?
  let prerequisites: DesktopPrerequisiteInspector
  let theme: DesktopThemeController?

  static let live = Self(
    lifecycle: .live,
    sketchyBarLifecycle: .live,
    sketchyBarCoreRuntime: nil,
    keybindings: .live,
    prerequisites: .live,
    theme: .live
  )

  func execute(
    resourcesRoot: URL,
    keybindingsResourcesRoot: URL = RuntimeEnvironment.live.builtInKeybindingsURL,
    profileURL: URL,
    profileRequired: Bool,
    stateRoot: URL,
    homeDirectory: URL,
    consumerPaths: ThemeConsumerPaths,
    json: Bool,
    macarchyExecutableURL: URL = RuntimeEnvironment.live.executableURL,
    profile suppliedProfile: PortableProfile? = nil
  ) throws -> (output: String, succeeded: Bool) {
    let desired: DesktopDesiredState
    do {
      desired = try DesktopDesiredState.load(
        resourcesRoot: resourcesRoot,
        profileURL: profileURL,
        profileRequired: profileRequired,
        stateRoot: stateRoot,
        macarchyExecutableURL: macarchyExecutableURL,
        profile: suppliedProfile
      )
    } catch {
      let report = DoctorReport(
        findings: [
          DoctorFinding(
            id: "desktop.profile",
            status: .failure,
            message: String(describing: error)
          )
        ],
        operation: "desktop_doctor",
        title: "Macarchy desktop doctor"
      )
      return (try report.render(json: json), false)
    }

    var findings = prerequisites.inspect(desired.profile, homeDirectory).map {
      DoctorFinding(
        id: "desktop.prerequisite.\($0.id)",
        status: $0.status == .present ? .ok : .failure,
        message: $0.status == .present
          ? $0.requirement : "\($0.requirement); \($0.remediation)"
      )
    }
    if desired.profile.desktop.provider == .yabaiSkhd {
      do {
        _ = try lifecycle.preflight()
        findings.append(
          DoctorFinding(
            id: "desktop.yabai.manual-prerequisite",
            status: .ok,
            message: "yabai can query Spaces through the supported Accessibility boundary"
          )
        )
      } catch {
        findings.append(
          DoctorFinding(
            id: "desktop.yabai.manual-prerequisite",
            status: .failure,
            message: String(describing: error)
          )
        )
      }
      if let keybindings {
        do {
          let plan = try keybindings.plan(
            resourcesRoot: keybindingsResourcesRoot,
            profileURL: profileURL,
            profileRequired: profileRequired,
            stateRoot: stateRoot,
            homeDirectory: homeDirectory,
            profile: desired.profile
          )
          findings.append(
            DoctorFinding(
              id: "desktop.skhd",
              status: plan.effectiveStatus == "converged" ? .ok : .failure,
              message: plan.message
            )
          )
        } catch {
          findings.append(
            DoctorFinding(
              id: "desktop.skhd",
              status: .failure,
              message: String(describing: error)
            )
          )
        }
      }
    } else {
      findings.append(
        DoctorFinding(
          id: "desktop.yabai-skhd",
          status: .warning,
          message: "desktop role is disabled; yabai and skhd are not claimed"
        )
      )
    }

    if desired.profile.topBar == .sketchybar {
      do {
        _ = try sketchyBarLifecycle.preflight()
        findings.append(
          DoctorFinding(
            id: "desktop.sketchybar.service",
            status: .ok,
            message: "supported Homebrew SketchyBar service boundary is available"
          )
        )
      } catch {
        findings.append(
          DoctorFinding(
            id: "desktop.sketchybar.service",
            status: .failure,
            message: String(describing: error)
          )
        )
      }
    } else {
      findings.append(
        DoctorFinding(
          id: "desktop.sketchybar",
          status: .warning,
          message: "top-bar role is disabled; SketchyBar is not claimed"
        )
      )
    }

    let status = try DesktopStatusCommandRunner(
      lifecycle: lifecycle,
      sketchyBarLifecycle: sketchyBarLifecycle,
      sketchyBarCoreRuntime: sketchyBarCoreRuntime,
      keybindings: keybindings,
      theme: theme
    ).execute(
      resourcesRoot: resourcesRoot,
      keybindingsResourcesRoot: keybindingsResourcesRoot,
      profileURL: profileURL,
      profileRequired: profileRequired,
      stateRoot: stateRoot,
      homeDirectory: homeDirectory,
      json: true,
      consumerPaths: consumerPaths,
      macarchyExecutableURL: macarchyExecutableURL
    )
    findings.append(
      DoctorFinding(
        id: "desktop.aggregate",
        status: status.succeeded ? .ok : .failure,
        message: status.succeeded
          ? "desktop generations, ownership, runtime, and theme evidence agree"
          : "desktop status is not converged; run macarchy desktop status --json"
      )
    )

    let report = DoctorReport(
      findings: findings.sorted { $0.id < $1.id },
      operation: "desktop_doctor",
      title: "Macarchy desktop doctor"
    )
    return (try report.render(json: json), report.succeeded)
  }
}
