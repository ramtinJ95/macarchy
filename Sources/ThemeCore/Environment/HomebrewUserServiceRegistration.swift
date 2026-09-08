import Darwin
import Foundation

/// Resolves Homebrew's current and legacy names without choosing between competing jobs.
/// Provider-specific plist, process and executable validation remains with each caller.
package struct HomebrewUserServiceRegistration: Sendable {
  package enum Provider: String, Sendable {
    case borders, sketchybar

    package var labels: [String] {
      ["homebrew.mxcl.\(rawValue)", "sh.brew.\(rawValue)"]
    }
  }

  package struct InspectionError: Error, CustomStringConvertible {
    package let description: String
  }

  package let label: String
  package let propertyListURL: URL
  package let loadedJobOutput: String?

  package static func inspect(
    provider: Provider, home: URL, runner: ProcessRunner
  ) throws -> Self? {
    var registrations: [Self] = []
    for label in provider.labels {
      let url = home.appending(path: "Library/LaunchAgents/\(label).plist")
      var metadata = stat()
      let exists = lstat(url.path, &metadata) == 0
      guard exists || errno == ENOENT else {
        throw InspectionError(description: "Cannot inspect \(url.path) (errno \(errno))")
      }
      let job = try runner.run(
        ProcessRequest(
          executableURL: URL(filePath: "/bin/launchctl"),
          arguments: ["print", "gui/\(getuid())/\(label)"], timeout: 2
        ))
      guard job.terminationStatus == 0 || job.terminationStatus == 113 else {
        throw InspectionError(
          description:
            "Cannot inspect \(label): launchctl status \(job.terminationStatus): \(job.output)")
      }
      if exists || job.terminationStatus == 0 {
        registrations.append(
          Self(
            label: label, propertyListURL: url,
            loadedJobOutput: job.terminationStatus == 0 ? job.output : nil))
      }
    }
    guard registrations.count <= 1 else {
      throw InspectionError(
        description:
          "Conflicting current and legacy Homebrew registrations for \(provider.rawValue); resolve them explicitly"
      )
    }
    return registrations.first
  }
}
