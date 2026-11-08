import Foundation

@testable import MacarchyCLI
@testable import ThemeCore

struct InventoryFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "macarchy-package-inventory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }

  func write(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func formula(_ token: String, version: String = "1", tap: String) throws {
    try write(
      #"{"homebrew_version":"6.0.18","source":{"tap":"\#(tap)"}}"#,
      at: root.appending(path: "Cellar/\(token)/\(version)/INSTALL_RECEIPT.json")
    )
  }

  func cask(_ token: String, tap: String) throws {
    let metadata = root.appending(path: "Caskroom/\(token)/.metadata")
    try write(
      #"{"homebrew_version":"6.0.18","source":{"tap":"\#(tap)","version":"1"}} "#,
      at: metadata.appending(path: "INSTALL_RECEIPT.json")
    )
    try FileManager.default.createDirectory(
      at: metadata.appending(path: "1"), withIntermediateDirectories: true)
  }

  func reader(
    formulae: String = "", casks: String = "",
    record: @escaping @Sendable (ProcessRequest) -> Void = { _ in }
  ) -> HomebrewPackageInventoryReader {
    HomebrewPackageInventoryReader(
      prefix: root,
      processRunner: ProcessRunner { request in
        record(request)
        return ProcessResult(
          terminationStatus: 0, output: request.arguments[1] == "--formula" ? formulae : casks)
      },
      executableIsAvailable: { true }
    )
  }
}
