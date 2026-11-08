/// The `macarchy-focus-ring` command line, which `macarchy` and the managed launch agent produce
/// and the helper parses. Installed launch agents and older `macarchy` builds pass these exact
/// strings, so none of them may change.
package enum FocusRingHelperCommand {
  package static let executableName = "macarchy-focus-ring"

  /// Long option and flag names, without their leading `--`.
  package static let stateRootOption = "state-root"
  package static let secondsOption = "seconds"
  package static let managedFlag = "managed"
  package static let jsonFlag = "json"

  /// The managed launchd job's arguments after the executable.
  package static func managedArguments(stateRoot: String) -> [String] {
    ["--\(managedFlag)", "--\(stateRootOption)", stateRoot]
  }

  /// A bounded preview's arguments after the executable.
  package static func previewArguments(stateRoot: String, seconds: Double, json: Bool)
    -> [String]
  {
    ["--\(stateRootOption)", stateRoot, "--\(secondsOption)", String(seconds)]
      + (json ? ["--\(jsonFlag)"] : [])
  }
}
