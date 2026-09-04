import Foundation

extension SpicetifyAdapter {
  package static func live(
    root: URL,
    configurationDirectoryURL: URL,
    processRunner: ProcessRunner = .live
  ) -> Self {
    Self(
      root: root,
      configurationDirectoryURL: configurationDirectoryURL,
      executableURL: liveExecutableURL,
      controlIsAvailable: {
        FileManager.default.isExecutableFile(atPath: liveExecutableURL.path)
      },
      processRunner: processRunner,
      spicetifyVersionProvider: {
        try commandVersion(processRunner: processRunner)
      },
      spotifyVersionProvider: {
        try spotifyBundleVersion()
      }
    )
  }

  package static func supportedCommandVersion(
    executableURL: URL = liveExecutableURL,
    processRunner: ProcessRunner = .live
  ) throws -> String {
    try Self(
      root: URL(filePath: "/"),
      configurationDirectoryURL: URL(filePath: "/"),
      executableURL: executableURL,
      controlIsAvailable: { true },
      processRunner: processRunner,
      spicetifyVersionProvider: {
        try commandVersion(executableURL: executableURL, processRunner: processRunner)
      }
    ).supportedVersion()
  }
}
