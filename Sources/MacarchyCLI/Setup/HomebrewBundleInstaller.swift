import Darwin
import Foundation
import ThemeCore

/// Homebrew owns resolution, downloads, linking, hooks and receipts.
struct HomebrewBundleInstaller: Sendable {
  struct Execution: Sendable {
    let status: Int32
    let diagnostic: String
  }
  var preflight: @Sendable () throws -> Void = {}
  var apply: @Sendable (URL, @Sendable (Int32) throws -> Void) throws -> Execution

  static let arguments = ["bundle", "install", "--no-upgrade", "--file"]
  static let environment = [
    "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_AUTO_UPDATE=1",
    "HOMEBREW_NO_AUTOREMOVE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1",
    "HOMEBREW_NO_INSTALL_UPGRADE=1",
  ]

  static func live(homeDirectory: URL) -> Self {
    Self(
      preflight: { try validateConfiguration(homeDirectory: homeDirectory) },
      apply: { brewfile, recordProcess in
        try validateConfiguration(homeDirectory: homeDirectory)
        let log = brewfile.deletingLastPathComponent().appending(path: "homebrew-install.log")
        let status = try HomebrewPackageInstallProcess.run(
          request(brewfile: brewfile, log: log, homeDirectory: homeDirectory),
          recordProcess: recordProcess)
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        return .init(
          status: status,
          diagnostic: String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self))
      })
  }

  static func request(brewfile: URL, log: URL, homeDirectory: URL) -> ProcessRequest {
    // Explicit env prevents inherited Bundle cleanup/skip/force settings. stdin
    // is closed: authentication/trust prompts fail visibly rather than hanging.
    // Do not cap all regular-file writes: that also caps native package payloads.
    ProcessRequest(
      executableURL: URL(filePath: "/bin/sh"),
      arguments: [
        "-c", #"log=$1; shift; exec "$@" < /dev/null > "$log" 2>&1"#,
        "macarchy-bundle-install", log.path, "/usr/bin/env", "-i",
        "HOME=\(homeDirectory.path)", "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL=C",
      ] + environment + ["/opt/homebrew/bin/brew"] + arguments + [brewfile.path],
      timeout: 1800)
  }

  static func validateConfiguration(homeDirectory: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else {
      throw SetupPackageAdoptionError("Homebrew is not installed at /opt/homebrew/bin/brew.")
    }
    // bin/brew sources these after the command environment. Do not silently
    // ignore user settings or allow them to request cleanup outside approval.
    for url in [
      URL(filePath: "/etc/homebrew/brew.env"),
      URL(filePath: "/opt/homebrew/etc/homebrew/brew.env"),
      homeDirectory.appending(path: ".homebrew/brew.env"),
    ] {
      var info = stat()
      if lstat(url.path, &info) == 0 {
        throw SetupPackageAdoptionError(
          "Homebrew configuration may override install-only command scope: \(url.path). Resolve explicitly; Macarchy will not edit it."
        )
      }
      guard errno == ENOENT else {
        throw SetupPackageAdoptionError("Cannot inspect Homebrew configuration: \(url.path).")
      }
    }
  }
}
