import Foundation

/// The scripts the applied profile declares, supplied by the CLI from applied ownership, never
/// read from an edited profile.
package struct UserScriptsMode: Sendable {
  package let scripts: [URL]

  package init(scripts: [URL]) {
    self.scripts = scripts
  }
}

/// Each script's outcome, in profile order.
package struct UserScriptsReport: Equatable, Sendable {
  package struct Entry: Equatable, Sendable {
    package let script: String
    package let outcome: UserScriptRunner.Outcome
  }

  package let entries: [Entry]

  package var succeeded: Bool { entries.allSatisfy { $0.outcome == .succeeded } }

  package var message: String {
    let count = entries.count == 1 ? "1 script" : "\(entries.count) scripts"
    return "Ran \(count): "
      + entries.map { entry in
        switch entry.outcome {
        case .succeeded: "\(entry.script) succeeded"
        case .refused(let reason): "\(entry.script) refused, \(reason)"
        case .failed(let reason): "\(entry.script) failed, \(reason)"
        }
      }.joined(separator: "; ")
  }
}

/// Runs the profile's scripts once every other consumer has reconciled, with the active theme.
/// A failed script fails only this optional consumer.
package struct UserScriptsAdapter: Sendable {
  package static let id = "user-scripts"

  let root: URL
  let mode: UserScriptsMode?
  let runner: UserScriptRunner

  package init(root: URL, mode: UserScriptsMode?, runner: UserScriptRunner = UserScriptRunner()) {
    self.root = root
    self.mode = mode
    self.runner = runner
  }

  private func scripts() throws -> [URL] {
    guard let mode else {
      throw UserScriptsError(
        "no applied user scripts; review the setup plan and apply the profile first")
    }
    return mode.scripts
  }

  func preflight() throws { _ = try scripts() }

  func inspection() -> AdapterInspection {
    do {
      let scripts = try scripts()
      let refusals = scripts.compactMap { script -> String? in
        guard case .failure(let refusal) = runner.trustedPath(of: script) else { return nil }
        return "\(script.path): \(refusal.reason)"
      }
      guard refusals.isEmpty else {
        return AdapterInspection(
          .userScripts, status: .failed,
          message: "Will not run: " + refusals.joined(separator: "; "))
      }
      return AdapterInspection(
        .userScripts,
        message: "Runs after each theme change and at teardown: "
          + scripts.map(\.path).joined(separator: ", "))
    } catch {
      return AdapterInspection(.userScripts, status: .failed, message: String(describing: error))
    }
  }

  func reconciliation() -> AdapterReconciliation {
    AdapterReconciliation(.userScripts, runsAfterOthers: true) {
      let report = try run(event: .apply)
      return AdapterOutcome(status: report.succeeded ? .applied : .failed, message: report.message)
    }
  }

  /// Runs every script in order for `event` with the active theme. Teardown calls this before
  /// the active theme is retired.
  package func run(event: UserScriptRunner.Event) throws -> UserScriptsReport {
    try Task.checkCancellation()
    let scripts = try scripts()
    let theme = try ThemeGenerationReader(root: root).activeManifest().normalizedTheme(root: root)
    let environment = UserScriptRunner.environment(
      event: event, theme: theme,
      themeFile: StateLayout(root: root).currentThemeArtifact(ThemeRenderer.themeOutputPath))
    var entries: [UserScriptsReport.Entry] = []
    for script in scripts {
      try Task.checkCancellation()
      let outcome = runner.run(script, environment: environment, isCancelled: { Task.isCancelled })
      try Task.checkCancellation()
      entries.append(.init(script: script.path, outcome: outcome))
    }
    return UserScriptsReport(entries: entries)
  }
}

struct UserScriptsError: Error, CustomStringConvertible, Sendable {
  let description: String
  init(_ description: String) { self.description = description }
}
