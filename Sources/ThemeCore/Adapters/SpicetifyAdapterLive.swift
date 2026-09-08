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
      },
      refreshPreparation: {
        try requireRefreshPreparation(configurationDirectoryURL: configurationDirectoryURL)
      }
    )
  }

  /// Inert prerequisite inspection. Native refresh writes into an already unpacked xpui;
  /// it does not initialize stock Spotify. This is not proof that a later refresh succeeds.
  package static func requireRefreshPreparation(configurationDirectoryURL: URL) throws {
    let configurationURL = configurationDirectoryURL.appending(path: "config-xpui.ini")
    let data = try BoundedRegularFile.read(at: configurationURL.resolvingSymlinksInPath()).data
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw SpicetifyAdapterError.cannotReadConfiguration(configurationURL)
    }
    let selection = try configurationSelection(in: configuration, at: configurationURL)
    guard let spotifyPath = selection.spotifyPath, spotifyPath.hasPrefix("/") else {
      throw SpicetifyAdapterError.refreshNotPrepared(
        "config-xpui.ini must name an explicit absolute spotify_path for inert inspection")
    }
    let xpui = URL(filePath: spotifyPath).appending(path: "Apps/xpui")
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: xpui.path, isDirectory: &isDirectory), isDirectory.boolValue,
      manager.isReadableFile(atPath: xpui.appending(path: "index.html").path),
      manager.isWritableFile(atPath: xpui.path)
    else {
      throw SpicetifyAdapterError.refreshNotPrepared(
        "\(xpui.path) must be an unpacked, writable Spotify application with readable index.html")
    }
    for name in ["colors.css", "user.css", "spicetify-config.json"] {
      let file = xpui.appending(path: name)
      if manager.fileExists(atPath: file.path), !manager.isWritableFile(atPath: file.path) {
        throw SpicetifyAdapterError.refreshNotPrepared("\(file.path) is not writable")
      }
    }
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
